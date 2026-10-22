import 'dart:io';

import 'git_service.dart';

/// Desktop git backend: wraps the system `git` executable.
///
/// This is deliberately thin — the same commands a developer would type. It is
/// only used on platforms that ship a `git` binary (desktop / CI), never on
/// Android.
class CliGitService implements GitService {
  @override
  final String repoPath;

  CliGitService(this.repoPath);

  GitCredentials? _credentials;

  /// CLI git reports progress on stderr with `--progress`; not parsed here —
  /// desktop operations are fast enough that a spinner is plenty.
  @override
  void Function(GitProgress progress)? onProgress;

  @override
  void useCredentials(GitCredentials? credentials) => _credentials = credentials;

  GitCredentials? _creds(GitCredentials? explicit) => explicit ?? _credentials;

  Future<ProcessResult> _run(List<String> args) async {
    try {
      return await Process.run('git', args, workingDirectory: repoPath);
    } on ProcessException catch (e) {
      throw Exception('找不到 git 可执行文件，请确认已安装 git。(${e.message})');
    }
  }

  /// Embed credentials into an HTTPS URL for a single command, without writing
  /// them into `.git/config`.
  String _withCredentials(String url, GitCredentials? credentials) {
    if (credentials == null || credentials.isEmpty) return url;
    if (credentials.username == null || credentials.password == null) return url;
    final uri = Uri.tryParse(url);
    if (uri == null || uri.scheme != 'https') return url;
    final user = Uri.encodeComponent(credentials.username!);
    final pass = Uri.encodeComponent(credentials.password!);
    return uri.replace(userInfo: '$user:$pass').toString();
  }

  void _ensureOk(ProcessResult result, String op) {
    if (result.exitCode != 0) {
      throw Exception('$op 失败 (exit ${result.exitCode}):\n${result.stderr}');
    }
  }

  @override
  Future<bool> isRepo() async {
    final r = await _run(['rev-parse', '--is-inside-work-tree']);
    return r.exitCode == 0 && (r.stdout as String).trim() == 'true';
  }

  @override
  Future<void> init() async {
    final dir = Directory(repoPath);
    if (!dir.existsSync()) dir.createSync(recursive: true);
    final r = await _run(['init', '-b', 'main']);
    if (r.exitCode != 0) {
      // Older git without -b support.
      _ensureOk(await _run(['init']), 'git init');
    }
  }

  @override
  Future<CloneOutcome> clone(
    String url, {
    GitCredentials? credentials,
    String? branch,
  }) async {
    final dir = Directory(repoPath);
    if (!dir.existsSync()) dir.createSync(recursive: true);

    final creds = _creds(credentials);
    final args = <String>['clone'];
    if (branch != null && branch.isNotEmpty) {
      args.addAll(['--branch', branch]);
    }
    args.addAll([_withCredentials(url, creds), '.']);

    var r = await Process.run('git', args, workingDirectory: repoPath);
    if (r.exitCode != 0 && branch != null && branch.isNotEmpty) {
      // Branch missing locally is a common false alarm: retry against the
      // remote's default branch and report what actually got checked out.
      final retryArgs = <String>['clone', _withCredentials(url, creds), '.'];
      r = await Process.run('git', retryArgs, workingDirectory: repoPath);
    }
    _ensureOk(r, 'git clone');

    // Never leave credentials sitting in .git/config.
    if (creds != null && !creds.isEmpty) {
      await _run(['remote', 'set-url', 'origin', url]);
    }

    final head = await currentBranch();
    return CloneOutcome(branch: head ?? branch ?? 'main', path: repoPath);
  }

  @override
  Future<String?> currentBranch() async {
    final r = await _run(['rev-parse', '--abbrev-ref', 'HEAD']);
    if (r.exitCode != 0) return null;
    final name = (r.stdout as String).trim();
    if (name.isEmpty || name == 'HEAD') return null;
    return name;
  }

  @override
  Future<void> configureRemote(String url, {String remote = 'origin'}) async {
    final existing = await _run(['remote', 'get-url', remote]);
    if (existing.exitCode == 0) {
      _ensureOk(
        await _run(['remote', 'set-url', remote, url]),
        'git remote set-url',
      );
    } else {
      _ensureOk(
        await _run(['remote', 'add', remote, url]),
        'git remote add',
      );
    }
  }

  @override
  Future<bool> commitAll(
    String message, {
    required String authorName,
    required String authorEmail,
  }) async {
    _ensureOk(await _run(['add', '-A']), 'git add -A');
    final r = await _run([
      '-c',
      'user.name=$authorName',
      '-c',
      'user.email=$authorEmail',
      'commit',
      '-m',
      message,
    ]);
    final output = '${r.stdout}${r.stderr}';
    final nothingToCommit =
        output.contains('nothing to commit') || output.contains('无文件要提交');
    if (r.exitCode != 0 && !nothingToCommit) {
      _ensureOk(r, 'git commit');
    }
    return r.exitCode == 0;
  }

  Future<String> _remoteUrl(String remote) async {
    final r = await _run(['remote', 'get-url', remote]);
    if (r.exitCode != 0) return '';
    return (r.stdout as String).trim();
  }

  @override
  Future<void> push({
    String remote = 'origin',
    String branch = 'main',
    GitCredentials? credentials,
  }) async {
    final url = await _remoteUrl(remote);
    if (url.isEmpty) {
      throw Exception('未配置远程仓库 ($remote)。请在设置中填写仓库地址。');
    }
    final target = _withCredentials(url, credentials);
    final r = await _run(['push', target, 'HEAD:refs/heads/$branch']);
    _ensureOk(r, 'git push');
  }

  @override
  Future<PullOutcome> pull({
    String remote = 'origin',
    String branch = 'main',
    GitCredentials? credentials,
  }) async {
    final url = await _remoteUrl(remote);
    if (url.isEmpty) {
      throw Exception('未配置远程仓库 ($remote)。请在设置中填写仓库地址。');
    }
    final before = await _headOid();
    final target = _withCredentials(url, credentials);
    final r = await _run(['pull', '--no-rebase', '--no-tags', target, branch]);

    if (r.exitCode == 0) {
      final after = await _headOid();
      if (before == null || after == null || before == after) {
        return const PullOutcome(status: PullStatus.upToDate);
      }
      return PullOutcome(
        status: PullStatus.updated,
        commits: await _commitsBetween(before, after),
      );
    }

    // Conflicts leave the merge half-done on purpose — the same contract the
    // libgit2 backend follows — so the caller can tell the user what to do.
    final output = '${r.stdout}${r.stderr}';
    if (output.contains('CONFLICT') || output.contains('Automatic merge failed')) {
      return const PullOutcome(status: PullStatus.conflict);
    }
    _ensureOk(r, 'git pull');
    return const PullOutcome(status: PullStatus.upToDate);
  }

  Future<String?> _headOid() async {
    final r = await _run(['rev-parse', 'HEAD']);
    if (r.exitCode != 0) return null;
    final id = (r.stdout as String).trim();
    return id.isEmpty ? null : id;
  }

  Future<int> _commitsBetween(String before, String after) async {
    final r = await _run(['rev-list', '--count', '$before..$after']);
    if (r.exitCode != 0) return 0;
    return int.tryParse((r.stdout as String).trim()) ?? 0;
  }

  @override
  Future<List<String>> status() async {
    final r = await _run(['status', '--porcelain']);
    if (r.exitCode != 0) return const [];
    return (r.stdout as String)
        .split('\n')
        .where((line) => line.trim().isNotEmpty)
        .toList();
  }
}
