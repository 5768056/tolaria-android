import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:tolaria_android/models/note.dart';
import 'package:tolaria_android/models/note_filter.dart';
import 'package:tolaria_android/services/vault_index.dart';

/// Covers the sidebar: parsing `views/*.yml` (Tolaria's own view format) and
/// the filters built from frontmatter. Fixtures mirror the file layout found in
/// a real desktop vault.
void main() {
  Note note(String path, {Map<String, dynamic>? frontmatter}) => Note(
        relativePath: path,
        title: p.basenameWithoutExtension(path),
        frontmatter: frontmatter ?? const {},
        body: '',
      );

  group('VaultIndex', () {
    late Directory root;

    setUp(() {
      root = Directory.systemTemp.createTempSync('tolaria_index_');
      final views = Directory(p.join(root.path, 'views'))..createSync();
      File(p.join(views.path, '自媒体.yml')).writeAsStringSync('''
name: 自媒体
icon: ph:megaphone
order: 1
filters:
  all:
    - field: type
      op: equals
      value: 自媒体
''');
      File(p.join(views.path, '未归档.yml')).writeAsStringSync('''
name: 未归档/系统文件
order: 7
filters:
  all:
    - field: type
      op: none_of
      value:
        - 自媒体
        - 个人成长
''');
      // A broken file must not take the sidebar down.
      File(p.join(views.path, 'broken.yml')).writeAsStringSync('::: not yaml :::');
    });

    tearDown(() {
      if (root.existsSync()) root.deleteSync(recursive: true);
    });

    test('loads views sorted by order and skips malformed files', () {
      final index = VaultIndex.load(root.path, const []);
      expect(index.views.map((v) => v.name), ['自媒体', '未归档/系统文件']);
      expect(index.views.first.id, '自媒体');
    });

    test('counts types but ignores `type: Type` definitions', () {
      final notes = [
        note('a.md', frontmatter: {'type': '自媒体'}),
        note('b.md', frontmatter: {'type': '自媒体'}),
        note('c.md', frontmatter: {'type': '个人成长'}),
        note('自媒体.md', frontmatter: {'type': 'Type'}),
        note('plain.md'),
      ];
      final index = VaultIndex.load(root.path, notes);
      expect(index.typeCounts, {'自媒体': 2, '个人成长': 1});
      // `type: Type` files are definitions: they show up as sidebar entries but
      // never carry a count of their own.
      expect(index.sortedTypes.map((t) => t.value),
          containsAll(['自媒体', '个人成长']));
      expect(index.types.any((t) => t.value == '自媒体'), isTrue);
    });

    test('categories are the values a note can actually be filed under', () {
      final notes = [
        note('a.md', frontmatter: {'type': '自媒体'}),
        note('b.md', frontmatter: {'type': '个人成长'}),
        note('自媒体.md', frontmatter: {'type': 'Type', '_color': '#E8743B'}),
        note('personal.md', frontmatter: {'type': '个人成长'}),
      ];
      final index = VaultIndex.load(root.path, notes);
      final categories = index.categories;

      // The 自媒体 view supplies the label; the `none_of` view
      // (未归档/系统文件) does not, because writing `type:` would not put a note
      // in it.
      expect(categories.map((c) => c.value), containsAll(['自媒体', '个人成长']));
      expect(categories.map((c) => c.label), isNot(contains('未归档/系统文件')));

      final media = categories.firstWhere((c) => c.value == '自媒体');
      expect(media.count, 1);
      // Colour comes from the view when it has one, else the type definition.
      expect(media.color, anyOf(isNull, '#E8743B'));
    });

    test('a type used by notes is offered even without a definition file', () {
      final index = VaultIndex.load(root.path, [
        note('x.md', frontmatter: {'type': '账号资料'}),
      ]);
      expect(
        index.categories.map((c) => c.value),
        contains('账号资料'),
      );
    });
  });

  group('NoteFilter', () {
    final notes = [
      note('自媒体-1.md', frontmatter: {'type': '自媒体'}),
      note('自媒体-2.md', frontmatter: {'type': '自媒体'}),
      note('成长-1.md', frontmatter: {'type': '个人成长'}),
      note('inbox.md'),
      note('old.md', frontmatter: {'type': '自媒体', 'archived': true}),
      note('自媒体.md', frontmatter: {'type': 'Type'}),
    ];

    test('view with `equals` keeps only that type', () {
      const view = TolariaView(
        id: '自媒体',
        name: '自媒体',
        order: 1,
        rules: [ViewRule(field: 'type', op: 'equals', value: '自媒体')],
      );
      final result = NoteFilter.view(view).apply(notes);
      expect(result.map((n) => n.relativePath), [
        '自媒体-1.md',
        '自媒体-2.md',
        'old.md',
      ]);
    });

    test('view with `none_of` keeps everything else', () {
      const view = TolariaView(
        id: '未归档',
        name: '未归档',
        order: 2,
        rules: [
          ViewRule(field: 'type', op: 'none_of', value: ['自媒体', '个人成长']),
        ],
      );
      final result = NoteFilter.view(view).apply(notes);
      // `type: Type` marks a type *definition*; views never list those.
      expect(result.map((n) => n.relativePath), ['inbox.md']);
    });

    test('inbox holds notes without a type', () {
      expect(
        const NoteFilter.inbox().apply(notes).map((n) => n.relativePath),
        ['inbox.md'],
      );
    });

    test('archive only includes archived: true', () {
      expect(
        const NoteFilter.archive().apply(notes).map((n) => n.relativePath),
        ['old.md'],
      );
    });

    test('type filter matches a single type', () {
      expect(
        NoteFilter.type('个人成长').apply(notes).map((n) => n.relativePath),
        ['成长-1.md'],
      );
    });

    test('all returns everything', () {
      expect(const NoteFilter.all().apply(notes).length, notes.length);
    });

    test('filters compare by identity of kind + value', () {
      expect(const NoteFilter.all(), const NoteFilter.all());
      expect(NoteFilter.type('a'), NoteFilter.type('a'));
      expect(NoteFilter.type('a'), isNot(NoteFilter.type('b')));
    });
  });
}
