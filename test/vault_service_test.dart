import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:tolaria_android/models/note_filter.dart';
import 'package:tolaria_android/services/vault_index.dart';
import 'package:tolaria_android/services/vault_service.dart';

/// Archive and category are frontmatter edits, so these tests check the exact
/// bytes on disk — including that the body and untouched keys survive.
void main() {
  late Directory root;
  late VaultService vault;

  const original = '''---
title: 带货脚本
type: 自媒体
tags:
  - 短视频
---

# 带货脚本

开头三秒要抓人。
''';

  setUp(() {
    root = Directory.systemTemp.createTempSync('tolaria_vault_');
    vault = VaultService(root.path);
    Directory(p.join(root.path, 'notes')).createSync();
  });

  tearDown(() {
    if (root.existsSync()) root.deleteSync(recursive: true);
  });

  String write(String name, String content) {
    File(p.join(root.path, name)).writeAsStringSync(content);
    return name;
  }

  String read(String name) =>
      File(p.join(root.path, name)).readAsStringSync();

  group('archive', () {
    test('writes the canonical _archived key and leaves the body alone', () {
      final path = write('notes/a.md', original);
      final note = vault.setArchived(path, true);

      expect(note.isArchived, isTrue);
      expect(read(path), contains('_archived: true'));
      expect(read(path), contains('# 带货脚本\n\n开头三秒要抓人。'));
      // Untouched keys keep their order and style.
      expect(read(path), contains('type: 自媒体\ntags:\n  - 短视频\n'));
    });

    test('unarchiving removes the key instead of writing false', () {
      final path = write('notes/a.md', original);
      vault.setArchived(path, true);
      final note = vault.setArchived(path, false);

      expect(note.isArchived, isFalse);
      expect(read(path), isNot(contains('_archived')));
      expect(read(path), isNot(contains('false')));
    });

    test('a legacy `archived:` flag is updated in place', () {
      final path = write(
        'notes/b.md',
        '---\ntitle: b\narchived: false\n---\nbody\n',
      );
      vault.setArchived(path, true);
      expect(read(path), '---\ntitle: b\narchived: true\n---\nbody\n');
    });

    test('mirrors through NoteFilter.archive', () {
      final a = write('notes/a.md', original);
      write('notes/b.md', '---\ntitle: b\n---\nbody\n');
      vault.setArchived(a, true);

      final index = VaultService(root.path).loadNotes();
      final archived = index.where((n) => n.isArchived).map((n) => n.relativePath);
      expect(archived, ['notes/a.md']);
    });
  });

  group('category', () {
    test('writes type and keeps the rest of the frontmatter verbatim', () {
      final path = write('notes/a.md', '---\ntitle: a\n---\nbody\n');
      final note = vault.setType(path, '个人成长');

      expect(note.noteType, '个人成长');
      expect(read(path), '---\ntitle: a\ntype: 个人成长\n---\nbody\n');
    });

    test('replaces an existing type', () {
      final path = write('notes/a.md', original);
      vault.setType(path, '技术教程');
      expect(read(path), contains('type: 技术教程\n'));
      expect(read(path), isNot(contains('type: 自媒体')));
    });

    test('null moves the note out of every category', () {
      final path = write('notes/a.md', original);
      final note = vault.setType(path, null);
      expect(note.noteType, isNull);
      expect(read(path), isNot(contains('type:')));
      // The tags list that followed it is still there.
      expect(read(path), contains('tags:\n  - 短视频\n'));
    });

    test('filing a note makes it appear in the matching view', () {
      final views = Directory(p.join(root.path, 'views'))..createSync();
      File(p.join(views.path, '自媒体.yml')).writeAsStringSync(
        'name: 自媒体\norder: 1\nfilters:\n  all:\n'
        '    - field: type\n      op: equals\n      value: 自媒体\n',
      );
      final path = write('notes/a.md', original);
      vault.setType(path, '自媒体');

      final notes = vault.loadNotes();
      final view = VaultIndex.load(root.path, notes).views.single;
      final listed = NoteFilter.view(view).apply(notes);
      expect(listed.map((n) => n.relativePath), ['notes/a.md']);
    });
  });

  group('createCategoryView', () {
    test('writes a view Tolaria can read back', () {
      vault.createCategoryView(name: '灵感素材', order: 3, color: '#D4A72C');

      final file = File(p.join(root.path, 'views', '灵感素材.yml'));
      expect(file.existsSync(), isTrue);
      final content = file.readAsStringSync();
      expect(content, contains('name: 灵感素材'));
      expect(content, contains('order: 3'));
      expect(content, contains('color: "#D4A72C"'));

      final index = VaultIndex.load(root.path, const []);
      expect(index.views.single.name, '灵感素材');
      expect(index.views.single.rules.single.field, 'type');
      expect(index.views.single.rules.single.value, '灵感素材');
    });

    test('does not overwrite a view that already exists', () {
      vault.createCategoryView(name: '灵感素材', order: 1);
      vault.createCategoryView(name: '灵感素材', order: 2);

      final files = Directory(p.join(root.path, 'views'))
          .listSync()
          .map((e) => p.basename(e.path))
          .toList()
        ..sort();
      expect(files, ['灵感素材-2.yml', '灵感素材.yml']);
    });
  });
}
