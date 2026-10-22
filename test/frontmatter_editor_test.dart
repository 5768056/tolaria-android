import 'package:flutter_test/flutter_test.dart';
import 'package:tolaria_android/services/frontmatter_editor.dart';

/// The archive / category edits must not rewrite the rest of a note: a type
/// definition carries a `template: |` block scalar whose formatting matters,
/// and a hand-optimised note should not be reformatted just because its
/// archived flag flipped.
void main() {
  const archived = ['archived', 'Archived'];

  group('FrontmatterEditor.upsert', () {
    test('inserts a new key and keeps every other byte intact', () {
      const raw = '---\ntitle: 测试\ntype: 自媒体\n---\n\n# 测试\n\n正文\n';
      final out = FrontmatterEditor.upsert(
        raw,
        key: '_archived',
        aliases: archived,
        value: true,
      );
      expect(
        out,
        '---\ntitle: 测试\ntype: 自媒体\n_archived: true\n---\n\n# 测试\n\n正文\n',
      );
    });

    test('rewrites an existing alias in place, keeping its spelling', () {
      const raw = '---\ntitle: a\narchived: false\n---\nbody';
      final out = FrontmatterEditor.upsert(
        raw,
        key: '_archived',
        aliases: archived,
        value: true,
      );
      // Not `_archived:` — a vault that already uses the legacy key keeps it.
      expect(out, '---\ntitle: a\narchived: true\n---\nbody');
    });

    test('removing a key also drops its indented children', () {
      const raw = '---\ntitle: a\ntype:\n  - x\n  - y\ntags: [q]\n---\nb';
      final out = FrontmatterEditor.upsert(
        raw,
        key: 'type',
        aliases: const ['is_a'],
        value: null,
      );
      expect(out, '---\ntitle: a\ntags: [q]\n---\nb');
    });

    test('removing an absent key leaves the file untouched', () {
      const raw = '---\ntitle: a\n---\nb';
      final out = FrontmatterEditor.upsert(
        raw,
        key: '_archived',
        aliases: archived,
        value: null,
      );
      expect(identical(out, raw), isTrue);
    });

    test('creates a frontmatter block when the note has none', () {
      const raw = '# 标题\n\n正文\n';
      final out = FrontmatterEditor.upsert(
        raw,
        key: 'type',
        aliases: const ['is_a', 'Is A'],
        value: '自媒体',
      );
      expect(out, '---\ntype: 自媒体\n---\n# 标题\n\n正文\n');
    });

    test('does nothing when removing from a note without frontmatter', () {
      const raw = '# 标题\n';
      expect(
        FrontmatterEditor.upsert(raw, key: 'type', value: null),
        raw,
      );
    });

    test('keeps CRLF line endings', () {
      const raw = '---\r\ntitle: a\r\n---\r\nbody\r\n';
      final out = FrontmatterEditor.upsert(
        raw,
        key: '_archived',
        aliases: archived,
        value: true,
      );
      expect(out, '---\r\ntitle: a\r\n_archived: true\r\n---\r\nbody\r\n');
    });

    test('keeps a leading BOM', () {
      const raw = '\uFEFF---\ntitle: a\n---\nb';
      final out = FrontmatterEditor.upsert(
        raw,
        key: '_archived',
        aliases: archived,
        value: true,
      );
      expect(out, '\uFEFF---\ntitle: a\n_archived: true\n---\nb');
    });

    test('leaves a block scalar alone when appending a key', () {
      const raw = '---\n'
          'type: Type\n'
          'template: |\n'
          '  # {{title}}\n'
          '\n'
          '  正文\n'
          '---\n'
          'body\n';
      final out = FrontmatterEditor.upsert(
        raw,
        key: 'title',
        value: '笔记',
      );
      expect(out, contains('template: |\n  # {{title}}\n\n  正文\n'));
      expect(out, contains('title: 笔记\n---\n'));
    });

    test('ignores a same-named key nested under another field', () {
      const raw = '---\nmeta:\n  type: inner\ntitle: a\n---\nb';
      final out = FrontmatterEditor.upsert(
        raw,
        key: 'type',
        aliases: const ['is_a'],
        value: '自媒体',
      );
      expect(out, contains('  type: inner\n'));
      expect(out, contains('\ntype: 自媒体\n---'));
    });

    test('quotes only scalars that need it', () {
      String set(Object value) => FrontmatterEditor.upsert(
            '---\ntitle: a\n---\nb',
            key: 'type',
            value: value,
          );
      expect(set('自媒体'), contains('type: 自媒体\n'));
      expect(set('a: b'), contains('type: "a: b"\n'));
      expect(set('true'), contains('type: "true"\n'));
      expect(set('- 开头'), contains('type: "- 开头"\n'));
    });

    test('matches `Is A` against `is_a` when comparing spellings', () {
      const raw = '---\ntitle: a\nIs A: 旧\n---\nb';
      final out = FrontmatterEditor.upsert(
        raw,
        key: 'type',
        aliases: const ['is_a', 'Is A'],
        value: '个人成长',
      );
      expect(out, '---\ntitle: a\nIs A: 个人成长\n---\nb');
    });
  });
}
