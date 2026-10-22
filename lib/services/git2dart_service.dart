import 'dart:io';

import 'package:path/path.dart' as p;

import 'git_job_runner.dart';
import 'git_service.dart';
import 'git_worker.dart';

/// Android git backend built on libgit2 (via FFI), so no system `git` binary is
/// required.
///
/// Every method here only builds a job description and hands it to
/// [GitJobRunner], which executes it on a background isolate. libgit2 is
/// synchronous FFI — calling it directly froze the UI long enough for Android
/// to declare an ANR, which is why nothing in this class touches libgit2 itself.
///
/// `PlatformSpecific.initialize()` must be awaited in `main()` before the first
/// call, otherwise the bundled CA bundle is not wired into libgit2.
class Git2DartService implements GitService {
  @override
  final String repoPath;

  Git2DartService(this.repoPath);

  /// Credentials for the in-flight job. Kept as a field so the `GitService`
  /// signature stays stateless-friendly.
  GitCredentials? _credentials;

  /// Called with 0-100 while objects are being received.
  void Function(GitProgress progress)? onProgress;

  Map<String, Object?> _job(String op, {Map<String, Object?> extra = const {}}) {
    return <String, Object?>{
      'op': op,
      'repoPath': repoPath,
      ...extra,
      if (_credentials != null) ...{
        'username': _credentials!.username,
        'password': _credentials!.password,
      },
    };
  }

  @override
  void useCredentials(GitCredentials? credentials) => _credentials = credentials;

  @override
  Future<bool> isRepo() async {
    try {
      final result = await GitJobRunner.run(_job(GitOp.isRepo));
      return result == true;
    } catch (_) {
      return false;
    }
  }

  @override
  Future<void> init() async {
    await GitJobRunner.run(_job(GitOp.init));
  }

  @override
  Future<CloneOutcome> clone(
    String url, {
    GitCredentials? credentials,
    String? branch,
  }) async {
    final dir = Directory(repoPath);
    if (dir.existsSync() && dir.listSync().isNotEmpty) {
      throw GitOperationError('目标目录非空，无法克隆到：$repoPath');
    }
    dir.createSync(recursive: true);

    final result = await GitJobRunner.run(
      <String, Object?>{
        'op': GitOp.clone,
        'path': repoPath,
        'url': url,
        'branch': branch,
        if (credentials != null) ...{
          'username': credentials.username,
          'password': credentials.password,
        },
      },
      onProgress: onProgress,
    );

    final map = (result as Map).cast<String, Object?>();
    return CloneOutcome(
      branch: (map['branch'] as String?) ?? branch ?? 'main',
      path: p.normalize(map['path'] as String? ?? repoPath),
    );
  }

  @override
  Future<void> configureRemote(String url, {String remote = 'origin'}) async {
    await GitJobRunner.run(_job(GitOp.setRemote, extra: {
      'url': url,
      'remote': remote,
    }));
  }

  /// Returns true when a commit was actually created (false = nothing changed).
  @override
  Future<bool> commitAll(
    String message, {
    required String authorName,
    required String authorEmail,
  }) async {
    final created = await GitJobRunner.run(_job(GitOp.commit, extra: {
      'message': message,
      'authorName': authorName,
      'authorEmail': authorEmail,
    }));
    return created == true;
  }

  @override
  Future<void> push({
    String remote = 'origin',
    String branch = 'main',
    GitCredentials? credentials,
  }) async {
    if (credentials != null) _credentials = credentials;
    await GitJobRunner.run(
      _job(GitOp.push, extra: {'remote': remote, 'branch': branch}),
      onProgress: onProgress,
    );
  }

  @override
  Future<PullOutcome> pull({
    String remote = 'origin',
    String branch = 'main',
    GitCredentials? credentials,
  }) async {
    if (credentials != null) _credentials = credentials;
    final result = await GitJobRunner.run(
      _job(GitOp.pull, extra: {'remote': remote, 'branch': branch}),
      onProgress: onProgress,
    );
    return PullOutcome.fromMap(result);
  }

  @override
  Future<List<String>> status() async {
    final result = await GitJobRunner.run(_job(GitOp.status));
    return (result as List).cast<String>();
  }

  /// Paths currently staged in the index — i.e. exactly what the next commit
  /// would record. `.gitignore`d files never appear here.
  Future<List<String>> trackedFiles() async {
    final result = await GitJobRunner.run(_job(GitOp.tracked));
    return (result as List).cast<String>();
  }

  @override
  Future<String?> currentBranch() async {
    final result = await GitJobRunner.run(_job(GitOp.headBranch));
    return result as String?;
  }
}
