import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:tolaria_android/models/ai_config.dart';
import 'package:tolaria_android/models/note.dart';
import 'package:tolaria_android/providers/agent_provider.dart';

/// The notifier is what the screen actually talks to: it decides when a run
/// starts, what the timeline looks like while it runs, and whether the note
/// list gets refreshed afterwards. These tests drive it against a scripted
/// endpoint so that contract is pinned down without a device.
void main() {
  late Directory root;
  late HttpServer server;
  late List<Map<String, dynamic>> requests;
  late List<Map<String, dynamic>> replies;
  /// One entry per streaming request: the `delta` objects to send. Empty means
  /// "answer with a single JSON object", the older behaviour.
  late List<List<Map<String, dynamic>>> sseReplies;

  setUp(() async {
    root = Directory.systemTemp.createTempSync('agent_state_');
    File(p.join(root.path, 'a.md')).writeAsStringSync('# a\n\n正文甲\n');
    requests = [];
    replies = [];
    sseReplies = [];
    server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    server.listen((request) async {
      final body = await utf8.decoder.bind(request).join();
      requests.add(jsonDecode(body) as Map<String, dynamic>);
      if (sseReplies.isNotEmpty) {
        final frames = sseReplies.removeAt(0);
        request.response.headers.contentType =
            ContentType('text', 'event-stream', charset: 'utf-8');
        for (final frame in frames) {
          request.response.write(
            'data: ${jsonEncode({'choices': [{'delta': frame}]})}\n\n',
          );
        }
        request.response.write('data: [DONE]\n\n');
        await request.response.close();
        return;
      }
      final reply = replies.isEmpty
          ? {'choices': [{'message': {'role': 'assistant', 'content': '（脚本用完了）'}}]}
          : replies.removeAt(0);
      request.response.headers.contentType =
          ContentType('application', 'json', charset: 'utf-8');
      request.response.add(utf8.encode(jsonEncode(reply)));
      await request.response.close();
    });
  });

  tearDown(() async {
    await server.close(force: true);
    if (root.existsSync()) root.deleteSync(recursive: true);
  });

  AiConfig config() => AiConfig(
        baseUrl: 'http://127.0.0.1:${server.port}/v1',
        model: 'test-model',
        apiKey: 'test-key',
      );

  Map<String, dynamic> assistant(Map<String, dynamic> message) =>
      {'choices': [{'message': message}]};

  Map<String, dynamic> call(String name, Object? args, {String id = 'c1'}) => {
        'id': id,
        'type': 'function',
        'function': {
          'name': name,
          'arguments': args is String ? args : jsonEncode(args),
        },
      };

  AgentChatNotifier build({int Function()? onRefresh}) {
    final counter = onRefresh ?? () => 0;
    return AgentChatNotifier(
      readConfig: config,
      readVaultPath: () => root.path,
      onVaultChanged: () async => counter(),
    );
  }

  test('a plain answer becomes one answer item', () async {
    replies.add(assistant({'role': 'assistant', 'content': '两篇笔记。'}));
    final notifier = build();

    await notifier.send('我有几篇笔记？');

    expect(notifier.state.items, hasLength(2));
    expect(notifier.state.items.first, isA<AgentUserItem>());
    final answer = notifier.state.items.last;
    expect(answer, isA<AgentAnswerItem>());
    expect((answer as AgentAnswerItem).text, '两篇笔记。');
    expect(notifier.state.running, isFalse);
    expect(notifier.state.error, isNull);
  });

  test('a tool call is visible while running, then carries its result', () async {
    replies.addAll([
      assistant({
        'role': 'assistant',
        'content': '',
        'tool_calls': [call('list_notes', <String, dynamic>{})],
      }),
      assistant({'role': 'assistant', 'content': '两篇。'}),
    ]);
    final notifier = build();

    final seen = <AgentToolItem>[];
    notifier.addListener((state) {
      for (final item in state.items) {
        if (item is AgentToolItem) seen.add(item);
      }
    });

    await notifier.send('列一下');

    // A spinner with no result was rendered at least once: the UI shows work
    // in progress instead of freezing on a blank screen.
    expect(seen.any((item) => item.running), isTrue);
    final card = notifier.state.items.whereType<AgentToolItem>().single;
    expect(card.running, isFalse);
    expect(card.isError, isFalse);
    expect(card.result, contains('a.md'));
    expect(card.subject, isEmpty); // list_notes has no path argument
  });

  test('a declined write leaves the file alone and refreshes nothing', () async {
    replies.addAll([
      assistant({
        'role': 'assistant',
        'content': '',
        'tool_calls': [
          call('edit_note', {
            'path': 'a.md',
            'old_string': '正文甲',
            'new_string': '正文丙',
          }),
        ],
      }),
      assistant({'role': 'assistant', 'content': '好，不改了。'}),
    ]);

    var approvals = 0;
    var refreshes = 0;
    final notifier = build(onRefresh: () => refreshes++);

    await notifier.send('改一下', approve: (tool, args) async {
      approvals++;
      return false;
    });

    expect(approvals, 1);
    expect(File(p.join(root.path, 'a.md')).readAsStringSync(), contains('正文甲'));
    final card = notifier.state.items.whereType<AgentToolItem>().single;
    expect(card.isError, isTrue);
    expect(card.result, contains('拒绝'));
    expect(refreshes, 0);
  });

  test('an approved write refreshes the vault so the list is not stale',
      () async {
    replies.addAll([
      assistant({
        'role': 'assistant',
        'content': '',
        'tool_calls': [
          call('create_note', {'title': '新想法', 'body': '记一句'}),
        ],
      }),
      assistant({'role': 'assistant', 'content': '建好了。'}),
    ]);

    var refreshes = 0;
    final notifier = build(onRefresh: () => refreshes++);

    await notifier.send('写一篇', approve: (tool, args) async => true);

    expect(File(p.join(root.path, '新想法.md')).existsSync(), isTrue);
    expect(refreshes, 1);
  });

  test('with no approver, writes are refused rather than silently applied',
      () async {
    replies.addAll([
      assistant({
        'role': 'assistant',
        'content': '',
        'tool_calls': [
          call('create_note', {'title': '偷偷写', 'body': 'x'}),
        ],
      }),
      assistant({'role': 'assistant', 'content': '好的。'}),
    ]);

    final notifier = build();
    await notifier.send('写一篇');

    expect(File(p.join(root.path, '偷偷写.md')).existsSync(), isFalse);
  });

  test('an unusable endpoint fails before any request is sent', () async {
    final notifier = AgentChatNotifier(
      readConfig: () => const AiConfig(baseUrl: '', model: ''),
      readVaultPath: () => root.path,
      onVaultChanged: () async {},
    );

    await notifier.send('你好');

    expect(requests, isEmpty);
    expect(notifier.state.error, contains('还没配置'));
    expect(notifier.state.items, isEmpty);
  });

  test('an Anthropic endpoint is pointed back at chat mode', () async {
    final notifier = AgentChatNotifier(
      readConfig: () => const AiConfig(
        baseUrl: 'https://api.anthropic.com',
        model: 'claude',
        apiKey: 'k',
        protocol: AiProtocol.anthropic,
      ),
      readVaultPath: () => root.path,
      onVaultChanged: () async {},
    );

    await notifier.send('你好');

    expect(requests, isEmpty);
    expect(notifier.state.error, contains('切回问答模式'));
  });

  test('stop() closes the timeline and marks nothing as running', () async {
    // A tool round that never finishes on its own: the server answers only
    // once, so after the first response the loop asks again and hangs on the
    // empty script — long enough for stop() to land.
    replies.addAll([
      assistant({
        'role': 'assistant',
        'content': '',
        'tool_calls': [call('list_notes', <String, dynamic>{})],
      }),
      assistant({
        'role': 'assistant',
        'content': '',
        'tool_calls': [call('list_notes', <String, dynamic>{})],
      }),
    ]);

    final notifier = build();
    final run = notifier.send('一直列');
    notifier.stop();
    await run;

    expect(notifier.state.running, isFalse);
    expect(notifier.state.items.whereType<AgentNoticeItem>().last.text,
        contains('已停止'));
    expect(
      notifier.state.items.whereType<AgentToolItem>().any((i) => i.running),
      isFalse,
    );
  });

  test('a second question carries the first exchange', () async {
    replies.addAll([
      assistant({'role': 'assistant', 'content': '两篇笔记。'}),
      assistant({'role': 'assistant', 'content': '第二篇叫 b.md。'}),
    ]);

    final notifier = build();
    await notifier.send('我有几篇笔记？');
    await notifier.send('第二篇叫什么？');

    final sent = (requests.last['messages'] as List).cast<Map<String, dynamic>>();
    expect(
      sent.map((m) => m['role']).toList(),
      ['system', 'user', 'assistant', 'user'],
    );
    expect(sent[1]['content'], '我有几篇笔记？');
    expect(sent[2]['content'], '两篇笔记。');
    expect(sent[3]['content'], '第二篇叫什么？');
  });

  test('a streamed answer grows one bubble, not one bubble per token',
      () async {
    sseReplies.add([
      {'role': 'assistant', 'content': '两篇'},
      {'content': '笔记。'},
      {'content': '分别是 a.md 和 b.md。'},
    ]);

    final notifier = build();
    await notifier.send('我有几篇？');

    final answers = notifier.state.items.whereType<AgentAnswerItem>().toList();
    expect(answers, hasLength(1), reason: 'deltas must extend, not stack');
    expect(answers.single.text, '两篇笔记。分别是 a.md 和 b.md。');
    expect(notifier.state.items.whereType<AgentToolItem>(), isEmpty);
    expect(notifier.state.running, isFalse);
  });

  test('an unchanged note is not resent; an edited one is', () async {
    replies.addAll([
      assistant({'role': 'assistant', 'content': '一。'}),
      assistant({'role': 'assistant', 'content': '二。'}),
      assistant({'role': 'assistant', 'content': '三。'}),
    ]);

    final notifier = build()..attachActiveNote(_note(body: '# a\n\n正文甲\n'));
    await notifier.send('第一问');
    await notifier.send('第二问');
    // Same path, longer body: the user edited it between questions.
    notifier.attachActiveNote(_note(body: '# a\n\n正文甲\n新增一段\n'));
    await notifier.send('第三问');

    List<Map<String, dynamic>> messagesOf(Map<String, dynamic> request) =>
        (request['messages'] as List).cast<Map<String, dynamic>>();

    // Turn 1 puts the note in the system prompt; turn 2 must not re-upload it.
    expect(messagesOf(requests[0])[0]['content'], contains('正文甲'));
    expect(messagesOf(requests[1]).last['content'], '第二问');
    // Turn 3 sees the edit, and it arrives in the user turn, not a new system.
    expect(messagesOf(requests[2]).last['content'], contains('新增一段'));
    expect(
      messagesOf(requests[2]).where((m) => m['role'] == 'system'),
      hasLength(1),
    );
  });

  test('clear() starts a cold conversation', () async {    replies.addAll([
      assistant({'role': 'assistant', 'content': '一。'}),
      assistant({'role': 'assistant', 'content': '二。'}),
    ]);

    final notifier = build();
    await notifier.send('第一问');
    notifier.clear();
    await notifier.send('新的问题');

    final sent = (requests.last['messages'] as List).cast<Map<String, dynamic>>();
    expect(sent.map((m) => m['role']).toList(), ['system', 'user']);
    expect(sent.last['content'], '新的问题');
  });

  test('a failed turn is not remembered as an unanswered question', () async {
    var baseUrlOverride = '';
    final notifier = AgentChatNotifier(
      readConfig: () => baseUrlOverride.isEmpty
          ? config()
          : AiConfig(baseUrl: baseUrlOverride, model: 'test-model', apiKey: 'k'),
      readVaultPath: () => root.path,
      onVaultChanged: () async {},
    );

    replies.add(assistant({'role': 'assistant', 'content': '一。'}));
    await notifier.send('第一问');

    // A port nothing listens on: the request never reaches a model.
    baseUrlOverride = 'http://127.0.0.1:${await _freePort()}/v1';
    await notifier.send('注定失败的一问');
    expect(notifier.state.error, contains('连不上'));

    baseUrlOverride = '';
    replies.add(assistant({'role': 'assistant', 'content': '二。'}));
    await notifier.send('再来');

    final sent = (requests.last['messages'] as List).cast<Map<String, dynamic>>();
    // The failed question was never answered, so replaying it would hand the
    // model a dangling user turn; the good turn before it must survive.
    expect(jsonEncode(sent), isNot(contains('注定失败的一问')));
    expect(jsonEncode(sent), contains('第一问'));
    expect(sent.last['content'], '再来');
  });
}

Note _note({required String body}) => Note(
      relativePath: 'a.md',
      title: 'a',
      frontmatter: const {},
      body: body,
    );

/// A port that was just free, so a connection is refused rather than routed.
Future<int> _freePort() async {
  final socket = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
  final port = socket.port;
  await socket.close();
  return port;
}
