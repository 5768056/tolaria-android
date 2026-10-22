import 'dart:async';
import 'dart:convert';
import 'dart:io';

import '../../models/ai_config.dart';
import '../vault_service.dart';
import 'agent_tool.dart';
import 'vault_tools.dart';

/// The on-device agent loop.
///
/// Desktop Tolaria hands a local CLI agent the vault through an MCP server and
/// lets that process decide what to do. Android has no such process, so the
/// loop lives here: ask the model, run whatever tools it calls, feed the
/// results back, repeat until it answers in prose.
///
/// Only OpenAI-compatible endpoints are supported — that covers DeepSeek,
/// Moonshot, Zhipu, DashScope, SiliconFlow, OpenRouter, OpenAI and Ollama,
/// which is every provider that speaks `tool_calls` in this shape. Anthropic
/// and Gemini use different tool wire formats; for those the app keeps the
/// plain Chat mode instead of pretending.
///
/// Requests are non-streaming on purpose: `tool_calls` in SSE deltas arrive
/// fragmented across chunks and reassembling them is a well-known source of
/// silent corruption. Tool rounds are short; only the last answer is worth
/// streaming, and that can be layered on later.
class AgentRunner {
  AgentRunner({
    required this.vault,
    required this.config,
    this.approve,
    this.maxSteps = 8,
    this.maxToolCallsPerStep = 4,
    this.outputTemplate,
    this.searchApiKey,
    this.searchProvider,
    this.onNotice,
    this.retryDelays = const [Duration(seconds: 1), Duration(seconds: 2)],
    this.rateLimitGap = const Duration(milliseconds: 1200),
    this.maxHistoryChars = 24000,
    this.maxHistoryTurns = 12,
    List<AgentTool>? tools,
  }) : tools = tools ??
            buildVaultTools(
              vault,
              searchApiKey: searchApiKey,
              searchProvider: searchProvider,
            );

  final VaultService vault;
  final AiConfig config;

  /// Called before any tool that writes. Returning false turns the call into a
  /// "user declined" tool result so the model can adapt instead of failing.
  final Future<bool> Function(AgentTool tool, Map<String, dynamic> args)? approve;

  final int maxSteps;
  final int maxToolCallsPerStep;
  final List<AgentTool> tools;

  /// Out-of-band status text for things that happen *between* two events —
  /// mainly "the provider rate-limited us, retrying in Ns". The event stream
  /// is parked inside `await _chat(...)` while that happens, so a plain yield
  /// cannot deliver it; the screen gets it through this hook instead.
  final void Function(String message)? onNotice;

  /// Backoff schedule for retryable HTTP failures (429 / 5xx). One entry per
  /// retry, so the default means "first try + 2 retries". Tests pass short
  /// delays so a rate-limit case does not cost three real seconds.
  final List<Duration> retryDelays;

  /// Minimum spacing between requests once the provider has complained about
  /// speed. Free tiers rate-limit by the second, not by the day: `glm-4.7-flash`
  /// starts returning 429 on the *second* request of a run while `glm-4-flash`
  /// takes dozens. The loop issues one request per step, so without pacing a
  /// 10-step task can never finish on a strict free tier. Zero disables it.
  final Duration rateLimitGap;

  /// How much of the previous conversation is replayed on the next question.
  ///
  /// A follow-up question has to see what was already said and done, or the
  /// model answers "那第二点呢" as if the conversation had just started. The
  /// transcript is therefore sent back whole — but only up to this many
  /// characters, because every turn re-uploads it and a free tier will either
  /// run out of context or start answering 429 long before it runs out of money.
  final int maxHistoryChars;

  /// Hard cap on the number of previous user turns kept, regardless of size.
  /// Guards against a long tail of tiny turns that fit the character budget
  /// while still costing a request per round-trip on strict free tiers.
  final int maxHistoryTurns;

  /// Optional output-format template forwarded from [AiConfig]; when set it is
  /// appended to the system prompt so every answer follows the same shape.
  final String? outputTemplate;

  /// Optional search provider key forwarded from [AiConfig]; when set the
  /// `web_search` tool uses Tavily instead of the keyless DuckDuckGo scrape.
  final String? searchApiKey;

  /// Which search backend to use; forwarded from [AiConfig.searchProvider].
  final SearchProvider? searchProvider;

  /// The OpenAI-shaped transcript (system/user/assistant/tool messages) as it
  /// stood at the end of the most recent [run] — including tool calls and
  /// their results, with oversized tool payloads trimmed. Feeding this back
  /// through [run]'s `history` is what makes every follow-up question a
  /// continuation of the same conversation instead of a cold start.
  List<Map<String, dynamic>>? lastMessages;

  bool _cancelled = false;

  /// Set after the first 429 of a run; see [rateLimitGap]. Resets every run
  /// because the next task may be on a model that does not care.
  bool _slowMode = false;
  DateTime? _lastRequestAt;

  void cancel() => _cancelled = true;

  Map<String, AgentTool> get _byName => {for (final t in tools) t.name: t};

  /// Runs one conversation turn, emitting everything that happens.
  ///
  /// Pass [history] (the previous turn's [lastMessages]) to keep the
  /// conversation going. That is the normal path from the second question
  /// onward — not just after hitting the step cap. The history already carries
  /// the system prompt, so no new one is injected; [noteContext] is instead
  /// prepended to this turn's user message, and only when the caller passes it
  /// (i.e. only when the note actually changed, so the same 12k characters are
  /// not re-uploaded on every follow-up).
  ///
  /// Events come out of a [StreamController] instead of an `async*` body
  /// because the SSE parser has to push text *from inside a socket read*.
  /// A generator cannot yield from a callback, and buffering deltas until the
  /// response ends would defeat the point of streaming.
  Stream<AgentEvent> run(
    String prompt, {
    String? noteContext,
    List<Map<String, dynamic>>? history,
  }) {
    final controller = StreamController<AgentEvent>();
    // Cancelling the subscription (the stop button) must stop the loop, not
    // just stop listening to it. A *finished* stream also reports a cancel as
    // it winds down, so the flag is gated: otherwise one completed turn would
    // poison every later turn on the same runner.
    var finished = false;
    controller.onCancel = () {
      if (!finished) _cancelled = true;
    };
    unawaited(
      _drive(controller, prompt, noteContext: noteContext, history: history).then(
        (_) {
          finished = true;
          if (!controller.isClosed) controller.close();
        },
        onError: (Object error, StackTrace stack) {
          finished = true;
          if (!controller.isClosed) {
            controller.addError(error, stack);
            controller.close();
          }
        },
      ),
    );
    return controller.stream;
  }

  Future<void> _drive(
    StreamController<AgentEvent> out,
    String prompt, {
    String? noteContext,
    List<Map<String, dynamic>>? history,
  }) async {
    if (config.protocol != AiProtocol.openai) {
      throw const AgentException(
        '这台设备上的 Agent 模式只支持 OpenAI 兼容接口（DeepSeek、Kimi、智谱、'
        '硅基流动、OpenRouter、Ollama 等）。当前服务商用的是另一套工具协议，'
        '请切回 Chat 模式，或在设置里换一家。',
      );
    }
    if (!config.isUsable) {
      throw AgentException(config.needsKey ? '还没有填 API Key。' : 'AI 配置不完整。');
    }

    final messages = <Map<String, dynamic>>[
      if (history == null)
        {'role': 'system', 'content': _systemPrompt(noteContext, outputTemplate)}
      else
        ..._pruneHistory(history).map((m) => Map<String, dynamic>.from(m)),
      {
        'role': 'user',
        'content': history == null ? prompt : _withFreshContext(prompt, noteContext),
      },
    ];

    final client = HttpClient()..connectionTimeout = const Duration(seconds: 30);
    try {
      for (var step = 0; step < maxSteps; step++) {
        if (_cancelled) return;

        // Whether this step's prose already went to the UI token by token. A
        // streamed answer must NOT also be emitted as a whole `AgentText`, or
        // every reply would appear twice: once typed out, once pasted again.
        var streamed = false;
        final message = await _chat(
          client,
          messages,
          onDelta: (delta) {
            streamed = true;
            if (!_cancelled && !out.isClosed) out.add(AgentTextDelta(delta));
          },
        );
        final text = _visibleText((message['content'] as String?) ?? '');
        final rawCalls = (message['tool_calls'] as List?) ?? const [];

        if (rawCalls.isEmpty) {
          if (text.isNotEmpty && !streamed) out.add(AgentText(text));
          // The answer has to go into the transcript, or the next question is
          // replayed as two user turns in a row and the model cannot tell what
          // it already said. Empty content is skipped: some gateways reject an
          // assistant turn with nothing in it.
          if (text.isNotEmpty) {
            messages.add({'role': 'assistant', 'content': text});
          }
          out.add(const AgentFinished());
          return;
        }

        if (text.isNotEmpty && !streamed) out.add(AgentText(text));

        // Echo the assistant turn back verbatim: the API requires the tool
        // calls it produced to appear in the history before their results.
        messages.add({
          'role': 'assistant',
          'content': text,
          'tool_calls': rawCalls,
        });

        if (rawCalls.length > maxToolCallsPerStep) {
          out.add(AgentNotice(
            '这一步模型想调用 ${rawCalls.length} 个工具，超过上限 $maxToolCallsPerStep，'
            '只执行前 $maxToolCallsPerStep 个。',
          ));
        }

        for (final raw in rawCalls.take(maxToolCallsPerStep)) {
          if (_cancelled) return;
          final call = raw as Map<String, dynamic>;
          final id = (call['id'] ?? '').toString();
          final function = (call['function'] as Map?) ?? const {};
          final name = (function['name'] ?? '').toString();
          final args = _parseArguments(function['arguments']);

          out.add(AgentToolStarted(name: name, arguments: args));

          final result = await _runTool(name, args);
          messages.add({
            'role': 'tool',
            'tool_call_id': id,
            'content': result.content,
          });
          out.add(AgentToolFinished(
            name: name,
            content: result.content,
            isError: result.isError,
          ));
        }

        // Every tool_call the assistant turn echoed back MUST be answered by
        // exactly one tool message, or the next request is rejected with
        // "insufficient tool messages following tool_calls message" (400) and
        // the run dies. Skipped calls get a synthetic result so the protocol
        // stays valid and the model can re-request them next step.
        for (final raw in rawCalls.skip(maxToolCallsPerStep)) {
          final call = raw as Map<String, dynamic>;
          final id = (call['id'] ?? '').toString();
          messages.add({
            'role': 'tool',
            'tool_call_id': id,
            'content': '这一步要调用的工具超过单步上限 $maxToolCallsPerStep 个，'
                '这个调用被跳过了。如果仍然需要它，请在下一步重新发起。',
          });
        }
      }

      out.add(AgentNotice('达到 $maxSteps 步上限，先停在这里。可以让我继续。'));
      out.add(const AgentFinished());
    } finally {
      lastMessages = _condenseForHistory(messages);
      client.close(force: true);
    }
  }

  /// Trims oversized tool results before a transcript is kept for the next
  /// turn. The capped run already sent the full text upstream; the trim only
  /// stops a follow-up question from dragging half a megabyte of scraped pages
  /// back into context.
  static const int _historyToolCharLimit = 2000;

  List<Map<String, dynamic>> _condenseForHistory(
    List<Map<String, dynamic>> messages,
  ) {
    return [
      for (final m in messages)
        if (m['role'] == 'tool' &&
            m['content'] is String &&
            (m['content'] as String).length > _historyToolCharLimit)
          {
            'role': 'tool',
            'tool_call_id': m['tool_call_id'],
            'content':
                '${(m['content'] as String).substring(0, _historyToolCharLimit)}'
                '…（内容过长，续跑时已截断）',
          }
        else
          Map<String, dynamic>.from(m),
    ];
  }

  /// Cuts a previous conversation down to what still fits in one request.
  ///
  /// Trimming has to happen on **turn boundaries**, never mid-turn: an
  /// assistant message carrying `tool_calls` must be followed by one `tool`
  /// message per call, or the next request is rejected with "insufficient tool
  /// messages following tool_calls message". So the slice always starts at a
  /// `user` message, which by construction is the start of a complete turn.
  /// The system prompt is kept as-is: it holds the folder layout, the rules and
  /// the note the conversation began with.
  List<Map<String, dynamic>> _pruneHistory(
    List<Map<String, dynamic>> history,
  ) {
    if (history.isEmpty) return const [];
    final system = history.first['role'] == 'system' ? history.first : null;
    final body = system == null ? history : history.sublist(1);

    final starts = <int>[
      for (var i = 0; i < body.length; i++)
        if (body[i]['role'] == 'user') i,
    ];
    // No user turn to align to (a transcript handed in by a test, say): keep
    // everything rather than risk orphaning a tool result.
    if (starts.isEmpty) {
      return [if (system != null) system, ...body];
    }

    var chosen = starts.last;
    var chars = 0;
    var turns = 0;
    for (var k = starts.length - 1; k >= 0; k--) {
      final from = starts[k];
      final to = k + 1 < starts.length ? starts[k + 1] : body.length;
      var size = 0;
      for (var i = from; i < to; i++) {
        size += _messageSize(body[i]);
      }
      // The newest turn is kept even when it alone blows the budget; dropping
      // it would leave the model with no question to answer.
      final isNewest = k == starts.length - 1;
      if (!isNewest &&
          (chars + size > maxHistoryChars || turns + 1 > maxHistoryTurns)) {
        break;
      }
      chars += size;
      turns++;
      chosen = from;
    }

    return [if (system != null) system, ...body.sublist(chosen)];
  }

  /// Rough size of one message. `tool_calls` arguments are part of the payload,
  /// so measuring `content` alone would undercount a create_note call that
  /// carries a whole note body.
  static int _messageSize(Map<String, dynamic> message) {
    try {
      return jsonEncode(message).length;
    } catch (_) {
      return (message['content'] as String?)?.length ?? 0;
    }
  }

  /// Re-states the open note for a follow-up turn.
  ///
  /// The system prompt (sent with the first turn) already described the note
  /// the user came from, so the caller only passes [noteContext] when the note
  /// changed. Labelling it in the user turn keeps the provider happy — a second
  /// system message mid-conversation is rejected by some gateways.
  static String _withFreshContext(String prompt, String? noteContext) {
    final context = noteContext?.trim();
    if (context == null || context.isEmpty) return prompt;
    return '【用户当前打开的笔记（最新内容）】\n$context\n\n---\n$prompt';
  }

  Future<AgentToolResult> _runTool(String name, Map<String, dynamic> args) async {
    final tool = _byName[name];
    if (tool == null) {
      return AgentToolResult.error(
        '没有叫 `$name` 的工具。可用工具：${tools.map((t) => t.name).join('、')}。',
      );
    }
    if (tool.writes && approve != null) {
      final ok = await approve!(tool, args);
      if (!ok) {
        return const AgentToolResult.error('用户拒绝了这次修改，文件没有改动。');
      }
    }
    return guardToolCall(tool, args);
  }

  /// Retries the provider's "not now" answers: 429 (rate limit) and 5xx.
  ///
  /// Re-sending is safe: the tools ran in an earlier step and their results are
  /// already in [messages], so a retry cannot double-execute a write — it just
  /// asks the same question again.
  Future<Map<String, dynamic>> _chat(
    HttpClient client,
    List<Map<String, dynamic>> messages, {
    required void Function(String delta) onDelta,
  }) async {
    for (var attempt = 0; ; attempt++) {
      await _pace();
      var streamed = false;
      try {
        return await _chatOnce(
          client,
          messages,
          onDelta: (delta) {
            streamed = true;
            onDelta(delta);
          },
        );
      } on _RetryableResponse catch (error) {
        // Retryable statuses arrive before any body, so `streamed` should never
        // be true here. If it somehow is, re-sending would print the answer
        // twice — fail loudly instead.
        if (streamed || attempt >= retryDelays.length) {
          throw AgentException(_translateStatus(error.status, error.body));
        }
        // Providers usually say how long to wait; when they don't, back off.
        final wait = error.retryAfter ?? retryDelays[attempt];
        if (error.status == 429) _enterSlowMode();
        onNotice?.call(
          '服务商${error.status == 429 ? '限流' : '繁忙'}（${error.status}），'
          '${wait.inSeconds > 0 ? '${wait.inSeconds} 秒后' : ''}自动重试'
          '（第 ${attempt + 1}/${retryDelays.length} 次）',
        );
        if (wait > Duration.zero) await Future<void>.delayed(wait);
        if (_cancelled) throw const AgentException('已停止。');
      }
    }
  }

  /// Keeps consecutive requests [rateLimitGap] apart once the provider has
  /// said "too fast". One request per step means a strict free tier (one
  /// request per second or worse) would otherwise fail on step two of every
  /// single run.
  Future<void> _pace() async {
    final last = _lastRequestAt;
    if (_slowMode && rateLimitGap > Duration.zero && last != null) {
      final elapsed = DateTime.now().difference(last);
      if (elapsed < rateLimitGap) {
        await Future<void>.delayed(rateLimitGap - elapsed);
        if (_cancelled) throw const AgentException('已停止。');
      }
    }
    _lastRequestAt = DateTime.now();
  }

  void _enterSlowMode() {
    if (_slowMode) return;
    _slowMode = true;
    if (rateLimitGap <= Duration.zero) return;
    final seconds = (rateLimitGap.inMilliseconds / 1000).toStringAsFixed(1);
    onNotice?.call('已切到慢速模式：这轮后面每个请求前多等 $seconds 秒，别再撞限流。'
        '免费档模型限流是按秒算的，慢一点能跑完。');
  }

  /// Starts of the `{"index": N, "delta": …}` SSE frames that Zhipu's free
  /// tiers glue into `message.content` instead of returning as protocol fields.
  static final RegExp _sseNoiseMarker = RegExp(r'\{\s*"index"\s*:\s*\d+');

  Future<Map<String, dynamic>> _chatOnce(
    HttpClient client,
    List<Map<String, dynamic>> messages, {
    required void Function(String delta) onDelta,
  }) async {
    final uri = Uri.parse('${_trimSlash(config.baseUrl)}/chat/completions');

    final body = utf8.encode(jsonEncode({
      'model': config.model.trim(),
      // Streaming is on for every step, not just the last one: which step is
      // the last is only known after the answer arrives. A tool round simply
      // streams its "let me look that up" prose first.
      'stream': true,
      'temperature': 0.2,
      'messages': messages,
      'tools': [for (final tool in tools) tool.toSchema()],
      'tool_choice': 'auto',
    }));

    final int status;
    final HttpClientResponse response;
    Duration? retryAfter;
    try {
      final request = await client.postUrl(uri);
      request.headers.set(HttpHeaders.contentTypeHeader, 'application/json');
      request.headers
          .set(HttpHeaders.acceptHeader, 'text/event-stream, application/json');
      final key = config.apiKey.trim();
      if (key.isNotEmpty) {
        request.headers.set(HttpHeaders.authorizationHeader, 'Bearer $key');
      }
      request.headers.set('HTTP-Referer', 'https://github.com/refactoringhq/tolaria');
      request.headers.set('X-Title', 'Tolaria Android');

      // Some gateways only look at Content-Length; chunked bodies arrive empty.
      request.contentLength = body.length;
      request.add(body);

      response = await request.close();
      status = response.statusCode;
      retryAfter = _retryAfterOf(
        response.headers.value(HttpHeaders.retryAfterHeader),
      );
    } on SocketException catch (error) {
      // A bare "SocketException: Connection refused" tells the user nothing
      // about which address was tried, and on a phone the address is usually
      // the mistake (10.0.2.2 vs a LAN IP, or a port that moved).
      throw AgentException(
        '连不上 ${uri.host}:${uri.port}。检查 Base URL、端口，以及手机和电脑是否在同一个网络。'
        '（${error.osError?.message ?? error.message}）',
      );
    }

    if (status == 429 || status >= 500) {
      throw _RetryableResponse(status, await _readAll(response), retryAfter);
    }
    if (status >= 400) {
      throw AgentException(_translateStatus(status, await _readAll(response)));
    }

    final mime = response.headers.contentType?.mimeType ?? '';
    // A gateway that ignores `stream: true` answers with one JSON object.
    // Parsing it is cheaper than failing, and the caller still shows the text
    // (as a whole `AgentText`, because no deltas were emitted).
    if (mime.contains('application/json')) {
      return _decodeWholeBody(await _readAll(response));
    }

    var text = '';
    var emitted = 0;
    final calls = <int, Map<String, dynamic>>{};
    final rawLines = StringBuffer();

    await for (final line
        in response.transform(utf8.decoder).transform(const LineSplitter())) {
      if (_cancelled) break;
      if (!line.startsWith('data:')) continue;
      final payload = line.substring(5).trim();
      if (payload.isEmpty) continue;
      if (payload == '[DONE]') break;
      rawLines.writeln(payload);

      Object? decoded;
      try {
        decoded = jsonDecode(payload);
      } catch (_) {
        continue; // A malformed keep-alive must not kill the answer.
      }
      if (decoded is! Map) continue;
      final choices = decoded['choices'];
      if (choices is! List || choices.isEmpty) continue;
      final first = choices.first;
      if (first is! Map) continue;

      final delta = first['delta'];
      if (delta is Map) {
        final piece = delta['content'];
        if (piece is String && piece.isNotEmpty) {
          text += piece;
          emitted = _pumpVisible(text, emitted, onDelta);
        }
        _accumulateToolCalls(calls, delta['tool_calls']);
      }
    }

    // Flush whatever the hold-back kept: this is where a legit trailing
    // `{"index": 0}` (not noise) finally reaches the screen.
    final clean = _visibleText(text);
    if (clean.length > emitted) onDelta(clean.substring(emitted));

    if (clean.isEmpty && calls.isEmpty) {
      throw AgentException(
        '接口没有返回任何内容：${_condense(rawLines.isEmpty ? '（空响应体）' : rawLines.toString())}',
      );
    }

    return {
      'role': 'assistant',
      'content': clean,
      // Ordered by the index the provider used, so call order is preserved.
      if (calls.isNotEmpty)
        'tool_calls': [for (final index in calls.keys.toList()..sort()) calls[index]],
    };
  }

  /// Emits the safe prefix of [text] and returns the new emitted position.
  ///
  /// Withheld: anything from a `{` that has no closing brace yet (an SSE frame
  /// glued into `content` always starts with one, and a frame split across two
  /// deltas would otherwise be shown half-written), and anything from a
  /// recognised noise frame onward. Text already emitted cannot be unsent, so
  /// the check has to happen before it goes out, not after.
  static int _pumpVisible(
    String text,
    int emitted,
    void Function(String delta) onDelta,
  ) {
    var end = text.length;
    final lastBrace = text.lastIndexOf('{');
    if (lastBrace >= emitted && text.indexOf('}', lastBrace) < 0) {
      // Dangling `{`: hold it until more deltas say what it is.
      end = lastBrace;
    }
    for (final match in _sseNoiseMarker.allMatches(text)) {
      // `>=` and not `>`: a frame that starts exactly where the last emit
      // ended is the common case, and `>` would let the whole frame through.
      if (match.start >= emitted && match.start < end) {
        end = match.start;
        break;
      }
    }
    if (end <= emitted) return emitted;
    onDelta(text.substring(emitted, end));
    return end;
  }

  /// Reassembles `tool_calls` from SSE deltas.
  ///
  /// This is the part that made streaming look unsafe before: the arguments
  /// string arrives in fragments (`{"pa` + `th":"a.md"}`) and each call is
  /// identified only by its `index`. The rules that matter:
  ///
  ///  * accumulate per `index`, never per `id` — the id itself may be fragmentary
  ///    in early chunks and only settles once the whole call is in;
  ///  * append `arguments` (concatenation is the only correct reassembly);
  ///  * take `name` once, when it is non-empty — providers send it whole, and
  ///    appending it twice would yield `list_noteslist_notes`.
  void _accumulateToolCalls(
    Map<int, Map<String, dynamic>> acc,
    Object? rawCalls,
  ) {
    if (rawCalls is! List) return;
    for (final raw in rawCalls) {
      if (raw is! Map) continue;
      final index = raw['index'] is num ? (raw['index'] as num).toInt() : acc.length;
      final entry = acc.putIfAbsent(
        index,
        () => <String, dynamic>{
          'id': '',
          'type': 'function',
          'function': <String, dynamic>{'name': '', 'arguments': ''},
        },
      );
      final id = raw['id'];
      if (id is String && id.isNotEmpty) entry['id'] = id;
      final function = raw['function'];
      if (function is! Map) continue;
      final target = entry['function'] as Map<String, dynamic>;
      final name = function['name'];
      if (name is String &&
          name.isNotEmpty &&
          (target['name'] as String).isEmpty) {
        target['name'] = name;
      }
      final args = function['arguments'];
      if (args is String && args.isNotEmpty) {
        target['arguments'] = '${target['arguments']}$args';
      }
    }
  }

  /// Fallback for a gateway that answered with a single JSON object.
  Map<String, dynamic> _decodeWholeBody(String raw) {
    Map<String, dynamic> decoded;
    try {
      decoded = jsonDecode(raw) as Map<String, dynamic>;
    } catch (_) {
      throw const AgentException('接口返回的不是 JSON，先检查 Base URL 是否指到了 /v1 这一级。');
    }
    final choices = decoded['choices'] as List?;
    if (choices == null || choices.isEmpty) {
      throw AgentException('接口没有返回任何结果：${_condense(raw)}');
    }
    final message = (choices.first as Map)['message'];
    if (message is! Map) {
      throw AgentException('接口返回结构不认识：${_condense(raw)}');
    }
    return Map<String, dynamic>.from(message);
  }

  static Future<String> _readAll(HttpClientResponse response) =>
      response.transform(utf8.decoder).join();

  Map<String, dynamic> _parseArguments(Object? raw) {
    if (raw is Map) return Map<String, dynamic>.from(raw);
    final text = (raw ?? '').toString().trim();
    if (text.isEmpty) return const {};
    try {
      final decoded = jsonDecode(text);
      return decoded is Map ? Map<String, dynamic>.from(decoded) : const {};
    } catch (_) {
      // Let the tool layer report the missing arguments instead of throwing.
      return const {};
    }
  }

  String _systemPrompt(String? noteContext, String? outputTemplate) {
    final buffer = StringBuffer()
      ..writeln('你是 Tolaria 知识库的助手，运行在用户的手机上。')
      ..writeln(describeVault(vault))
      ..writeln()
      ..writeln('规则：')
      ..writeln('1. 需要笔记内容时必须调用工具读取，不要凭目录猜测正文。')
      ..writeln('2. 路径一律用 list_notes / search_notes 返回的**原样**相对路径，'
          '不要自己加目录前缀——知识库通常是扁平的，`Skill1/xxx.md`、`Skill/xxx.md` '
          '这类前缀多半不存在。read_note 报「找不到」时，直接改用错误里列出的候选路径，'
          '或重新 list_notes 确认；**不要拿同一个错路径再试一次**。')
      ..writeln('3. 修改文件前先用 read_note 确认原文；edit_note 的 old_string 要能唯一匹配。')
      ..writeln('4. 每次只做用户要求的事，不要顺手重排、批量改写或删除。')
      ..writeln('5. 新建笔记时必须给 create_note 传 type（分类），从上面列出的分类里选；'
          '没有合适的就先 read_note 读 `Type.md` 或 `分类总览.md` 看知识库的分类规范，'
          '再选一个最接近的。绝不能建没有分类的笔记。')
      ..writeln('6. 用户要写文案、脚本、选题、拆书、做计划、复盘这类「有方法论的活」时，'
          '先调 list_notes(type: "Skill") 看知识库里有哪些现成 SOP，'
          '挑一篇最相关的 read_note 读完，再按它的步骤做。'
          '实在没有相关的 SOP 才用通用方法，并在回答开头说明「这次没找到对应 SOP，'
          '按通用方法做」。不要凭印象编一套流程。')
      ..writeln('7. 这台设备没有 shell，不能跑命令、不能执行脚本。需要这些时直说，'
          '并建议回到电脑上做。')
      ..writeln('8. 回答用中文，短句，先给结论。');
    if (outputTemplate != null && outputTemplate.trim().isNotEmpty) {
      buffer
        ..writeln()
        ..writeln('输出格式要求（务必遵守，除非用户当场另有指示）：')
        ..writeln(outputTemplate.trim());
    }
    if (noteContext != null && noteContext.trim().isNotEmpty) {
      buffer
        ..writeln()
        ..writeln('用户当前打开的笔记内容如下（可以直接用，不必再读一遍）：')
        ..writeln(noteContext.trim());
    }
    return buffer.toString();
  }

  static String _translateStatus(int status, String body) {
    switch (status) {
      case 400:
        return '请求被拒绝（400）：模型名或参数不对。${_condense(body)}';
      case 401:
        return 'API Key 无效（401），检查是否复制完整。';
      case 402:
        return '账户余额不足（402），先去服务商控制台充值。';
      case 403:
        return '没有权限（403），这个 Key 可能没开通该模型。';
      case 404:
        return '接口不存在（404），Base URL 可能少了或多了 /v1。';
      case 429:
        return '请求太频繁（429），等几秒再试。免费档模型（如智谱的 flash 系列）'
            '限流往往按秒算，一路连发必撞；换个宽松些的模型通常立刻就好。'
            '服务商原话：${_condense(body)}';
      default:
        if (status >= 500) return '服务商出错了（$status），稍后重试。';
        return '请求失败（$status）：${_condense(body)}';
    }
  }

  static String _condense(String body) {
    final text = body.replaceAll(RegExp(r'\s+'), ' ').trim();
    return text.length > 200 ? '${text.substring(0, 200)}…' : text;
  }

  static String _trimSlash(String value) =>
      value.endsWith('/') ? value.substring(0, value.length - 1) : value;

  /// Strips raw streaming frames that some gateways glue into
  /// `message.content` instead of returning them as protocol fields.
  ///
  /// Seen live on Zhipu's free flash tiers: a tool-calling turn came back with
  /// the answer text followed by
  /// `{"index":0,"finish_reason":"tool_calls","delta":{…}}` — an SSE frame,
  /// stringified, as content. It landed in the chat bubble and in the
  /// transcript, so the model then saw its own noise and would repeat it.
  /// Only frames carrying `delta`/`finish_reason` are removed: a model that is
  /// legitimately explaining JSON keeps its braces.
  static String _visibleText(String raw) {
    var text = raw.trim();
    final marker = RegExp(r'\{\s*"index"\s*:\s*\d+');
    while (true) {
      final match = marker.firstMatch(text);
      if (match == null) break;
      final end = _matchingBrace(text, match.start);
      if (end < 0) break;
      final frame = text.substring(match.start, end + 1);
      if (!frame.contains('"delta"') && !frame.contains('"finish_reason"')) {
        break;
      }
      text = (text.substring(0, match.start) + text.substring(end + 1)).trim();
    }
    return text;
  }

  /// Index of the `}` closing the `{` at [start], ignoring braces in strings.
  static int _matchingBrace(String text, int start) {
    var depth = 0;
    var inString = false;
    var escaped = false;
    for (var i = start; i < text.length; i++) {
      final char = text[i];
      if (escaped) {
        escaped = false;
        continue;
      }
      if (char == '\\' && inString) {
        escaped = true;
        continue;
      }
      if (char == '"') {
        inString = !inString;
        continue;
      }
      if (inString) continue;
      if (char == '{') depth++;
      if (char == '}') {
        depth--;
        if (depth == 0) return i;
      }
    }
    return -1;
  }

  /// `Retry-After` is either a delay in seconds or an HTTP date. Only the
  /// seconds form is worth honouring — a date needs a clock we don't know is
  /// right, and a phone that is off by minutes would stall for minutes.
  static Duration? _retryAfterOf(String? value) {
    if (value == null) return null;
    final seconds = int.tryParse(value.trim());
    if (seconds == null) return null;
    return Duration(seconds: seconds.clamp(0, 15));
  }
}

// ------------------------------------------------------------------- events

sealed class AgentEvent {
  const AgentEvent();
}

/// Assistant prose. Emitted before tool rounds and for the final answer.
class AgentText extends AgentEvent {
  const AgentText(this.text);
  final String text;
}

/// One increment of the assistant's prose, while it is still arriving.
///
/// Only emitted when the provider actually streams. A complete [AgentText] is
/// still used for gateways that answer with a single JSON object, so consumers
/// must handle both: append deltas, and take [AgentText] as a whole bubble.
class AgentTextDelta extends AgentEvent {
  const AgentTextDelta(this.text);
  final String text;
}

class AgentToolStarted extends AgentEvent {
  const AgentToolStarted({required this.name, required this.arguments});
  final String name;
  final Map<String, dynamic> arguments;
}

class AgentToolFinished extends AgentEvent {
  const AgentToolFinished({
    required this.name,
    required this.content,
    required this.isError,
  });

  final String name;
  final String content;
  final bool isError;
}

/// Non-fatal information: step cap reached, too many calls in one step.
class AgentNotice extends AgentEvent {
  const AgentNotice(this.text);
  final String text;
}

class AgentFinished extends AgentEvent {
  const AgentFinished();
}

class AgentException implements Exception {
  const AgentException(this.message);
  final String message;

  @override
  String toString() => message;
}

/// A 429/5xx answer: the same request will probably work in a moment, unlike a
/// 400/401/403 which fails identically however many times it is sent. Kept
/// private because the only thing that should act on it is [_chat]'s backoff.
class _RetryableResponse implements Exception {
  const _RetryableResponse(this.status, this.body, this.retryAfter);
  final int status;
  final String body;
  final Duration? retryAfter;
}
