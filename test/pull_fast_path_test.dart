import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:git2dart/git2dart.dart' as g;
import 'package:path/path.dart' as p;
import 'package:tolaria_android/services/git2dart_service.dart';
import 'package:tolaria_android/services/git_service.dart';

/// Coverage for the "拉取太慢" fix.
///
/// A phone sync runs several times a day and almost never has anything to
/// download, yet the old code negotiated a full pack every time. These tests
/// pin down the two behaviours that make the fast path safe:
///  * nothing changed remotely -> **no** transfer, reported as `upToDate`;
///  * something changed -> still pulled, and only the requested branch.
///
/// A local source repository keeps everything offline; what is being asserted
/// here is which libgit2 steps run, not how long the bytes take.
void main() {
  late Directory root;
  late Directory source;
  late Directory target;

  setUp(() async {
    root = Directory.systemTemp.createTempSync('tolaria_pull_');
    source = Directory(p.join(root.path, 'source'));
    target = Directory(p.join(root.path, 'target'));

    final git = Git2DartService(source.path);
    await git.init();
    File(p.join(source.path, 'Welcome.md')).writeAsStringSync('# Welcome\n');
    await git.commitAll('seed', authorName: 'T', authorEmail: 't@test.dev');
  });

  tearDown(() {
    if (root.existsSync()) root.deleteSync(recursive: true);
  });

  String urlOf(Directory dir) => Uri.file(dir.path).toString();

  Future<Git2DartService> cloned() async {
    final git = Git2DartService(target.path);
    await git.clone(urlOf(source), branch: 'main');
    return git;
  }

  /// Adds a commit to whichever branch [source] currently has checked out.
  Future<void> commitOnSource(String message, {required String file}) async {
    File(p.join(source.path, file)).writeAsStringSync('# $file\n\n$message\n');
    final git = Git2DartService(source.path);
    await git.commitAll(message, authorName: 'T', authorEmail: 't@test.dev');
  }

  Future<void> createSourceBranch(String name) async {
    final repo = g.Repository.open(source.path);
    try {
      final head = g.Commit.lookup(repo: repo, oid: repo.head.target);
      g.Branch.create(repo: repo, name: name, target: head);
      repo.setHead('refs/heads/$name');
      repo.reset(oid: repo.head.target, resetType: g.GitReset.hard);
    } finally {
      repo.free();
    }
  }

  Future<void> checkoutSource(String name) async {
    final repo = g.Repository.open(source.path);
    try {
      repo.setHead('refs/heads/$name');
      repo.reset(oid: repo.head.target, resetType: g.GitReset.hard);
    } finally {
      repo.free();
    }
  }

  bool trackingRefExists(String name) {
    final repo = g.Repository.open(target.path);
    try {
      g.Reference.lookup(repo: repo, name: 'refs/remotes/origin/$name').free();
      return true;
    } catch (_) {
      return false;
    } finally {
      repo.free();
    }
  }

  test('nothing to download means no transfer is reported', () async {
    final git = await cloned();

    final withoutChanges = await git.pull(branch: 'main');

    expect(withoutChanges.status, PullStatus.upToDate);
    // Reported by the worker itself, so a regression that quietly reinstates
    // the old full negotiation on every pull fails here. "upToDate" alone
    // would not catch it: a pull that downloads everything can still find
    // nothing to merge.
    expect(withoutChanges.fetched, isFalse);

    await commitOnSource('add note', file: 'Second.md');
    final withChanges = await git.pull(branch: 'main');

    expect(withChanges.status, PullStatus.updated);
    expect(withChanges.fetched, isTrue);
  }, timeout: const Timeout(Duration(minutes: 2)));

  test('an unreachable remote fails loudly instead of saying upToDate', () async {
    final git = await cloned();
    // The counterpart of the case above: "upToDate" must never be a cover for
    // "did not bother asking". With no remote at all, pull has to complain.
    source.deleteSync(recursive: true);

    await expectLater(
      git.pull(branch: 'main'),
      throwsA(isA<GitOperationError>()),
    );
  }, timeout: const Timeout(Duration(minutes: 2)));

  test('a pull with nothing new says upToDate and touches no files', () async {
    final git = await cloned();
    final before = File(p.join(target.path, 'Welcome.md')).statSync().modified;

    final outcome = await git.pull(branch: 'main');

    expect(outcome.status, PullStatus.upToDate);
    expect(outcome.commits, 0);
    // No working-tree rewrite means mtimes are untouched — this is what lets
    // the note list skip its full re-read on the common path.
    expect(File(p.join(target.path, 'Welcome.md')).statSync().modified, before);
  }, timeout: const Timeout(Duration(minutes: 2)));

  test('a remote-only change is still pulled, and counted', () async {
    final git = await cloned();
    await commitOnSource('add note', file: 'Second.md');

    final outcome = await git.pull(branch: 'main');

    expect(outcome.status, PullStatus.updated);
    expect(outcome.commits, 1);
    expect(File(p.join(target.path, 'Second.md')).existsSync(), isTrue);
    expect(File(p.join(target.path, 'Second.md')).readAsStringSync(),
        contains('add note'));
  }, timeout: const Timeout(Duration(minutes: 2)));

  test('a second pull after the change is upToDate again', () async {
    final git = await cloned();
    await commitOnSource('add note', file: 'Second.md');

    expect((await git.pull(branch: 'main')).status, PullStatus.updated);
    // The second call must take the fast path, not re-download the same pack.
    expect((await git.pull(branch: 'main')).status, PullStatus.upToDate);
  }, timeout: const Timeout(Duration(minutes: 2)));

  test('only the requested branch is fetched', () async {
    final git = await cloned();
    await createSourceBranch('scratch');
    await commitOnSource('work in progress', file: 'Scratch.md');
    await checkoutSource('main');

    await git.pull(branch: 'main');

    // The other branch exists on the remote but must not have been downloaded:
    // a vault that has accumulated a dozen branches should not pay for them on
    // every phone sync.
    expect(trackingRefExists('scratch'), isFalse);
    expect(trackingRefExists('main'), isTrue);
  }, timeout: const Timeout(Duration(minutes: 2)));

  test('a workspace that never fetched before still does', () async {
    // No `refs/remotes/origin/main` -> the tip comparison has nothing to
    // compare, so the fast path must not be taken by accident.
    Directory(p.join(target.path)).createSync(recursive: true);
    File(p.join(target.path, 'pre.md')).writeAsStringSync('# pre\n');
    final git = Git2DartService(target.path);
    await git.init();
    await git.configureRemote(urlOf(source));
    await git.commitAll('local seed', authorName: 'T', authorEmail: 't@test.dev');

    final outcome = await git.pull(branch: 'main');

    // Unrelated histories merge rather than fast-forward; either way the remote
    // content has to arrive.
    expect(outcome.status, isNot(PullStatus.upToDate));
    expect(trackingRefExists('main'), isTrue);
  }, timeout: const Timeout(Duration(minutes: 2)));

  test('pulling a branch that does not exist explains itself', () async {
    final git = await cloned();

    await expectLater(
      git.pull(branch: 'release-does-not-exist'),
      throwsA(
        isA<GitOperationError>().having(
          (e) => e.message + (e.detail ?? ''),
          'message',
          contains('检查设置里的分支名'),
        ),
      ),
    );
  }, timeout: const Timeout(Duration(minutes: 2)));

  test('a local-only commit survives pulling an unrelated remote tip', () async {
    final git = await cloned();
    // Commit locally before the remote moves, forcing a real merge instead of
    // a fast-forward reset (which would silently drop the local note).
    await commitLocally(target, 'mine.md', 'local note');
    await commitOnSource('remote note', file: 'Theirs.md');

    await git.pull(branch: 'main');

    expect(File(p.join(target.path, 'mine.md')).existsSync(), isTrue,
        reason: '本地未推送的笔记被拉取吃掉了');
    expect(File(p.join(target.path, 'Theirs.md')).existsSync(), isTrue);
  }, timeout: const Timeout(Duration(minutes: 2)));
}

Future<void> commitLocally(Directory repo, String file, String message) async {
  File(p.join(repo.path, file)).writeAsStringSync('# $message\n');
  final git = Git2DartService(repo.path);
  await git.commitAll(message, authorName: 'T', authorEmail: 't@test.dev');
}
