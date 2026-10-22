import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:tolaria_android/services/git2dart_service.dart';
import 'package:tolaria_android/services/git_job_runner.dart';

/// End-to-end coverage of the clone path used by the "克隆现有知识库" button.
///
/// Everything runs through `GitJobRunner`, i.e. on a background isolate exactly
/// like on Android — the clone used to run on the UI isolate and freeze the app
/// long enough for Android to show "Tolaria 没有响应". A local source repo keeps
/// the test offline and fast.
void main() {
  late Directory root;
  late Directory source;
  late Directory target;

  setUp(() async {
    root = Directory.systemTemp.createTempSync('tolaria_clone_');
    source = Directory(p.join(root.path, 'source'));
    target = Directory(p.join(root.path, 'target'));

    // Build a small vault to clone from.
    final git = Git2DartService(source.path);
    await git.init();
    for (final name in ['Welcome', 'Ideas', 'Reading']) {
      File(p.join(source.path, '$name.md')).writeAsStringSync('# $name\n');
    }
    Directory(p.join(source.path, 'notes')).createSync();
    File(p.join(source.path, 'notes', 'nested.md'))
        .writeAsStringSync('# Nested\n\nsee [[Welcome]]\n');
    // Bulk notes make the clone long enough to observe from the UI isolate.
    for (var i = 0; i < 150; i++) {
      File(p.join(source.path, 'notes', 'bulk-$i.md'))
          .writeAsStringSync('# Bulk $i\n\n${'lorem ipsum ' * 40}\n');
    }
    File(p.join(source.path, '.gitignore')).writeAsStringSync('*.tmp\n');
    await git.commitAll('seed', authorName: 'T', authorEmail: 't@test.dev');
  });

  tearDown(() {
    if (root.existsSync()) root.deleteSync(recursive: true);
  });

  String urlOf(Directory dir) => Uri.file(dir.path).toString();

  test('clones a local repo and reports the real branch', () async {
    final git = Git2DartService(target.path);
    final outcome = await git.clone(urlOf(source));

    expect(outcome.branch, 'main');
    expect(File(p.join(target.path, 'Welcome.md')).existsSync(), isTrue);
    expect(File(p.join(target.path, 'notes', 'nested.md')).existsSync(), isTrue);
    expect(await git.currentBranch(), 'main');
    expect(await git.status(), isEmpty);
  }, timeout: const Timeout(Duration(minutes: 2)));

  test('falls back to the default branch when the requested one is missing',
      () async {
    final git = Git2DartService(target.path);
    final outcome = await git.clone(urlOf(source), branch: 'release-does-not-exist');

    // The repo cloned fine; only the branch hint was wrong. Reporting the real
    // branch is what stops `push` from creating a second remote branch.
    expect(outcome.branch, 'main');
    expect(File(p.join(target.path, 'Welcome.md')).existsSync(), isTrue);
  }, timeout: const Timeout(Duration(minutes: 2)));

  test('refuses to clone into a non-empty directory', () async {
    Directory(target.path).createSync(recursive: true);
    File(p.join(target.path, 'existing.md')).writeAsStringSync('# keep me\n');

    final git = Git2DartService(target.path);
    await expectLater(
      git.clone(urlOf(source)),
      throwsA(isA<GitOperationError>()),
    );
    // The pre-existing file must survive the failed clone.
    expect(File(p.join(target.path, 'existing.md')).existsSync(), isTrue);
  }, timeout: const Timeout(Duration(minutes: 2)));

  test('clone keeps the UI isolate free to run timers', () async {
    var ticks = 0;
    final timer = Timer.periodic(const Duration(milliseconds: 1), (_) => ticks++);
    addTearDown(timer.cancel);

    final git = Git2DartService(target.path);
    await git.clone(urlOf(source));

    // If libgit2 ran on this isolate, the timer could not have ticked at all
    // while the clone was in flight.
    expect(ticks, greaterThan(0),
        reason: 'git 操作阻塞了主 isolate（会触发 Android ANR）');
  }, timeout: const Timeout(Duration(minutes: 2)));
}
