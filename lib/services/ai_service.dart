import 'dart:async';
import 'dart:convert';
import 'dart:io';

import '../models/ai_config.dart';

/// A failure the user can act on. [message] is already in Chinese and says what
/// to check; [detail] keeps the server's own words for the log / expandable row.
class AiException implements Exception {
  AiException(this.message, {this.detail});

  final String message;
  final String? detail;

  @override
  String toString() => message;

  String get expanded {
    final body = detail?.trim();
    if (body == null || body.isEmpty) return message;
    return '$message\n\n服务器原文：\n$body';
  }
}

/// Talks to one chat endpoint. No dependency beyond `dart:io`, so it adds
/// nothing to the APK and works the same in tests via an injected [HttpClient].
class AiService {
  AiService(this.config, {HttpClient? client})
      : _injected = client;

  final AiConfig config;
  final HttpClient? _injected;

  static const _connectTimeout = Duration(seconds: 30);

  /// Streams the assistant's answer as it arrives.
  ///
  /// Cancelling the subscription aborts the request: the generator's `finally`
  /// closes the socket, so "停止" does not keep burning tokens in the
  /// background.
  Stream<String> streamChat(List<AiMessage> messages) async* {
    if (!config.isUsable) {
      throw AiException('还没有配置 AI 服务。请到「设置 → AI 助手」填写接口地址和模型名。');
    }
    if (config.needsKey && config.apiKey.trim().isEmpty) {
      throw AiException(
        '缺少 API Key。${config.isLocalEndpoint ? '' : '请到「设置 → AI 助手」填入服务商的 Key。'}',
      );
    }

    final client = _injected ?? HttpClient();
    client.connectionTimeout = _connectTimeout;

    try {
      final uri = _endpointUri();
      final request = await client.postUrl(uri);
      request.headers.set(HttpHeaders.contentTypeHeader, 'application/json');
      request.headers.set(HttpHeaders.acceptHeader, 'text/event-stream');
      _applyAuth(request);

      // Declare the length explicitly. Without it HttpClient switches to
      // chunked transfer-encoding, which a handful of gateways and home-grown
      // proxies do not decode — they then see an empty body and answer as if
      // no prompt had been sent.
      final payload = utf8.encode(jsonEncode(_requestBody(messages)));
      request.contentLength = payload.length;
      request.add(payload);

      final response = await request.close();
      if (response.statusCode != HttpStatus.ok) {
        final body = await response.transform(utf8.decoder).join();
        throw _translateStatus(response.statusCode, body);
      }

      final mime = response.headers.contentType?.mimeType ?? '';
      if (mime.contains('application/json')) {
        // Some gateways ignore `stream: true` and answer in one JSON blob.
        final body = await response.transform(utf8.decoder).join();
        final text = _extractWholeBody(body);
        if (text != null && text.isNotEmpty) yield text;
        return;
      }

      await for (final line in response
          .transform(utf8.decoder)
          .transform(const LineSplitter())) {
        final delta = _parseEventLine(line);
        if (delta == null) return;      // stream finished
        if (delta.isNotEmpty) yield delta;
      }
    } on SocketException catch (error) {
      throw AiException(
        '连不上 ${Uri.tryParse(config.baseUrl)?.host ?? config.baseUrl}。'
        '检查网络、接口地址是否写错；若用本地电脑上的模型，确认手机和电脑在同一 WiFi，'
        '且电脑防火墙放行了该端口。',
        detail: error.message,
      );
    } on HandshakeException catch (error) {
      throw AiException('TLS 握手失败，接口地址可能是 http 而非 https，或证书不被信任。',
          detail: error.message);
    } on HttpException catch (error) {
      throw AiException('HTTP 请求失败。', detail: error.message);
    } finally {
      if (_injected == null) client.close(force: true);
    }
  }

  /// Lists the models the endpoint exposes.
  ///
  /// This doubles as the "测试连接" action: it is a free GET, so a wrong key or
  /// a typo'd base URL surfaces before the user spends anything.
  Future<List<String>> listModels() async {
    if (config.baseUrl.trim().isEmpty) {
      throw AiException('请先填接口地址。');
    }
    final client = _injected ?? HttpClient();
    client.connectionTimeout = _connectTimeout;

    try {
      final uri = _modelsUri();
      final request = await client.getUrl(uri);
      _applyAuth(request);
      request.headers.set(HttpHeaders.acceptHeader, 'application/json');

      final response = await request.close();
      final body = await response.transform(utf8.decoder).join();
      if (response.statusCode != HttpStatus.ok) {
        throw _translateStatus(response.statusCode, body);
      }
      final decoded = jsonDecode(body);
      final raw = decoded is Map ? (decoded['data'] ?? decoded['models']) : decoded;
      if (raw is! List) {
        throw AiException('接口返回的模型列表格式不认识。', detail: body);
      }
      final ids = <String>[];
      for (final item in raw) {
        if (item is Map) {
          final id = item['id'] ?? item['name'] ?? item['model'];
          if (id != null) {
            // Gemini returns "models/gemini-2.5-flash"; the API wants the bare id.
            ids.add(id.toString().split('/').last);
          }
        } else if (item is String) {
          ids.add(item);
        }
      }
      ids.sort();
      return ids;
    } on SocketException catch (error) {
      throw AiException('连不上接口地址，检查网络或地址是否写错。', detail: error.message);
    } finally {
      if (_injected == null) client.close(force: true);
    }
  }

  // ---------------------------------------------------------------------------
  // Request building
  // ---------------------------------------------------------------------------

  Uri _endpointUri() {
    final base = _trimSlash(config.baseUrl);
    switch (config.protocol) {
      case AiProtocol.openai:
        return Uri.parse('$base/chat/completions');
      case AiProtocol.anthropic:
        return Uri.parse('$base/v1/messages');
      case AiProtocol.gemini:
        final model = Uri.encodeComponent(config.model.trim());
        return Uri.parse('$base/models/$model:streamGenerateContent?alt=sse');
    }
  }

  Uri _modelsUri() {
    final base = _trimSlash(config.baseUrl);
    switch (config.protocol) {
      case AiProtocol.openai:
        return Uri.parse('$base/models');
      case AiProtocol.anthropic:
        return Uri.parse('$base/v1/models');
      case AiProtocol.gemini:
        return Uri.parse('$base/models');
    }
  }

  void _applyAuth(HttpClientRequest request) {
    final key = config.apiKey.trim();
    switch (config.protocol) {
      case AiProtocol.openai:
        if (key.isNotEmpty) {
          request.headers.set(HttpHeaders.authorizationHeader, 'Bearer $key');
        }
        // OpenRouter asks for these but does not require them.
        request.headers.set('HTTP-Referer', 'https://github.com/refactoringhq/tolaria');
        request.headers.set('X-Title', 'Tolaria Android');
      case AiProtocol.anthropic:
        if (key.isNotEmpty) request.headers.set('x-api-key', key);
        request.headers.set('anthropic-version', '2023-06-01');
      case AiProtocol.gemini:
        // Header instead of ?key= so the secret does not end up in logs.
        if (key.isNotEmpty) request.headers.set('x-goog-api-key', key);
    }
  }

  Map<String, Object?> _requestBody(List<AiMessage> messages) {
    switch (config.protocol) {
      case AiProtocol.openai:
        return {
          'model': config.model.trim(),
          'stream': true,
          'messages': [
            for (final m in messages)
              if (m.content.trim().isNotEmpty)
                {'role': m.role, 'content': m.content},
          ],
        };

      case AiProtocol.anthropic:
        // Anthropic takes the system prompt out of band and rejects a
        // `system` role inside `messages`.
        final system = messages
            .where((m) => m.role == 'system')
            .map((m) => m.content)
            .join('\n\n')
            .trim();
        final turns = messages
            .where((m) => m.role != 'system' && m.content.trim().isNotEmpty)
            .map((m) => {'role': m.role, 'content': m.content})
            .toList();
        return {
          'model': config.model.trim(),
          'max_tokens': 4096,
          'stream': true,
          if (system.isNotEmpty) 'system': system,
          'messages': turns,
        };

      case AiProtocol.gemini:
        final system = messages
            .where((m) => m.role == 'system')
            .map((m) => m.content)
            .join('\n\n')
            .trim();
        final contents = <Map<String, Object?>>[];
        for (final m in messages) {
          if (m.role == 'system' || m.content.trim().isEmpty) continue;
          contents.add({
            'role': m.role == 'assistant' ? 'model' : 'user',
            'parts': [
              {'text': m.content},
            ],
          });
        }
        return {
          if (system.isNotEmpty)
            'systemInstruction': {
              'parts': [
                {'text': system},
              ],
            },
          'contents': contents,
        };
    }
  }

  // ---------------------------------------------------------------------------
  // Response parsing
  // ---------------------------------------------------------------------------

  /// Parses one SSE line.
  ///
  /// Returns `null` when the stream is finished, an empty string when the line
  /// carries no text (keep-alive, `event:` header, zero-length delta), and the
  /// text itself otherwise.
  String? _parseEventLine(String line) {
    if (line.isEmpty || line.startsWith(':')) return '';
    // Anthropic sends `event: ...` lines; the payload is always in `data:`.
    if (!line.startsWith('data:')) return '';

    final payload = line.substring(5).trim();
    if (payload.isEmpty) return '';
    if (payload == '[DONE]') return null;

    Object? decoded;
    try {
      decoded = jsonDecode(payload);
    } catch (_) {
      return ''; // A malformed keep-alive must not kill the stream.
    }
    if (decoded is! Map) return '';

    switch (config.protocol) {
      case AiProtocol.openai:
        final choices = decoded['choices'];
        if (choices is! List || choices.isEmpty) return '';
        final first = choices.first;
        if (first is! Map) return '';
        final delta = first['delta'] ?? first['message'];
        if (delta is! Map) return '';
        final content = delta['content'];
        return content is String ? content : '';

      case AiProtocol.anthropic:
        final type = decoded['type'];
        if (type == 'content_block_delta') {
          final delta = decoded['delta'];
          if (delta is Map) {
            final text = delta['text'];
            if (text is String) return text;
          }
          return '';
        }
        if (type == 'content_block_start') {
          final block = decoded['content_block'];
          if (block is Map && block['text'] is String) {
            return block['text'] as String;
          }
          return '';
        }
        if (type == 'error') {
          final error = decoded['error'];
          final message = error is Map ? error['message'] : null;
          throw AiException('模型返回错误。', detail: message?.toString() ?? payload);
        }
        return '';

      case AiProtocol.gemini:
        final candidates = decoded['candidates'];
        if (candidates is! List || candidates.isEmpty) return '';
        final first = candidates.first;
        if (first is! Map) return '';
        final content = first['content'];
        if (content is! Map) return '';
        final parts = content['parts'];
        if (parts is! List) return '';
        final buffer = StringBuffer();
        for (final part in parts) {
          if (part is Map && part['text'] is String) {
            buffer.write(part['text']);
          }
        }
        return buffer.toString();
    }
  }

  /// For gateways that answer with a single JSON object instead of a stream.
  String? _extractWholeBody(String body) {
    Object? decoded;
    try {
      decoded = jsonDecode(body);
    } catch (_) {
      return null;
    }
    if (decoded is! Map) return null;

    switch (config.protocol) {
      case AiProtocol.openai:
        final choices = decoded['choices'];
        if (choices is List && choices.isNotEmpty) {
          final first = choices.first;
          if (first is Map) {
            final message = first['message'];
            if (message is Map && message['content'] is String) {
              return message['content'] as String;
            }
            if (first['text'] is String) return first['text'] as String;
          }
        }
        break;
      case AiProtocol.anthropic:
        final content = decoded['content'];
        if (content is List) {
          final buffer = StringBuffer();
          for (final block in content) {
            if (block is Map && block['text'] is String) {
              buffer.write(block['text']);
            }
          }
          return buffer.toString();
        }
        break;
      case AiProtocol.gemini:
        final candidates = decoded['candidates'];
        if (candidates is List && candidates.isNotEmpty) {
          final first = candidates.first;
          if (first is Map) {
            final content = first['content'];
            if (content is Map && content['parts'] is List) {
              final buffer = StringBuffer();
              for (final part in content['parts'] as List) {
                if (part is Map && part['text'] is String) {
                  buffer.write(part['text']);
                }
              }
              return buffer.toString();
            }
          }
        }
        break;
    }
    return null;
  }

  // ---------------------------------------------------------------------------
  // Errors
  // ---------------------------------------------------------------------------

  AiException _translateStatus(int status, String body) {
    final detail = _condense(body);
    switch (status) {
      case 400:
        if (body.contains('model')) {
          return AiException(
            '请求被拒绝（400）：很可能模型名「${config.model}」这个接口不认识。'
            '点「检测连接」看可用模型列表。',
            detail: detail,
          );
        }
        return AiException('请求被拒绝（400），检查模型名和参数。', detail: detail);
      case 401:
        return AiException(
          'API Key 无效（401）。到服务商控制台重新复制一次，注意不要带空格或换行。',
          detail: detail,
        );
      case 402:
        return AiException('账户余额不足（402），需要充值后才能继续。', detail: detail);
      case 403:
        return AiException(
          '没有权限（403）：Key 可能没有该模型的访问权，或所在地区被限制。',
          detail: detail,
        );
      case 404:
        return AiException(
          '接口地址不存在（404）。检查 Base URL：OpenAI 兼容一般以 /v1 结尾，'
          'Anthropic 填到域名即可。',
          detail: detail,
        );
      case 413:
        return AiException('请求内容太大（413）。关掉「带上笔记内容」再试，或换更长的上下文模型。',
            detail: detail);
      case 429:
        return AiException('触发限流或额度用尽（429）。等一会儿再试，或检查账户配额。',
            detail: detail);
      case 500:
      case 502:
      case 503:
      case 504:
        return AiException('服务端出错（$status），通常是对方临时不可用，稍后重试。',
            detail: detail);
      default:
        return AiException('请求失败（HTTP $status）。', detail: detail);
    }
  }

  String _condense(String body) {
    final text = body.trim();
    if (text.isEmpty) return '';
    return text.length <= 800 ? text : '${text.substring(0, 800)}…';
  }

  static String _trimSlash(String value) {
    var out = value.trim();
    while (out.endsWith('/')) {
      out = out.substring(0, out.length - 1);
    }
    return out;
  }
}
