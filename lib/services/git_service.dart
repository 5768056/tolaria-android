import 'dart:io';

import 'cli_git_service.dart';
import 'git2dart_service.dart';
import 'git_progress.dart';

export 'git_job_runner.dart' show GitJobCancelled, GitOperationError;
export 'git_progress.dart' show GitProgress;

/// Credentials for an HTTPS git remote. Nothing here is persisted to disk.
class GitCredentials {
  final String? username;
  final String? password;

  const GitCredentials({this.username, this.password});

  bool get isEmpty =>
      (username == null || username!.isEmpty) &&
      (password == null || password!.isEmpty);

  bool get isComplete =>
      username != null && username!.isNotEmpty &&
      password != null && password!.isNotEmpty;
}

/// Result of a clone: which branch actually ended up checked out.
///
/// The branch matters — a vault may use `master` while the form defaults to
/// `main`. Pushing `HEAD:refs/heads/main` in that case would silently create a
/// *second* branch on the remote instead of updating the real one.
class CloneOutcome {
  const CloneOutcome({required this.branch, required this.path});

  final String branch;
  final String path;
}

/// What a pull actually did.
///
/// "已是最新" and "拉到 3 个新提交" are very different signals, and lumping
/// them together is why every pull looked like it had done something: the UI
/// could only ever say "拉取完成", even when nothing crossed the network.
enum PullStatus {
  /// The remote tip equalled what was already fetched — no transfer happened.
  upToDate,

  /// New commits came in and the working tree now reflects them.
  updated,

  /// A merge produced conflicts; they are left in the working tree.
  conflict,
}

class PullOutcome {
  const PullOutcome({
    required this.status,
    this.commits = 0,
    this.fetched = true,
  });

  final PullStatus status;

  /// How many commits the local branch moved forward, when cheap to count.
  final int commits;

  /// Whether any bytes were actually requested from the remote.
  ///
  /// Not mere diagnostics: pulls that download nothing are the common case, and
  /// this is what makes "远程没有变化" distinguishable from "拉到了东西" — without
  /// it every pull looked like it had done work.
  final bool fetched;

  static PullOutcome fromMap(Object? raw) {
    if (raw is! Map) return const PullOutcome(status: PullStatus.updated);
    final name = raw['status'] as String?;
    return PullOutcome(
      status: PullStatus.values.firstWhere(
        (value) => value.name == name,
        orElse: () => PullStatus.updated,
      ),
      commits: (raw['commits'] as num?)?.toInt() ?? 0,
      fetched: raw['fetched'] as bool? ?? true,
    );
  }

  @override
  String toString() =>
      'PullOutcome(${status.name}, commits: $commits, fetched: $fetched)';
}

/// Platform-agnostic git operations.
///
/// Two backends exist on purpose:
///  * [CliGitService] shells out to a real `git` binary and is used on desktop
///    (where `git` is available). This keeps the logic simple and easy to verify.
///  * [Git2DartService] uses libgit2 via FFI and is used on Android, where no
///    `git` executable exists. It runs every call on a background isolate
///    because libgit2 is synchronous and would otherwise freeze the UI.
abstract class GitService {
  String get repoPath;

  /// Receives transfer progress for clone / push / pull.
  set onProgress(void Function(GitProgress progress)? callback);

  Future<bool> isRepo();

  Future<void> init();

  Future<CloneOutcome> clone(
    String url, {
    GitCredentials? credentials,
    String? branch,
  });

  /// Create or update a named remote pointing at [url].
  Future<void> configureRemote(String url, {String remote = 'origin'});

  /// Commit every working-tree change. Returns false when there was nothing to
  /// commit (keeps "sync" idempotent instead of piling up empty commits).
  Future<bool> commitAll(
    String message, {
    required String authorName,
    required String authorEmail,
  });

  Future<void> push({
    String remote = 'origin',
    String branch = 'main',
    GitCredentials? credentials,
  });

  /// Fetch from [remote] and integrate [branch] into the working tree.
  ///
  /// Implementations skip the network entirely when the remote tip is already
  /// fetched locally — the phone pulls several times a day and most of those
  /// pulls have nothing to download.
  Future<PullOutcome> pull({
    String remote = 'origin',
    String branch = 'main',
    GitCredentials? credentials,
  });

  /// Files with uncommitted changes (porcelain-style paths).
  Future<List<String>> status();

  /// Branch HEAD currently points at, or null for an unborn branch.
  Future<String?> currentBranch();

  /// Remembers credentials for later calls made through this instance.
  void useCredentials(GitCredentials? credentials);

  static GitService create(String repoPath) {
    if (Platform.isAndroid || Platform.isIOS) {
      return Git2DartService(repoPath);
    }
    return CliGitService(repoPath);
  }
}
