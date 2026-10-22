import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:tolaria_android/services/agent/agent_tool.dart';
import 'package:tolaria_android/services/agent/vault_tools.dart';
import 'package:tolaria_android/services/vault_service.dart';

/// The tool belt is what the model is allowed to touch. These tests pin the
/// safety rails (no escaping the vault, no ambiguous edits, no silent
/// overwrites) as much as the happy paths.
void main() {
  late Directory root;
  late VaultService vault;
  late Map<String, AgentTool> tools;

  setUp(() {
    root = Directory.systemTemp.createTempSync('agent_tools_');
    vault = VaultService(root.path);
    tools = {for (final t in buildVaultTools(vault)) t.name: t};
  });

  tearDown(() {
    if (root.existsSync()) root.deleteSync(recursive: true);
  });

  void write(String rel, String content) {
    final file = File(p.join(root.path, rel));
    file.parent.createSync(recursive: true);
    file.writeAsStringSync(content);
  }

  Future<String> call(String name, Map<String, dynamic> args) async {
    final result = await guardToolCall(tools[name]!, args);
    return result.content;
  }

  group('list_notes', () {
    test('lists paths with titles, newest first', () async {
      write('alpha.md', '# Alpha\n\nbody\n');
      write('自媒体/beta.md', '---\ntitle: Beta 笔记\n---\n\n正文\n');

      final out = await call('list_notes', {});
      expect(out, contains('alpha.md'));
      expect(out, contains('自媒体/beta.md'));
      expect(out, contains('Beta 笔记'));
    });

    test('filters with a glob and honours the limit', () async {
      write('a.md', '# a\n');
      write('b.md', '# b\n');
      write('自媒体/c.md', '# c\n');

      expect(await call('list_notes', {'pattern': '*.md'}),
          allOf(contains('a.md'), isNot(contains('自媒体/c.md'))));
      expect(await call('list_notes', {'pattern': '自媒体/**'}),
          contains('自媒体/c.md'));

      final limited = await call('list_notes', {'limit': 1});
      expect(limited.split('\n').where((l) => l.contains('.md')).length, 1);
    });

    test('says so when nothing matches', () async {
      write('a.md', '# a\n');
      expect(await call('list_notes', {'pattern': 'zzz*'}), contains('没有匹配'));
    });

    test('filters by type, case-insensitively', () async {
      // The SOP rule in the system prompt tells the model to call
      // list_notes(type: "Skill"). If that filter silently ignored the type,
      // the model would be reading random notes and thinking they were SOPs.
      write('a.md', '---\ntype: Skill\n---\n\n# 拆书 SOP\n');
      write('b.md', '---\ntype: 随笔\n---\n\n# 随手记\n');
      write('c.md', '# 没有分类\n');

      final out = await call('list_notes', {'type': 'Skill'});
      expect(out, contains('a.md'));
      expect(out, isNot(contains('b.md')));
      expect(out, isNot(contains('c.md')));

      // Frontmatter casing is not worth a round trip.
      expect(await call('list_notes', {'type': 'skill'}), contains('a.md'));

      // Combining with a glob still means "and".
      expect(
        await call('list_notes', {'type': 'Skill', 'pattern': 'b*'}),
        contains('没有匹配'),
      );
      expect(
        await call('list_notes', {'type': 'Nope'}),
        contains('没有匹配'),
      );
    });
  });

  group('read_note', () {
    test('returns the whole file with a line count', () async {
      write('a.md', '# a\nline2\nline3\n');
      final out = await call('read_note', {'path': 'a.md'});
      expect(out, contains('line2'));
      expect(out, contains('共 3 行'));
    });

    test('slices with offset and limit and says how much is left', () async {
      write('a.md', List.generate(20, (i) => 'line$i').join('\n'));
      final out = await call('read_note', {'path': 'a.md', 'offset': 5, 'limit': 3});
      expect(out, contains('line4'));
      expect(out, isNot(contains('line8')));
      expect(out, contains('offset=8'));
    });

    test('missing file is a model-visible error, not a crash', () async {
      final result = await guardToolCall(tools['read_note']!, {'path': 'nope.md'});
      expect(result.isError, isTrue);
      expect(result.content, contains('找不到'));
    });

    test('a wrong folder prefix gets the real path handed back', () async {
      // Live failure: the model asked for `Skill1/短视频带货脚本 SOP.md` in a flat
      // vault, got "not found", and asked again with the same wrong path. The
      // error now carries the actual paths so the next step can succeed.
      write('短视频带货脚本 SOP.md',
          '---\ntype: Skill\n---\n\n# 短视频带货脚本 SOP\n\n正文\n');

      final result = await guardToolCall(
        tools['read_note']!,
        {'path': 'Skill1/短视频带货脚本 SOP.md'},
      );
      expect(result.isError, isTrue);
      expect(result.content, contains('找不到'));
      expect(result.content, contains('可能你想读'));
      expect(result.content, contains('`短视频带货脚本 SOP.md`'));
    });

    test('an unrelated wrong path stays a plain not-found', () async {
      write('a.md', '# a\n');
      final result =
          await guardToolCall(tools['read_note']!, {'path': 'zzz/qqq.md'});
      expect(result.content, contains('找不到'));
      expect(result.content, isNot(contains('可能你想读')));
    });
  });

  group('search_notes', () {
    test('reports path and line number', () async {
      write('a.md', '# a\n\n关键词在这里\n');
      final out = await call('search_notes', {'query': '关键词'});
      expect(out, contains('a.md:3'));
    });

    test('regex mode works and bad regex is reported', () async {
      write('a.md', '# a\n\nfoo-123\n');
      expect(await call('search_notes', {'query': r'foo-\d+', 'regex': true}),
          contains('a.md:3'));

      final bad = await guardToolCall(
          tools['search_notes']!, {'query': '(', 'regex': true});
      expect(bad.isError, isTrue);
      expect(bad.content, contains('正则'));
    });

    test('no hit is a normal answer', () async {
      write('a.md', '# a\n');
      expect(await call('search_notes', {'query': '找不到的词'}), contains('没有找到'));
    });
  });

  group('note_meta', () {
    test('normalises type and archived', () async {
      write('a.md', '---\ntype: 自媒体\n_archived: true\n---\n\n正文\n');
      final out = await call('note_meta', {'path': 'a.md'});
      expect(out, contains('"type": "自媒体"'));
      expect(out, contains('"archived": true'));
    });
  });

  group('create_note', () {
    test('creates the file with body and type', () async {
      await call('create_note', {
        'title': 'weekly',
        'body': '本周总结',
        'type': '随笔',
      });
      final file = File(p.join(root.path, 'weekly.md'));
      expect(file.existsSync(), isTrue);
      final raw = file.readAsStringSync();
      expect(raw, contains('本周总结'));
      expect(raw, contains('type: 随笔'));
    });

    test('a second note with the same title does not overwrite the first',
        () async {
      write('weekly.md', '# keep me\n');
      await call('create_note', {'title': 'weekly'});
      expect(File(p.join(root.path, 'weekly.md')).readAsStringSync(),
          contains('keep me'));
      expect(File(p.join(root.path, 'weekly-2.md')).existsSync(), isTrue);
    });
  });

  group('edit_note', () {
    test('replaces the single match and leaves the rest byte-identical',
        () async {
      const original = '---\ntitle: t\ntype: 随笔\n---\n\n旧内容\n';
      write('a.md', original);

      final out = await call('edit_note',
          {'path': 'a.md', 'old_string': '旧内容', 'new_string': '新内容'});
      expect(out, contains('已修改'));
      expect(File(p.join(root.path, 'a.md')).readAsStringSync(),
          original.replaceFirst('旧内容', '新内容'));
    });

    test('refuses when the text is ambiguous', () async {
      write('a.md', '重复\n重复\n');
      final result = await guardToolCall(tools['edit_note']!, {
        'path': 'a.md',
        'old_string': '重复',
        'new_string': 'x',
      });
      expect(result.isError, isTrue);
      expect(result.content, contains('2 次'));
      expect(File(p.join(root.path, 'a.md')).readAsStringSync(), '重复\n重复\n');
    });

    test('refuses when the text is absent', () async {
      write('a.md', 'abc\n');
      final result = await guardToolCall(
          tools['edit_note']!, {'path': 'a.md', 'old_string': 'zzz', 'new_string': 'y'});
      expect(result.isError, isTrue);
      expect(result.content, contains('没找到'));
    });

    test('can delete a block by replacing it with an empty string', () async {
      write('a.md', 'a\nb\nc\n');
      await call('edit_note', {'path': 'a.md', 'old_string': 'b\n', 'new_string': ''});
      expect(File(p.join(root.path, 'a.md')).readAsStringSync(), 'a\nc\n');
    });
  });

  group('append_note', () {
    test('adds a newline only when the file needs one', () async {
      write('a.md', 'a');
      await call('append_note', {'path': 'a.md', 'text': 'b'});
      expect(File(p.join(root.path, 'a.md')).readAsStringSync(), 'a\nb');

      write('b.md', 'a\n');
      await call('append_note', {'path': 'b.md', 'text': 'b'});
      expect(File(p.join(root.path, 'b.md')).readAsStringSync(), 'a\nb');
    });
  });

  group('path guards', () {
    test('rejects traversal, absolute paths, .git and non-markdown', () async {
      for (final bad in ['../secret.md', '/etc/passwd.md', 'C:/x.md', '.git/config.md']) {
        final result = await guardToolCall(tools['read_note']!, {'path': bad});
        expect(result.isError, isTrue, reason: bad);
      }
      final notMd = await guardToolCall(tools['read_note']!, {'path': 'a.txt'});
      expect(notMd.isError, isTrue);
    });

    test('accepts a nested relative path', () async {
      write('自媒体/a.md', '# a\n正文\n');
      final out = await call('read_note', {'path': '自媒体/a.md'});
      expect(out, contains('正文'));
    });
  });

  group('schema', () {
    test('every advertised tool exists and carries a JSON schema', () {
      expect(tools.keys.toList()..sort(), agentToolNames);
      for (final tool in tools.values) {
        final schema = tool.toSchema();
        expect(schema['type'], 'function');
        expect(schema['function']['name'], tool.name);
        expect(schema['function']['parameters']['type'], 'object');
      }
    });

    test('only the writing tools are flagged as writes', () {
      final writes = tools.values.where((t) => t.writes).map((t) => t.name).toList()
        ..sort();
      expect(writes, ['append_note', 'create_note', 'edit_note']);
    });

    test('there is no shell tool', () {
      expect(tools.keys, isNot(contains('execute')));
      expect(tools.keys, isNot(contains('bash')));
    });
  });

  group('web_search', () {
    test('is advertised with a required query and is not a write', () {
      final tool = tools['web_search']!;
      expect(tool.writes, isFalse);
      expect(tool.parameters['required'], contains('query'));
    });
  });

  group('parseBocha', () {
    const bochaSample = '''
    {
      "code": 200,
      "data": {
        "webPages": {
          "value": [
            {
              "name": "Flutter 发布说明",
              "url": "https://docs.flutter.dev/release-notes",
              "snippet": "Flutter 3.47 带来了性能改进。",
              "siteName": "Flutter",
              "dateLastCrawled": "2026-10-01"
            },
            {
              "name": "Dart 语言概览",
              "url": "https://dart.dev/overview",
              "snippet": "Dart 是 Flutter 的语言。"
            }
          ]
        },
        "queryContext": { "originalQuery": "flutter" }
      }
    }''';

    test('extracts title/url/snippet into bullet lines', () {
      final result = parseBocha(bochaSample, 10);
      expect(result.isError, isFalse);
      expect(result.content, contains('Flutter 发布说明'));
      expect(result.content, contains('https://docs.flutter.dev/release-notes'));
      expect(result.content, contains('Flutter 3.47 带来了性能改进。'));
      expect(result.content, contains('Dart 语言概览'));
      expect(result.content, startsWith('2 条搜索结果'));
    });

    test('respects the max argument', () {
      final result = parseBocha(bochaSample, 1);
      expect(result.content, contains('1 条搜索结果'));
      expect(result.content, isNot(contains('Dart 语言概览')));
    });

    test('tolerates alternate field names (title/link/description)', () {
      const alt = '''
      {
        "data": {
          "webPages": {
            "value": [
              { "title": "备用字段", "link": "https://example.com", "description": "描述" }
            ]
          }
        }
      }''';
      final result = parseBocha(alt, 10);
      expect(result.isError, isFalse);
      expect(result.content, contains('备用字段'));
      expect(result.content, contains('https://example.com'));
      expect(result.content, contains('描述'));
    });

    test('reports when there are no results', () {
      const empty = '{"code":200,"data":{"webPages":{"value":[]}}}';
      final result = parseBocha(empty, 10);
      expect(result.isError, isFalse);
      expect(result.content, contains('没有找到'));
    });
  });

  group('fetch_url', () {
    test('tolerates non-UTF-8 (GBK) pages instead of crashing', () async {
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      addTearDown(() => server.close(force: true));
      server.listen((req) async {
        // <html>…<h1>中文</h1>…</html>，"中文" 的 GBK 编码是 D6D0 CEC4。
        // 用 UTF-8 解码这是非法序列——修复前这里直接抛 FormatException。
        final body = <int>[
          ...'<html><body><h1>'.codeUnits,
          0xD6, 0xD0, 0xCE, 0xC4,
          ...'</h1></body></html>'.codeUnits,
        ];
        req.response.headers.contentType =
            ContentType('text', 'html', charset: 'gbk');
        req.response.add(body);
        await req.response.close();
      });
      final result = await guardToolCall(
        tools['fetch_url']!,
        {'url': 'http://127.0.0.1:${server.port}/'},
      );
      // 修复前：isError 为 true，内容是 "FormatException: Missing extension byte"。
      expect(result.isError, isFalse);
    });

    test('rejects non-http schemes', () async {
      final result = await guardToolCall(
        tools['fetch_url']!,
        {'url': 'ftp://example.com/x'},
      );
      expect(result.isError, isTrue);
    });
  });

  group('describeVault', () {
    test('counts notes, archived and types', () {
      write('a.md', '---\ntype: 随笔\n---\n\nx\n');
      write('b.md', '---\ntype: 随笔\n_archived: true\n---\n\ny\n');
      write('c.md', '# c\n');
      final out = describeVault(vault);
      expect(out, contains('共 3 篇'));
      expect(out, contains('1 篇已归档'));
      expect(out, contains('随笔 2 篇'));
    });
  });
}
