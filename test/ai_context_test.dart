import 'package:flutter_test/flutter_test.dart';
import 'package:tolaria_android/models/ai_config.dart';
import 'package:tolaria_android/models/note.dart';
import 'package:tolaria_android/services/ai_context.dart';

void main() {
  Note note({
    String path = 'notes/a.md',
    String title = '测试笔记',
    String body = '正文内容',
    Map<String, dynamic> frontmatter = const {'type': '自媒体'},
  }) {
    return Note(
      relativePath: path,
      title: title,
      frontmatter: frontmatter,
      body: body,
    );
  }

  const config = AiConfig(
    presetId: 'deepseek',
    baseUrl: 'https://api.deepseek.com/v1',
    model: 'deepseek-chat',
    apiKey: 'sk-x',
  );

  group('AiContext.build', () {
    test('attaches the active note title, path, type and body', () {
      final messages = AiContext.build(
        config: config,
        history: const [],
        question: '总结一下',
        activeNote: note(),
      );

      expect(messages.first.role, 'system');
      final system = messages.first.content;
      expect(system, contains('测试笔记'));
      expect(system, contains('notes/a.md'));
      expect(system, contains('自媒体'));
      expect(system, contains('正文内容'));

      expect(messages.last.role, 'user');
      expect(messages.last.content, '总结一下');
    });

    test('lists the vault outline so the model knows what exists', () {
      final messages = AiContext.build(
        config: config,
        history: const [],
        question: '我有哪些笔记？',
        vaultNotes: [
          note(path: 'a.md', title: '甲'),
          note(path: 'b.md', title: '乙', frontmatter: const {'type': '教程'}),
        ],
      );

      final system = messages.first.content;
      expect(system, contains('知识库目录'));
      expect(system, contains('a.md — 甲'));
      expect(system, contains('b.md — 乙 · 教程'));
    });

    test('truncates long bodies in the middle, keeping the tail', () {
      final longBody = '${'开' * 20000}结尾重点${'尾' * 300}';
      final messages = AiContext.build(
        config: config,
        history: const [],
        question: 'q',
        activeNote: note(body: longBody),
      );

      final system = messages.first.content;
      expect(system.length, lessThan(longBody.length));
      expect(system, contains('中间省略'));
      // The conclusion survives; cutting only the tail would lose it.
      expect(system, contains('结尾重点'));
      expect(system, contains('开'));
    });

    test('includeNoteContext=false sends no note and no outline', () {
      final messages = AiContext.build(
        config: config.copyWith(includeNoteContext: false),
        history: const [],
        question: '你好',
        activeNote: note(),
        vaultNotes: [note(path: 'z.md', title: '不该出现')],
      );

      final system = messages.first.content;
      expect(system, isNot(contains('正文内容')));
      expect(system, isNot(contains('不该出现')));
      expect(system, contains('没有附带'));
    });

    test('replays history but drops error bubbles', () {
      final messages = AiContext.build(
        config: config,
        history: const [
          AiMessage(role: 'user', content: '第一个问题'),
          AiMessage(role: 'assistant', content: '第一个回答'),
          AiMessage(role: 'assistant', content: 'API Key 无效', error: true),
        ],
        question: '第二个问题',
      );

      final contents = messages.map((m) => m.content).toList();
      expect(contents, contains('第一个问题'));
      expect(contents, contains('第一个回答'));
      expect(contents, isNot(contains('API Key 无效')));
      expect(messages.last.content, '第二个问题');
    });

    test('caps history so a long chat cannot blow the context window', () {
      final history = [
        for (var i = 0; i < 40; i++)
          AiMessage(role: i.isEven ? 'user' : 'assistant', content: 'm$i'),
      ];
      final messages = AiContext.build(
        config: config,
        history: history,
        question: 'q',
      );

      // system + 20 replayed + the new question
      expect(messages.length, 22);
      expect(messages[1].content, 'm20');
    });

    test('caps the outline at maxOutlineEntries', () {
      final notes = [
        for (var i = 0; i < 300; i++) note(path: 'n$i.md', title: '笔记$i'),
      ];
      final messages = AiContext.build(
        config: config,
        history: const [],
        question: 'q',
        vaultNotes: notes,
      );

      final system = messages.first.content;
      expect(system, contains('只列出前 ${AiContext.maxOutlineEntries} 篇'));
      expect(system, contains('共 300 篇'));
    });
  });

  group('AiContext.scopeLabel', () {
    test('describes both parts when context is on', () {
      expect(
        AiContext.scopeLabel(
          config: config,
          activeNote: note(),
          vaultNotes: [note(path: 'b.md')],
        ),
        '已附带：当前笔记 + 知识库目录 1 篇',
      );
    });

    test('says so when the user turned context off', () {
      expect(
        AiContext.scopeLabel(
          config: config.copyWith(includeNoteContext: false),
          activeNote: note(),
        ),
        '仅当前对话（未附带笔记）',
      );
    });

    test('does not claim a note when opened from the list', () {
      expect(
        AiContext.scopeLabel(config: config),
        '仅当前对话（知识库为空）',
      );
    });
  });

  group('AiConfig', () {
    test('local endpoints do not require a key', () {
      const local = AiConfig(baseUrl: 'http://192.168.1.10:11434/v1', model: 'q');
      expect(local.isLocalEndpoint, isTrue);
      expect(local.needsKey, isFalse);

      const remote = AiConfig(baseUrl: 'https://api.deepseek.com/v1', model: 'q');
      expect(remote.needsKey, isTrue);
    });

    test('survives a map round-trip', () {
      const original = AiConfig(
        presetId: 'moonshot',
        protocol: AiProtocol.anthropic,
        baseUrl: 'https://api.example.com',
        model: 'claude-x',
        apiKey: 'sk-1',
        includeNoteContext: false,
      );
      final restored = AiConfig.fromMap(original.toMap());

      expect(restored.presetId, 'moonshot');
      expect(restored.protocol, AiProtocol.anthropic);
      expect(restored.apiKey, 'sk-1');
      expect(restored.includeNoteContext, isFalse);
    });
  });
}
