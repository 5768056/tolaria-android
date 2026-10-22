import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:tolaria_android/models/ai_config.dart';
import 'package:tolaria_android/services/ai_service.dart';

/// Exercises the streaming layer against a real local HTTP server, because the
/// bugs worth catching here are protocol-shaped: chunk boundaries, `[DONE]`,
/// Anthropic's `event:` lines, and gateways that ignore `stream: true`. A
/// mocked client would let all of those pass.
void main() {
  late HttpServer server;
  late String baseUrl;

  setUp(() async {
    server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    baseUrl = 'http://127.0.0.1:${server.port}/v1';
  });

  tearDown(() async {
    await server.close(force: true);
  });

  /// `HttpResponse.write()` encodes as latin1 unless the sink was configured
  /// before the first byte, which throws on Chinese fixtures. Writing bytes
  /// directly sidesteps the whole question.
  void sendBody(HttpResponse response, String text, {bool sse = true}) {
    response.headers.contentType = sse
        ? ContentType('text', 'event-stream', charset: 'utf-8')
        : ContentType('application', 'json', charset: 'utf-8');
    response.add(utf8.encode(text));
  }

  AiConfig configFor({
    AiProtocol protocol = AiProtocol.openai,
    String model = 'test-model',
    String key = 'sk-test',
  }) {
    return AiConfig(
      presetId: 'custom',
      protocol: protocol,
      baseUrl: baseUrl,
      model: model,
      apiKey: key,
    );
  }

  test('openai: concatenates SSE deltas until [DONE]', () async {
    server.listen((request) async {
      final response = request.response..statusCode = 200;
      sendBody(response, [
        'data: {"choices":[{"delta":{"content":"你好"}}]}\n\n',
        'data: {"choices":[{"delta":{"content":"，"}}]}\n\n',
        'data: {"choices":[{"delta":{"content":"世界"}}]}\n\n',
        'data: [DONE]\n\n',
        // Anything after [DONE] must be ignored.
        'data: {"choices":[{"delta":{"content":"不该出现"}}]}\n\n',
      ].join());
      await response.close();
    });

    final chunks = await AiService(configFor())
        .streamChat([const AiMessage(role: 'user', content: 'hi')])
        .toList();
    expect(chunks.join(), '你好，世界');
  });

  test('openai: skips keep-alives and empty deltas without breaking', () async {
    server.listen((request) async {
      final response = request.response..statusCode = 200;
      sendBody(response, [
        ': keep-alive\n\n',
        'data: {"choices":[{"delta":{"role":"assistant"}}]}\n\n',
        'data: {"choices":[]}\n\n',
        'data: {"choices":[{"delta":{"content":"ok"}}]}\n\n',
        'data: [DONE]\n\n',
      ].join());
      await response.close();
    });

    final chunks = await AiService(configFor())
        .streamChat([const AiMessage(role: 'user', content: 'hi')])
        .toList();
    expect(chunks.join(), 'ok');
  });

  test('anthropic: reads content_block_delta text', () async {
    server.listen((request) async {
      final response = request.response..statusCode = 200;
      sendBody(response, [
        'event: message_start\n',
        'data: {"type":"message_start"}\n\n',
        'event: content_block_delta\n',
        'data: {"type":"content_block_delta","delta":{"type":"text_delta","text":"第一段"}}\n\n',
        'data: {"type":"content_block_delta","delta":{"text":"第二段"}}\n\n',
        'event: message_stop\n',
        'data: {"type":"message_stop"}\n\n',
      ].join());
      await response.close();
    });

    final chunks = await AiService(configFor(protocol: AiProtocol.anthropic))
        .streamChat([const AiMessage(role: 'user', content: 'hi')])
        .toList();
    expect(chunks.join(), '第一段第二段');
  });

  test('anthropic: system messages move out of the messages array', () async {
    late Map<String, Object?> sent;
    server.listen((request) async {
      sent = jsonDecode(await utf8.decoder.bind(request).join())
          as Map<String, Object?>;
      final response = request.response..statusCode = 200;
      sendBody(response,
          'data: {"type":"content_block_delta","delta":{"text":"x"}}\n\n');
      await response.close();
    });

    await AiService(configFor(protocol: AiProtocol.anthropic)).streamChat(const [
      AiMessage(role: 'system', content: '你是助手'),
      AiMessage(role: 'user', content: '问'),
    ]).toList();

    expect(sent['system'], '你是助手');
    final messages = sent['messages'] as List;
    expect(messages.length, 1);
    expect((messages.first as Map)['role'], 'user');
  });

  test('gemini: signs the request with a header, not the query string', () async {
    late HttpHeaders headers;
    late Map<String, Object?> sent;
    server.listen((request) async {
      headers = request.headers;
      sent = jsonDecode(await utf8.decoder.bind(request).join())
          as Map<String, Object?>;
      final response = request.response..statusCode = 200;
      sendBody(
        response,
        'data: {"candidates":[{"content":{"parts":[{"text":"答案"}]}}]}\n\n',
      );
      await response.close();
    });

    final chunks = await AiService(
      configFor(protocol: AiProtocol.gemini, model: 'gemini-test'),
    ).streamChat(const [
      AiMessage(role: 'system', content: 'sys'),
      AiMessage(role: 'user', content: '问'),
    ]).toList();

    expect(chunks.join(), '答案');
    expect(headers.value('x-goog-api-key'), 'sk-test');
    expect(sent['systemInstruction'], isNotNull);
    final contents = sent['contents'] as List;
    expect((contents.first as Map)['role'], 'user');
  });

  test('gateway that answers with one JSON blob is still usable', () async {
    server.listen((request) async {
      final response = request.response..statusCode = 200;
      sendBody(
        response,
        jsonEncode({
          'choices': [
            {
              'message': {'role': 'assistant', 'content': '整段回答'},
            },
          ],
        }),
        sse: false,
      );
      await response.close();
    });

    final chunks = await AiService(configFor())
        .streamChat([const AiMessage(role: 'user', content: 'hi')])
        .toList();
    expect(chunks.join(), '整段回答');
  });

  test('401 is translated into an actionable Chinese message', () async {
    server.listen((request) async {
      final response = request.response..statusCode = 401;
      sendBody(response, '{"error":{"message":"invalid api key"}}', sse: false);
      await response.close();
    });

    await expectLater(
      AiService(configFor())
          .streamChat([const AiMessage(role: 'user', content: 'hi')])
          .toList(),
      throwsA(
        isA<AiException>().having((e) => e.message, 'message', contains('Key 无效')),
      ),
    );
  });

  test('429 explains that it is rate limiting, not a bug', () async {
    server.listen((request) async {
      final response = request.response..statusCode = 429;
      sendBody(response, 'rate limited', sse: false);
      await response.close();
    });

    await expectLater(
      AiService(configFor())
          .streamChat([const AiMessage(role: 'user', content: 'hi')])
          .toList(),
      throwsA(
        isA<AiException>().having((e) => e.message, 'message', contains('429')),
      ),
    );
  });

  test('listModels parses ids and strips provider prefixes', () async {
    server.listen((request) async {
      expect(request.uri.path, '/v1/models');
      expect(request.headers.value('authorization'), 'Bearer sk-test');
      final response = request.response..statusCode = 200;
      sendBody(
        response,
        jsonEncode({
          'data': [
            {'id': 'models/gemini-flash'},
            {'id': 'deepseek-chat'},
            {'id': 'gpt-4o-mini'},
          ],
        }),
        sse: false,
      );
      await response.close();
    });

    final models = await AiService(configFor()).listModels();
    expect(models, ['deepseek-chat', 'gemini-flash', 'gpt-4o-mini']);
  });

  test('unreachable endpoint produces a network hint, not a stack trace',
      () async {
    const config = AiConfig(
      presetId: 'custom',
      baseUrl: 'http://127.0.0.1:1/v1', // nothing listens here
      model: 'm',
      apiKey: 'k',
    );

    await expectLater(
      AiService(config)
          .streamChat([const AiMessage(role: 'user', content: 'hi')])
          .toList(),
      throwsA(
        isA<AiException>().having((e) => e.message, 'message', contains('连不上')),
      ),
    );
  });

  test('missing key is rejected before any socket is opened', () async {
    var hit = false;
    server.listen((request) async {
      hit = true;
      await request.response.close();
    });

    // A public host, so the key requirement applies — but the check must fire
    // before any connection, which is why nothing may reach the server above.
    const config = AiConfig(
      presetId: 'deepseek',
      baseUrl: 'https://api.example.invalid/v1',
      model: 'm',
      apiKey: '',
    );

    await expectLater(
      AiService(config)
          .streamChat([const AiMessage(role: 'user', content: 'hi')])
          .toList(),
      throwsA(
        isA<AiException>().having((e) => e.message, 'message', contains('Key')),
      ),
    );
    expect(hit, isFalse);
  });
}
