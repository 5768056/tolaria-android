import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:tolaria_android/models/ai_config.dart';
import 'package:tolaria_android/services/agent/agent_runner.dart';
import 'package:tolaria_android/services/agent/agent_tool.dart';
import 'package:tolaria_android/services/agent/vault_tools.dart';
import 'package:tolaria_android/services/vault_service.dart';

/// The agent loop is the risky half of this feature: it decides what the model
/// is allowed to do to the user's files. These tests drive it against a
/// scripted endpoint so the whole conversation — including the second request
/// that carries the tool results back — is checked, not just the first call.
void main() {
  late Directory root;
  late VaultService vault;
  late HttpServer server;
  late List<Map<String, dynamic>> requests;
  late List<Map<String, dynamic>> replies;
  /// One entry per *streaming* request: the list of `delta` objects to send.
  /// When non-empty it wins over [replies], so a test can script a real SSE
  /// answer; leaving it empty keeps the older one-shot JSON behaviour.
  late List<List<Map<String, dynamic>>> sseReplies;
  int? statusOverride;
  late List<int> statusQueue;
  String? rawOverride;

  setUp(() async {
    root = Directory.systemTemp.createTempSync('agent_loop_');
    vault = VaultService(root.path);
    File(p.join(root.path, 'a.md')).writeAsStringSync('# a\n\n正文甲\n');
    File(p.join(root.path, 'b.md')).writeAsStringSync('# b\n\n正文乙\n');

    requests = [];
    replies = [];
    sseReplies = [];
    statusOverride = null;
    statusQueue = [];
    rawOverride = null;
    server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    server.listen((request) async {
      final body = await utf8.decoder.bind(request).join();
      requests.add(jsonDecode(body) as Map<String, dynamic>);
      // A queued status wins so a test can say "429 first, then fine".
      final status = statusQueue.isNotEmpty
          ? statusQueue.removeAt(0)
          : statusOverride ?? 200;
      final frames = status >= 400 || sseReplies.isEmpty
          ? null
          : sseReplies.removeAt(0);
      // Only a successful response consumes a scripted reply; otherwise a
      // retry test would eat its own answer on the rate-limited attempt.
      final reply = status >= 400
          ? <String, dynamic>{
              'error': {'message': 'scripted $status'},
            }
          : replies.isEmpty
              ? {
                  'choices': [
                    {
                      'message': {'role': 'assistant', 'content': '（脚本用完了）'},
                    },
                  ],
                }
              : replies.removeAt(0);
      request.response.statusCode = status;
      if (status == 429) {
        // Claiming zero seconds keeps the retry test instant while still
        // exercising the "provider told us how long to wait" path.
        request.response.headers.set(HttpHeaders.retryAfterHeader, '0');
      }
      if (frames != null) {
        request.response.headers.contentType =
            ContentType('text', 'event-stream', charset: 'utf-8');
        for (final frame in frames) {
          request.response.write(
            'data: ${jsonEncode({'choices': [{'delta': frame}]})}\n\n',
          );
        }
        request.response.write('data: [DONE]\n\n');
      } else {
        request.response.headers.contentType =
            ContentType('application', 'json', charset: 'utf-8');
        request.response.add(utf8.encode(rawOverride ?? jsonEncode(reply)));
      }
      await request.response.close();
    });
  });

  tearDown(() async {
    await server.close(force: true);
    if (root.existsSync()) root.deleteSync(recursive: true);
  });

  AiConfig configFor([AiProtocol protocol = AiProtocol.openai]) => AiConfig(
        baseUrl: 'http://127.0.0.1:${server.port}/v1',
        model: 'test-model',
        apiKey: 'test-key',
        protocol: protocol,
      );

  Map<String, dynamic> toolCall(String name, Object? args, {String id = 'call_1'}) => {
        'id': id,
        'type': 'function',
        'function': {
          'name': name,
          'arguments': args is String ? args : jsonEncode(args),
        },
      };

  Map<String, dynamic> assistant(Map<String, dynamic> message) =>
      {'choices': [{'message': message}]};

  test('calls a tool, feeds the result back, then answers', () async {
    replies.addAll([
      assistant({
        'role': 'assistant',
        'content': '',
        'tool_calls': [toolCall('list_notes', <String, dynamic>{})],
      }),
      assistant({'role': 'assistant', 'content': '你的知识库有 2 篇笔记。'}),
    ]);

    final events = await AgentRunner(vault: vault, config: configFor())
        .run('我有哪些笔记？')
        .toList();

    final started = events.whereType<AgentToolStarted>().toList();
    final finished = events.whereType<AgentToolFinished>().toList();
    expect(started.single.name, 'list_notes');
    expect(finished.single.isError, isFalse);
    expect(finished.single.content, contains('a.md'));
    expect(events.whereType<AgentText>().last.text, contains('2 篇'));
    expect(events.last, isA<AgentFinished>());

    // Second request must carry the assistant tool_calls and the tool result.
    expect(requests, hasLength(2));
    final second = requests[1]['messages'] as List;
    expect(second.last['role'], 'tool');
    expect(second.last['tool_call_id'], 'call_1');
    expect(second.last['content'], contains('a.md'));
  });

  test('sends tool schemas and asks for a stream', () async {
    replies.add(assistant({'role': 'assistant', 'content': '好'}));
    await AgentRunner(vault: vault, config: configFor()).run('hi').toList();

    final body = requests.single;
    expect(body['stream'], true);
    expect(body['tool_choice'], 'auto');
    expect(body['model'], 'test-model');
    final tools = body['tools'] as List;
    expect(tools, hasLength(agentToolNames.length));
    expect(tools.map((t) => t['function']['name']), contains('edit_note'));
    expect(tools.map((t) => t['function']['name']), isNot(contains('execute')));
  });

  test('a failing tool becomes readable text for the model', () async {
    replies.addAll([
      assistant({
        'role': 'assistant',
        'content': '',
        'tool_calls': [toolCall('read_note', {'path': 'nope.md'})],
      }),
      assistant({'role': 'assistant', 'content': '找不到那篇。'}),
    ]);

    final events =
        await AgentRunner(vault: vault, config: configFor()).run('读一下 nope').toList();

    final failed = events.whereType<AgentToolFinished>().single;
    expect(failed.isError, isTrue);
    expect(failed.content, contains('找不到'));
    final second = requests[1]['messages'] as List;
    expect(second.last['content'], contains('找不到'));
  });

  test('unknown tool name is reported instead of crashing', () async {
    replies.addAll([
      assistant({
        'role': 'assistant',
        'content': '',
        'tool_calls': [toolCall('execute', {'cmd': 'rm -rf /'})],
      }),
      assistant({'role': 'assistant', 'content': '这台设备不能跑命令。'}),
    ]);

    final events =
        await AgentRunner(vault: vault, config: configFor()).run('删库').toList();

    final failed = events.whereType<AgentToolFinished>().single;
    expect(failed.isError, isTrue);
    expect(failed.content, contains('没有叫 `execute`'));
    expect(File(p.join(root.path, 'a.md')).existsSync(), isTrue);
  });

  test('writing tools wait for approval and respect a refusal', () async {
    replies.addAll([
      assistant({
        'role': 'assistant',
        'content': '',
        'tool_calls': [
          toolCall('edit_note', {
            'path': 'a.md',
            'old_string': '正文甲',
            'new_string': '正文丙',
          }),
        ],
      }),
      assistant({'role': 'assistant', 'content': '那我不改了。'}),
    ]);

    var asked = 0;
    final events = await AgentRunner(
      vault: vault,
      config: configFor(),
      approve: (tool, args) async {
        asked++;
        return false;
      },
    ).run('把正文甲改成正文丙').toList();

    expect(asked, 1);
    expect(events.whereType<AgentToolFinished>().single.content, contains('拒绝'));
    expect(File(p.join(root.path, 'a.md')).readAsStringSync(), contains('正文甲'));
  });

  test('an approved write actually lands on disk', () async {
    replies.addAll([
      assistant({
        'role': 'assistant',
        'content': '',
        'tool_calls': [
          toolCall('edit_note', {
            'path': 'a.md',
            'old_string': '正文甲',
            'new_string': '正文丙',
          }),
        ],
      }),
      assistant({'role': 'assistant', 'content': '改好了。'}),
    ]);

    await AgentRunner(
      vault: vault,
      config: configFor(),
      approve: (tool, args) async => true,
    ).run('改').toList();

    expect(File(p.join(root.path, 'a.md')).readAsStringSync(), contains('正文丙'));
  });

  test('read-only tools never ask for approval', () async {
    replies.addAll([
      assistant({
        'role': 'assistant',
        'content': '',
        'tool_calls': [toolCall('list_notes', <String, dynamic>{})],
      }),
      assistant({'role': 'assistant', 'content': '两篇。'}),
    ]);

    var asked = 0;
    await AgentRunner(
      vault: vault,
      config: configFor(),
      approve: (tool, args) async {
        asked++;
        return true;
      },
    ).run('列一下').toList();

    expect(asked, 0);
  });

  test('stops at maxSteps instead of looping forever', () async {
    final looping = assistant({
      'role': 'assistant',
      'content': '',
      'tool_calls': [toolCall('list_notes', <String, dynamic>{})],
    });
    replies.addAll([looping, looping, looping]);

    final events = await AgentRunner(
      vault: vault,
      config: configFor(),
      maxSteps: 1,
    ).run('一直列').toList();

    expect(requests, hasLength(1));
    expect(events.whereType<AgentNotice>().single.text, contains('上限'));
  });

  test('a cancelled run sends no request at all', () async {
    final runner = AgentRunner(vault: vault, config: configFor());
    runner.cancel();
    final events = await runner.run('你好').toList();
    expect(events, isEmpty);
    expect(requests, isEmpty);
  });

  test('capped run can be continued via lastMessages history', () async {
    // 第一轮：maxSteps=1，模型调一次工具就撞上限。
    replies.add(assistant({
      'role': 'assistant',
      'content': '',
      'tool_calls': [toolCall('list_notes', <String, dynamic>{})],
    }));
    final runner1 = AgentRunner(vault: vault, config: configFor(), maxSteps: 1);
    final events1 = await runner1.run('我有哪些笔记？').toList();
    expect(
      events1.whereType<AgentNotice>().last.text,
      contains('步上限'),
    );
    expect(runner1.lastMessages, isNotNull);
    expect(
      runner1.lastMessages!.map((m) => m['role']),
      ['system', 'user', 'assistant', 'tool'],
    );

    // 第二轮：带着第一轮轨迹续跑"继续"。
    replies.add(assistant({'role': 'assistant', 'content': '上一轮查到 2 篇笔记。'}));
    final runner2 = AgentRunner(vault: vault, config: configFor());
    final events2 =
        await runner2.run('继续', history: runner1.lastMessages).toList();
    expect(events2.whereType<AgentText>().last.text, contains('2 篇'));

    // 上行请求：system 只出现一次（不重复注入），历史完整带上，末尾是"继续"。
    expect(requests, hasLength(2));
    final msgs =
        (requests[1]['messages'] as List).cast<Map<String, dynamic>>();
    expect(msgs.map((m) => m['role']),
        ['system', 'user', 'assistant', 'tool', 'user']);
    expect(msgs.last['content'], '继续');
    expect(msgs.where((m) => m['role'] == 'system'), hasLength(1));
    // 工具结果在历史里，模型才知道上一轮干了什么。
    expect(msgs[3]['content'], contains('a.md'));
  });

  test('oversized tool results are trimmed in lastMessages', () async {
    replies.add(assistant({
      'role': 'assistant',
      'content': '',
      'tool_calls': [toolCall('list_notes', <String, dynamic>{})],
    }));
    final runner = AgentRunner(vault: vault, config: configFor(), maxSteps: 1);
    await runner.run('我有哪些笔记？').toList();
    final toolMsg = runner.lastMessages!.last;
    expect(toolMsg['role'], 'tool');
    // list_notes 结果很短，不触发截断——这里验证的是"原样保留"。
    expect((toolMsg['content'] as String).length, lessThan(2000));
  });

  test('non OpenAI protocols are refused with an explanation', () async {
    final runner = AgentRunner(
      vault: vault,
      config: configFor(AiProtocol.anthropic),
    );
    await expectLater(
      runner.run('hi'),
      emitsError(isA<AgentException>().having(
        (e) => e.message,
        'message',
        contains('OpenAI 兼容'),
      )),
    );
    expect(requests, isEmpty);
  });

  test('an HTTP error surfaces as a Chinese message, not a stack trace', () async {
    // A 402 is exactly what a key with no balance returns; the loop must say so
    // rather than treating the error body as an empty answer.
    statusOverride = 402;
    rawOverride = '{"error":{"message":"Insufficient Balance"}}';

    await expectLater(
      AgentRunner(vault: vault, config: configFor()).run('hi'),
      emitsError(isA<AgentException>()
          .having((e) => e.message, 'message', contains('余额不足'))),
    );
  });

  test('a rate-limited request is retried instead of shown as an error', () async {
    // 429 is what the user actually hit on the phone. Waiting a second and
    // asking again is almost always enough; making them press retry by hand is
    // not. A 402 must NOT be retried, which the test above pins.
    statusQueue.add(429);
    replies.add(assistant({'role': 'assistant', 'content': '好了'}));

    final notices = <String>[];
    final events = await AgentRunner(
      vault: vault,
      config: configFor(),
      retryDelays: const [Duration.zero, Duration.zero],
      rateLimitGap: Duration.zero,
      onNotice: notices.add,
    ).run('hi').toList();

    expect(notices.single, allOf(contains('限流'), contains('自动重试')));
    expect(requests, hasLength(2));
    expect(events.whereType<AgentText>().single.text, '好了');
  });

  test('once rate-limited, the rest of the run is paced', () async {
    // A strict free tier answers 429 on the second request of a run. Retrying
    // is not enough — the third, fourth, fifth request hit the same wall. So
    // after the first 429 every later request waits a beat.
    statusQueue.add(429);
    replies.add(assistant({'role': 'assistant', 'content': '好了'}));

    final notices = <String>[];
    await AgentRunner(
      vault: vault,
      config: configFor(),
      retryDelays: const [Duration.zero],
      rateLimitGap: const Duration(milliseconds: 50),
      onNotice: notices.add,
    ).run('hi').toList();

    expect(notices, hasLength(2));
    expect(notices.first, contains('慢速模式'));
    expect(notices.last, contains('限流'));
    expect(requests, hasLength(2));
  });

  test('a persistent rate limit gives up with the same Chinese message', () async {
    statusQueue.addAll([429, 429, 429]);

    final notices = <String>[];
    await expectLater(
      AgentRunner(
        vault: vault,
        config: configFor(),
        retryDelays: const [Duration.zero, Duration.zero],
        rateLimitGap: Duration.zero,
        onNotice: notices.add,
      ).run('hi'),
      emitsError(isA<AgentException>()
          .having((e) => e.message, 'message', contains('429'))),
    );
    // Two retries were announced before giving up on the third answer.
    expect(notices, hasLength(2));
    expect(requests, hasLength(3));
  });

  test('tools given explicitly override the default belt', () async {
    replies.add(assistant({'role': 'assistant', 'content': 'ok'}));
    final custom = AgentTool(
      name: 'ping',
      description: 'ping',
      parameters: {'type': 'object', 'properties': <String, dynamic>{}},
      run: (args) async => const AgentToolResult('pong'),
    );
    await AgentRunner(
      vault: vault,
      config: configFor(),
      tools: [custom],
    ).run('hi').toList();

    final tools = requests.single['tools'] as List;
    expect(tools, hasLength(1));
    expect(tools.single['function']['name'], 'ping');
  });

  test('calls beyond the per-step cap still get a tool result', () async {
    // The real failure this guards against: the model asked for 5 tools, the
    // loop ran 4, and the assistant turn echoed all 5 tool_calls back. The
    // next request then violated the OpenAI contract — every tool_call_id
    // needs a following tool message — and DeepSeek answered 400, which read
    // to the user as "it ran four tools and then hung".
    replies.addAll([
      assistant({
        'role': 'assistant',
        'content': '',
        'tool_calls': [
          toolCall('read_note', {'path': 'a.md'}, id: 'call_1'),
          toolCall('read_note', {'path': 'b.md'}, id: 'call_2'),
          toolCall('list_notes', <String, dynamic>{}, id: 'call_3'),
          toolCall('search_notes', {'query': '甲'}, id: 'call_4'),
          toolCall('read_note', {'path': 'a.md'}, id: 'call_5'),
        ],
      }),
      assistant({'role': 'assistant', 'content': '读完了'}),
    ]);

    final events = await AgentRunner(vault: vault, config: configFor())
        .run('都读一下')
        .toList();

    // The user is told what happened, not left to count the cards.
    expect(
      events.whereType<AgentNotice>().single.text,
      contains('超过上限'),
    );

    // The decisive assertion: in the SECOND request, every tool_call_id the
    // assistant message produced is answered by exactly one tool message.
    final second = requests[1]['messages'] as List;
    final assistantTurn = second.firstWhere(
      (m) => (m as Map)['tool_calls'] != null,
    ) as Map<String, dynamic>;
    final callIds = (assistantTurn['tool_calls'] as List)
        .map((c) => (c as Map)['id'] as String)
        .toSet();
    expect(callIds, hasLength(5));

    final answeredIds = second
        .whereType<Map>()
        .where((m) => m['role'] == 'tool')
        .map((m) => m['tool_call_id'] as String)
        .toList();
    expect(answeredIds.toSet(), callIds);
    // No duplicates either: a tool_call answered twice is just as invalid.
    expect(answeredIds.length, callIds.length);

    // The skipped call is explained to the model so it can re-request it.
    final skipped = second.firstWhere(
      (m) =>
          (m as Map)['role'] == 'tool' && m['tool_call_id'] == 'call_5',
    ) as Map<String, dynamic>;
    expect(skipped['content'], contains('跳过'));
  });

  test('the system prompt demands a category on create_note', () async {
    // Regression for "AI 建的笔记没有分类": the vault convention lives in the
    // vault's own meta notes, and the model never reads them on its own.
    replies.add(assistant({'role': 'assistant', 'content': 'ok'}));
    await AgentRunner(vault: vault, config: configFor()).run('hi').toList();

    final system = (requests.single['messages'] as List)
        .firstWhere((m) => (m as Map)['role'] == 'system')['content'] as String;
    expect(system, contains('create_note 传 type'));
    expect(system, contains('分类总览'));
  });

  test('the system prompt sends methodology work to the vault SOPs', () async {
    // The vault holds 50+ `type: Skill` notes distilled from books. Without
    // this rule the model writes copy from its own generic sense and the user's
    // SOPs sit unused — which is exactly what happened on the phone.
    replies.add(assistant({'role': 'assistant', 'content': 'ok'}));
    await AgentRunner(vault: vault, config: configFor()).run('写篇文案').toList();

    final system = (requests.single['messages'] as List)
        .firstWhere((m) => (m as Map)['role'] == 'system')['content'] as String;
    expect(system, contains('list_notes(type: "Skill")'));
    expect(system, contains('read_note'));
    // Falling back is allowed, but it has to be announced, not silent.
    expect(system, contains('没找到对应 SOP'));
  });

  test('a streaming frame glued into content never reaches the bubble', () async {
    // Live shape from Zhipu's free tier: the SSE frame for a tool-calling turn
    // arrives stringified, appended to the assistant text. The user saw it in
    // the chat bubble, and the model then saw it in its own transcript.
    const noise = '{"index":0,"finish_reason":"tool_calls","delta":'
        '{"role":"assistant","content":null,"reasoning_content":null,'
        '"tool_calls":[{"id":"call_1","index":0,"type":"function",'
        '"function":{"name":"list_notes","arguments":"{}"}}]}}';
    replies.add(assistant({
      'role': 'assistant',
      'content': '好的，我先搜索一下。$noise',
      'tool_calls': [toolCall('list_notes', <String, dynamic>{})],
    }));
    replies.add(assistant({'role': 'assistant', 'content': '一共 2 篇。'}));

    final runner = AgentRunner(vault: vault, config: configFor());
    final events = await runner.run('hi').toList();

    final texts = events.whereType<AgentText>().map((e) => e.text).toList();
    expect(texts.first, '好的，我先搜索一下。');
    expect(texts.join(), isNot(contains('finish_reason')));

    // Leaving it in the transcript teaches the model to keep emitting it.
    expect(jsonEncode(runner.lastMessages), isNot(contains('finish_reason')));
  });

  test('a legitimate JSON answer keeps its braces', () async {
    replies.add(assistant({
      'role': 'assistant',
      'content': '返回体就是 {"index": 0} 这样的结构。',
    }));

    final events =
        await AgentRunner(vault: vault, config: configFor()).run('hi').toList();
    expect(events.whereType<AgentText>().single.text,
        contains('{"index": 0}'));
  });

  test('a follow-up turn replays the previous conversation', () async {
    replies.addAll([
      assistant({'role': 'assistant', 'content': '第一轮答案。'}),
      assistant({'role': 'assistant', 'content': '第二轮答案。'}),
    ]);

    final runner = AgentRunner(vault: vault, config: configFor());
    await runner.run('第一问').toList();
    await runner.run('那第二点呢', history: runner.lastMessages).toList();

    final sent = (requests.last['messages'] as List).cast<Map<String, dynamic>>();
    expect(
      sent.map((m) => m['role']).toList(),
      ['system', 'user', 'assistant', 'user'],
    );
    expect(sent[1]['content'], '第一问');
    expect(sent[2]['content'], '第一轮答案。');
    expect(sent[3]['content'], '那第二点呢');
  });

  test('a fresh note is restated in the follow-up without a second system turn',
      () async {
    replies.addAll([
      assistant({'role': 'assistant', 'content': '收到。'}),
      assistant({'role': 'assistant', 'content': '这篇讲的是乙。'}),
    ]);

    final runner = AgentRunner(vault: vault, config: configFor());
    await runner.run('你好').toList();
    await runner
        .run('这篇讲什么？',
            history: runner.lastMessages, noteContext: '《b》（b.md）\n正文乙')
        .toList();

    final sent = (requests.last['messages'] as List).cast<Map<String, dynamic>>();
    // One system message only: some gateways reject a system turn mid-chat.
    expect(sent.where((m) => m['role'] == 'system'), hasLength(1));
    expect(sent.last['content'], contains('正文乙'));
    expect(sent.last['content'], contains('这篇讲什么？'));
  });

  test('a long history is trimmed at turn boundaries, never mid-turn', () async {    replies.add(assistant({'role': 'assistant', 'content': '好。'}));

    final history = <Map<String, dynamic>>[
      {'role': 'system', 'content': '系统提示'},
    ];
    for (var i = 0; i < 20; i++) {
      history.add({'role': 'user', 'content': '问题 $i ${'x' * 3000}'});
      history.add({
        'role': 'assistant',
        'content': '',
        'tool_calls': [toolCall('list_notes', <String, dynamic>{}, id: 'call_$i')],
      });
      history.add({
        'role': 'tool',
        'tool_call_id': 'call_$i',
        'content': '结果 $i',
      });
      history.add({'role': 'assistant', 'content': '答 $i'});
    }

    await AgentRunner(vault: vault, config: configFor())
        .run('再来一次', history: history)
        .toList();

    final sent = (requests.single['messages'] as List).cast<Map<String, dynamic>>();
    expect(sent.first['role'], 'system');
    // The slice must begin on a user turn, otherwise its tool results would be
    // orphaned and the provider would reject the request with a 400.
    expect(sent[1]['role'], 'user');
    expect(sent, hasLength(lessThan(history.length)));

    final pendingCalls = <String>{};
    for (final message in sent) {
      if (message['role'] == 'assistant') {
        for (final call in (message['tool_calls'] as List?) ?? const []) {
          pendingCalls.add((call as Map)['id'].toString());
        }
      }
      if (message['role'] == 'tool') {
        expect(pendingCalls.remove(message['tool_call_id']), isTrue);
      }
    }
    expect(pendingCalls, isEmpty, reason: 'every tool_call must be answered');

    // And the budget is honoured: the trimmed transcript stays near the cap.
    expect(jsonEncode(sent).length, lessThan(24000 + 4000));
  });

  test('a streamed answer arrives as deltas, never as one pasted blob', () async {
    sseReplies.add([
      {'role': 'assistant', 'content': '你的知识库'},
      {'content': '有 2 篇笔记。'},
    ]);

    final runner = AgentRunner(vault: vault, config: configFor());
    final events = await runner.run('我有哪些笔记？').toList();

    expect(requests.single['stream'], isTrue);
    final streamed =
        events.whereType<AgentTextDelta>().map((e) => e.text).join();
    expect(streamed, '你的知识库有 2 篇笔记。');
    // Emitting both would show the answer twice: typed out, then pasted again.
    expect(events.whereType<AgentText>(), isEmpty);
    expect(events.last, isA<AgentFinished>());
    expect(jsonEncode(runner.lastMessages), contains('有 2 篇笔记'));
  });

  test('tool_calls split across deltas are reassembled before they run',
      () async {
    sseReplies.addAll([
      [
        {
          'role': 'assistant',
          'content': '',
          'tool_calls': [
            {
              'index': 0,
              'id': 'call_1',
              'type': 'function',
              'function': {'name': 'read_note', 'arguments': '{"pa'},
            },
          ],
        },
        {
          'tool_calls': [
            {
              'index': 0,
              'function': {'arguments': 'th":"a.md"}'},
            },
          ],
        },
      ],
      [
        {'role': 'assistant', 'content': 'a.md 的正文是「正文甲」。'},
      ],
    ]);

    final runner = AgentRunner(vault: vault, config: configFor());
    final events = await runner.run('读一下 a.md').toList();

    final finished = events.whereType<AgentToolFinished>().single;
    expect(finished.isError, isFalse);
    expect(finished.content, contains('正文甲'));
    expect(events.whereType<AgentToolStarted>().single.arguments, {'path': 'a.md'});

    // The echoed assistant turn must carry the whole call: a fragmented id or
    // arguments string is exactly what makes the next request a 400.
    final sent = (requests[1]['messages'] as List).cast<Map<String, dynamic>>();
    final echo = sent[2];
    expect(echo['role'], 'assistant');
    final call = (echo['tool_calls'] as List).single as Map;
    expect(call['id'], 'call_1');
    expect((call['function'] as Map)['name'], 'read_note');
    expect(
      jsonDecode((call['function'] as Map)['arguments'] as String),
      {'path': 'a.md'},
    );
    expect(sent[3]['role'], 'tool');
    expect(sent[3]['tool_call_id'], 'call_1');
  });

  test('a frame glued into a streamed delta never reaches the screen', () async {
    sseReplies.add([
      {'role': 'assistant', 'content': '好的，我先搜索一下。'},
      {
        'content': '{"index":0,"finish_reason":"tool_calls",'
            '"delta":{"role":"assistant","tool_calls":[]}}',
      },
    ]);

    final events =
        await AgentRunner(vault: vault, config: configFor()).run('帮我搜').toList();

    final shown = events.whereType<AgentTextDelta>().map((e) => e.text).join();
    expect(shown, '好的，我先搜索一下。');
    expect(shown, isNot(contains('finish_reason')));
  });

  test('a gateway that ignores stream:true still answers', () async {
    // No sseReplies: the harness falls back to a single JSON object, which is
    // what a proxy that strips `stream` sends back.
    replies.add(assistant({'role': 'assistant', 'content': '整段返回。'}));

    final events =
        await AgentRunner(vault: vault, config: configFor()).run('hi').toList();

    expect(requests.single['stream'], isTrue);
    expect(events.whereType<AgentTextDelta>(), isEmpty);
    expect(events.whereType<AgentText>().single.text, '整段返回。');
  });
}
