import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:tolaria_android/services/git2dart_service.dart';

/// Exercises the Android git backend on the host machine.
///
/// git2dart ships libgit2 for desktop too, so the exact code path used on
/// Android can be verified without an emulator. This covers the three things
/// that historically break: the first (parentless) commit, deletions, and
/// .gitignore handling.
void main() {
  late Directory tmp;

  setUp(() {
    tmp = Directory.systemTemp.createTempSync('tolaria_git2dart_');
  });

  tearDown(() {
    if (tmp.existsSync()) tmp.deleteSync(recursive: true);
  });

  File note(String name) => File(p.join(tmp.path, name));

  String headOid() {
    final head = File(p.join(tmp.path, '.git', 'refs', 'heads', 'main'));
    return head.readAsStringSync().trim();
  }

  test('init creates a repo with a main branch', () async {
    final git = Git2DartService(tmp.path);
    expect(await git.isRepo(), isFalse);
    await git.init();
    expect(await git.isRepo(), isTrue);
    expect(
      File(p.join(tmp.path, '.git', 'HEAD')).readAsStringSync(),
      contains('refs/heads/main'),
    );
  });

  test('commitAll creates a root commit and leaves a clean tree', () async {
    final git = Git2DartService(tmp.path);
    await git.init();

    note('Welcome.md').writeAsStringSync('# Welcome\n\nhello [[Other]]\n');
    note('Other.md').writeAsStringSync('# Other\n');

    await git.commitAll('initial', authorName: 'T', authorEmail: 't@test.dev');

    expect(headOid(), isNotEmpty);
    expect(await git.status(), isEmpty);
    // A second identical commit must be skipped, otherwise every "sync" would
    // add noise to the history.
    expect(
      await git.commitAll('initial again',
          authorName: 'T', authorEmail: 't@test.dev'),
      isFalse,
    );
  });

  test('commitAll picks up modifications, additions and deletions', () async {
    final git = Git2DartService(tmp.path);
    await git.init();

    note('a.md').writeAsStringSync('# A\n');
    note('b.md').writeAsStringSync('# B\n');
    await git.commitAll('first', authorName: 'T', authorEmail: 't@test.dev');
    final firstCommit = headOid();

    note('a.md').writeAsStringSync('# A v2\n');
    note('c.md').writeAsStringSync('# C\n');
    note('b.md').deleteSync();

    // `repo.status` reports tracked changes; brand-new untracked files are
    // only picked up by the commit itself, so assert on tracked entries here.
    expect((await git.status()).toSet(), containsAll(<String>['a.md', 'b.md']));

    await git.commitAll('second', authorName: 'T', authorEmail: 't@test.dev');
    final secondCommit = headOid();

    expect(secondCommit, isNot(firstCommit));
    expect(await git.status(), isEmpty);
  });

  test('commitAll is a no-op when nothing changed', () async {
    final git = Git2DartService(tmp.path);
    await git.init();
    note('a.md').writeAsStringSync('# A\n');
    await git.commitAll('first', authorName: 'T', authorEmail: 't@test.dev');
    final firstCommit = headOid();

    await git.commitAll('second', authorName: 'T', authorEmail: 't@test.dev');
    expect(headOid(), firstCommit);
  });

  test('.gitignore is respected', () async {
    final git = Git2DartService(tmp.path);
    await git.init();
    note('.gitignore').writeAsStringSync('.obsidian/\n*.tmp\n');
    note('keep.md').writeAsStringSync('# Keep\n');
    Directory(p.join(tmp.path, '.obsidian')).createSync();
    note('.obsidian/workspace.json').writeAsStringSync('{}');
    note('scratch.tmp').writeAsStringSync('junk');

    await git.commitAll('ignored', authorName: 'T', authorEmail: 't@test.dev');

    final tracked = await git.trackedFiles();
    expect(tracked, contains('keep.md'));
    expect(tracked, contains('.gitignore'));
    expect(tracked, isNot(contains('scratch.tmp')));
    expect(tracked, isNot(contains('.obsidian/workspace.json')));
  });
}
