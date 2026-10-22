import 'dart:io';
import 'dart:isolate';

import 'package:git2dart/git2dart.dart' as g;

import 'git_progress.dart';

/// Job kinds understood by the background worker.
///
/// Keep these as plain strings: the whole job is passed to another isolate as a
/// `Map<String, Object?>`, so nothing here may reference types that cannot be
/// copied across isolates.
abstract final class GitOp {
  static const clone = 'clone';
  static const init = 'init';
  static const setRemote = 'setRemote';
  static const commit = 'commit';
  static const push = 'push';
  static const pull = 'pull';
  static const status = 'status';
  static const tracked = 'tracked';
  static const headBranch = 'headBranch';
  static const isRepo = 'isRepo';
}

/// Entry point of the isolate spawned by `GitJobRunner`.
///
/// libgit2 calls are **synchronous** — a clone over HTTPS can block for
/// minutes. Running them on the UI isolate freezes the frame loop and Android
/// kills the app with an ANR ("Tolaria 没有响应"), which is exactly the bug this
/// indirection exists to prevent. Everything below therefore runs on a throwaway
/// isolate; results are shipped back as plain Dart values.
void gitJobMain(List<Object?> args) {
  final reply = args[0] as SendPort;
  final job = (args[1] as Map).cast<String, Object?>();
  try {
    final value = runGitJobSync(
      job,
      onProgress: (progress) {
        try {
          reply.send(<String, Object?>{'progress': progress.toMap()});
        } catch (_) {
          // Port closed because the UI cancelled: ignore.
        }
      },
    );
    reply.send(<String, Object?>{'ok': true, 'value': value});
  } catch (error, stack) {
    reply.send(<String, Object?>{
      'ok': false,
      'error': explainGitError(error),
      'detail': error.toString(),
      'stack': stack.toString(),
    });
  }
}

/// Runs one job **synchronously on the calling isolate**.
///
/// Used by [gitJobMain] inside the worker isolate, and as a last-resort fallback
/// by `GitJobRunner` if the isolate cannot load libgit2 (e.g. an OEM ROM that
/// blocks `dlopen` from a secondary isolate). Falling back to a blocked UI is
/// strictly better than refusing to clone at all.
Object? runGitJobSync(
  Map<String, Object?> job, {
  void Function(GitProgress progress)? onProgress,
}) {
  return _dispatch(job, onProgress ?? (_) {});
}

Object? _dispatch(
  Map<String, Object?> job,
  void Function(GitProgress progress) report,
) {
  switch (job['op'] as String?) {
    case GitOp.clone:
      return _clone(job, report);
    case GitOp.init:
      return _init(job);
    case GitOp.setRemote:
      return _setRemote(job);
    case GitOp.commit:
      return _commit(job);
    case GitOp.push:
      return _push(job, report);
    case GitOp.pull:
      return _pull(job, report);
    case GitOp.status:
      return _status(job);
    case GitOp.tracked:
      return _tracked(job);
    case GitOp.headBranch:
      return _headBranch(job);
    case GitOp.isRepo:
      return _isRepo(job);
    default:
      throw ArgumentError('未知的 git 操作: ${job['op']}');
  }
}

// ---------------------------------------------------------------------------
// Operations
// ---------------------------------------------------------------------------

Map<String, Object?> _clone(
  Map<String, Object?> job,
  void Function(GitProgress progress) report,
) {
  final url = job['url']! as String;
  final path = job['path']! as String;
  final branch = (job['branch'] as String?)?.trim();

  Directory(path).createSync(recursive: true);

  try {
    final repo = g.Repository.clone(
      url: url,
      localPath: path,
      checkoutBranch: (branch == null || branch.isEmpty) ? null : branch,
      callbacks: _callbacks(job, report),
    );
    return _cloneResult(repo, branch);
  } catch (error) {
    // `checkoutBranch` names a *local* branch that does not exist yet on a
    // fresh clone; libgit2 then fails with "reference 'refs/heads/x' not found"
    // even though the repository cloned fine. Retry once against the remote's
    // default branch instead of surfacing a confusing error.
    if (branch == null || branch.isEmpty || !_looksLikeMissingBranch(error)) {
      rethrow;
    }
    _wipe(path);
    Directory(path).createSync(recursive: true);
    final repo = g.Repository.clone(
      url: url,
      localPath: path,
      callbacks: _callbacks(job, report),
    );
    return _cloneResult(repo, null);
  }
}

Map<String, Object?> _cloneResult(g.Repository repo, String? requested) {
  try {
    String? head;
    try {
      head = repo.head.shorthand;
    } catch (_) {
      // Unborn HEAD on an empty remote: fall through to the requested branch.
    }
    return <String, Object?>{
      'path': repo.path,
      'branch': head ?? requested ?? 'main',
    };
  } finally {
    repo.free();
  }
}

bool _looksLikeMissingBranch(Object error) {
  final text = error.toString().toLowerCase();
  return text.contains('reference') ||
      text.contains('could not find') ||
      text.contains('not found') ||
      text.contains('no such branch');
}

bool _init(Map<String, Object?> job) {
  final path = job['repoPath']! as String;
  final dir = Directory(path);
  if (!dir.existsSync()) dir.createSync(recursive: true);
  final repo = g.Repository.init(path: path, initialHead: 'refs/heads/main');
  repo.free();
  return true;
}

bool _setRemote(Map<String, Object?> job) {
  final repo = g.Repository.open(job['repoPath']! as String);
  final name = (job['remote'] as String?) ?? 'origin';
  final url = job['url']! as String;
  try {
    try {
      g.Remote.create(repo: repo, name: name, url: url).free();
    } catch (_) {
      // Remote already exists — repoint it instead of failing.
      g.Remote.setUrl(repo: repo, remote: name, url: url);
    }
    return true;
  } finally {
    repo.free();
  }
}

bool _commit(Map<String, Object?> job) {
  final repo = g.Repository.open(job['repoPath']! as String);
  try {
    final index = repo.index;
    // Equivalent to `git add -A`: rebuild the index from the working tree so
    // new, modified AND deleted notes are all reflected. `defaults` keeps
    // .gitignore rules in force.
    index.clear();
    index.addAll(const ['*'], flags: const {g.GitIndexAddOption.defaults});
    index.write();

    if (!index.iterator.moveNext()) return false;

    final treeOid = index.writeTree();
    final parents = _parents(repo);
    // Identical tree to HEAD -> an empty commit would be pure noise. This is
    // what keeps "sync" idempotent when no note actually changed.
    if (parents.isNotEmpty && parents.first.treeOid == treeOid) return false;

    final name = (job['authorName'] as String?)?.trim();
    final email = (job['authorEmail'] as String?)?.trim();
    final signature = g.Signature.create(
      name: (name == null || name.isEmpty) ? 'Tolaria' : name,
      email: (email == null || email.isEmpty) ? 'tolaria@localhost' : email,
    );

    g.Commit.create(
      repo: repo,
      updateRef: 'HEAD',
      author: signature,
      committer: signature,
      message: (job['message'] as String?) ?? 'Tolaria 同步',
      tree: g.Tree.lookup(repo: repo, oid: treeOid),
      parents: parents,
    );
    return true;
  } finally {
    repo.free();
  }
}

List<g.Commit> _parents(g.Repository repo) {
  try {
    if (repo.isEmpty) return const [];
    return [g.Commit.lookup(repo: repo, oid: repo.head.target)];
  } catch (_) {
    return const [];
  }
}

bool _push(
  Map<String, Object?> job,
  void Function(GitProgress progress) report,
) {
  final repo = g.Repository.open(job['repoPath']! as String);
  final remote = (job['remote'] as String?) ?? 'origin';
  final branch = (job['branch'] as String?) ?? 'main';
  try {
    final r = g.Remote.lookup(repo: repo, name: remote);
    try {
      r.push(
        refspecs: ['HEAD:refs/heads/$branch'],
        callbacks: _callbacks(job, report),
      );
    } finally {
      r.free();
    }
    return true;
  } finally {
    repo.free();
  }
}

/// Brings the working tree up to date with `$remote/$branch`.
///
/// Returns a map (consumed as [PullOutcome]) rather than a bool so the UI can
/// tell "nothing to do" apart from "pulled 3 commits".
///
/// The network part is deliberately skippable. A phone sync pulls many times a
/// day and almost always nothing has changed remotely, but the old code went
/// through the whole pack negotiation every single time: TLS handshake,
/// `info/refs`, then a POST carrying hundreds of `have` lines, just to be told
/// nothing new exists. That round-trip chain is most of what users experienced
/// as "拉取好慢". So: ask the remote for nothing but its tip first (one small
/// request), and only run the real fetch when that tip differs from what is
/// already fetched.
Map<String, Object?> _pull(
  Map<String, Object?> job,
  void Function(GitProgress progress) report,
) {
  final repo = g.Repository.open(job['repoPath']! as String);
  final remote = (job['remote'] as String?) ?? 'origin';
  final branch = (job['branch'] as String?) ?? 'main';
  final tracking = 'refs/remotes/$remote/$branch';
  try {
    final r = g.Remote.lookup(repo: repo, name: remote);
    final callbacks = _callbacks(job, report);
    var fetched = false;
    try {
      final localTip = _oidAt(repo, tracking);
      final alreadyThere = localTip != null &&
          _remoteTipMatchesHead(r, callbacks, branch, localTip);

      if (!alreadyThere) {
        // Download exactly this branch. The remote's default refspec is
        // `+refs/heads/*`, which drags in every branch the desktop app ever
        // created — a cost the phone pays for something it never looks at.
        _disableTagFollowing(repo, remote);
        r.fetch(
          refspecs: ['+refs/heads/$branch:$tracking'],
          callbacks: callbacks,
        );
        fetched = true;
      }
    } finally {
      r.free();
    }

    final g.Oid theirOid;
    try {
      theirOid = g.Reference.lookup(repo: repo, name: tracking).target;
    } catch (_) {
      throw Exception('远程分支 $remote/$branch 不存在，请检查设置里的分支名。');
    }

    final beforeCommit = _headOid(repo);

    // No local commit yet, or a branch that has never been born: just move
    // HEAD onto the remote tip.
    if (repo.isEmpty || repo.isBranchUnborn) {
      repo.reset(oid: theirOid, resetType: g.GitReset.hard);
      return {'status': 'updated', 'commits': 1, 'fetched': fetched};
    }

    final result = g.Merge.analysis(repo: repo, theirHead: theirOid).result;
    if (result.contains(g.GitMergeAnalysis.upToDate)) {
      return {'status': 'upToDate', 'commits': 0, 'fetched': fetched};
    }

    if (result.contains(g.GitMergeAnalysis.fastForward) ||
        result.contains(g.GitMergeAnalysis.unborn)) {
      repo.reset(oid: theirOid, resetType: g.GitReset.hard);
      return {
        'status': 'updated',
        'commits': _countAhead(repo, theirOid, beforeCommit),
        'fetched': fetched,
      };
    }

    if (result.contains(g.GitMergeAnalysis.normal)) {
      g.Merge.commit(
        repo: repo,
        commit: g.AnnotatedCommit.lookup(repo: repo, oid: theirOid),
      );

      if (repo.index.hasConflicts) {
        // Conflicts are written into the working tree and index; leaving the
        // merge state in place lets the user resolve them in the editor and
        // commit on the next sync.
        throw Exception('拉取产生冲突，请解决冲突文件后再提交（冲突已写入工作区）。');
      }

      final headOid = repo.head.target;
      final treeOid = repo.index.writeTree();
      final signature = g.Signature.create(
        name: 'Tolaria',
        email: 'tolaria@localhost',
      );
      g.Commit.create(
        repo: repo,
        updateRef: 'HEAD',
        author: signature,
        committer: signature,
        message: 'Merge remote-tracking branch $remote/$branch',
        tree: g.Tree.lookup(repo: repo, oid: treeOid),
        parents: [
          g.Commit.lookup(repo: repo, oid: headOid),
          g.Commit.lookup(repo: repo, oid: theirOid),
        ],
      );
      repo.stateCleanup();
      return {
        'status': 'updated',
        'commits': _countAhead(repo, repo.head.target, beforeCommit),
        'fetched': fetched,
      };
    }
    return {'status': 'upToDate', 'commits': 0, 'fetched': fetched};
  } finally {
    repo.free();
  }
}

/// The tip this branch points at, or null when HEAD is unborn.
g.Oid? _headOid(g.Repository repo) {
  try {
    if (repo.isEmpty) return null;
    return repo.head.target;
  } catch (_) {
    return null;
  }
}

g.Oid? _oidAt(g.Repository repo, String name) {
  try {
    return g.Reference.lookup(repo: repo, name: name).target;
  } catch (_) {
    return null;
  }
}

/// Counts commits reachable from [tip] but not yet from [since].
///
/// Only feeds the "拉到 N 个提交" message, so an unreadable or oddly shaped
/// history degrades to "未知" rather than failing the pull. The walk is capped
/// because a vault synced from Git history going back years should not put a
/// thousand `Commit.lookup` calls between the user and their notes.
int _countAhead(g.Repository repo, g.Oid tip, g.Oid? since) {
  if (since == null || since == tip) return 0;
  var count = 0;
  var current = tip;
  final seen = <g.Oid>{};
  while (count < 500 && seen.add(current)) {
    List<g.Oid> parents;
    try {
      parents = g.Commit.lookup(repo: repo, oid: current).parents;
    } catch (_) {
      break;
    }
    if (parents.isEmpty) break;
    current = parents.first;
    count++;
    if (current == since) return count;
  }
  return count;
}

/// True when the remote's `$branch` tip equals [expected].
///
/// This is the cheap probe that lets a no-op pull finish without negotiating a
/// pack. It is advisory by design: anything going wrong here (no auth yet, odd
/// server, local transport quirk) falls back to doing the real fetch, so the
/// optimisation can never turn a working pull into a failing one.
bool _remoteTipMatchesHead(
  g.Remote remote,
  g.Callbacks callbacks,
  String branch,
  g.Oid expected,
) {
  try {
    final refs = remote.ls(callbacks: callbacks);
    for (final ref in refs) {
      if (ref.name == 'refs/heads/$branch') return ref.oid == expected;
    }
    return false;
  } catch (_) {
    return false;
  }
}

/// Stop pulling tags along with the branch.
///
/// A vault that has been running a while accumulates a tag per release; asking
/// the server for all of them on every phone sync is pure dead weight.
void _disableTagFollowing(g.Repository repo, String remote) {
  try {
    g.Remote.setAutotag(
      repo: repo,
      remote: remote,
      value: g.GitRemoteAutotag.none,
    );
  } catch (_) {
    // Worst case we download the tags; never worth failing a pull over.
  }
}

List<String> _status(Map<String, Object?> job) {
  final repo = g.Repository.open(job['repoPath']! as String);
  try {
    return repo.status.keys.toList(growable: false);
  } finally {
    repo.free();
  }
}

/// Paths currently staged in the index — i.e. exactly what the next commit
/// would record. `.gitignore`d files never appear here.
List<String> _tracked(Map<String, Object?> job) {
  final repo = g.Repository.open(job['repoPath']! as String);
  try {
    final out = <String>[];
    final iterator = repo.index.iterator;
    while (iterator.moveNext()) {
      out.add(iterator.current.path);
    }
    return out;
  } finally {
    repo.free();
  }
}

bool _isRepo(Map<String, Object?> job) {
  final path = job['repoPath']! as String;
  if (!Directory(path).existsSync()) return false;
  try {
    final repo = g.Repository.open(path);
    repo.free();
    return true;
  } catch (_) {
    return false;
  }
}

String? _headBranch(Map<String, Object?> job) {
  final repo = g.Repository.open(job['repoPath']! as String);
  try {
    try {
      // On a repository whose HEAD is unborn (fresh `init`, empty remote)
      // resolving HEAD throws — that is a legitimate "no branch yet" answer.
      return repo.head.shorthand;
    } catch (_) {
      return null;
    }
  } finally {
    repo.free();
  }
}

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

g.Callbacks _callbacks(
  Map<String, Object?> job,
  void Function(GitProgress progress) report,
) {
  final user = (job['username'] as String?)?.trim();
  final pass = job['password'] as String?;
  final hasCredentials =
      user != null && user.isNotEmpty && pass != null && pass.isNotEmpty;

  var lastPercent = -1;
  var lastBytes = 0;
  return g.Callbacks(
    credentials:
        hasCredentials ? g.UserPass(username: user, password: pass) : null,
    // Trust exactly what the platform trust store validated. On Android
    // `PlatformSpecific.initialize()` points libgit2 at the CA bundle shipped
    // with the app, so `valid` is already the right answer here.
    certificateCheck: (certificate, host, {required valid}) => valid,
    transferProgress: (progress) {
      // This runs inside a native callback: anything thrown here would abort
      // the isolate, so swallow hard.
      try {
        final total = progress.totalObjects;
        if (total <= 0) return;
        final received = progress.receivedObjects;
        final bytes = progress.receivedBytes;
        final percent = (received * 100 ~/ total).clamp(0, 100);
        // Only push a message when the user would see a difference: object
        // counts move in jumps, and flooding the UI isolate with thousands of
        // near-identical updates is what makes a legitimate clone look frozen.
        if (percent == lastPercent && bytes - lastBytes < 96 * 1024) return;
        lastPercent = percent;
        lastBytes = bytes;
        report(GitProgress(
          percent: percent,
          receivedBytes: bytes,
          receivedObjects: received,
          totalObjects: total,
        ));
      } catch (_) {
        // Ignore: progress reporting must never break the transfer.
      }
    },
  );
}

void _wipe(String path) {
  final dir = Directory(path);
  if (dir.existsSync()) dir.deleteSync(recursive: true);
}

/// Turns libgit2's terse native messages into something actionable in Chinese.
///
/// The raw text is still appended by callers (`detail`) so real errors are never
/// hidden — this only adds a human hint on top.
String explainGitError(Object error) {
  final raw = error.toString();
  final text = raw.toLowerCase();

  String hint(String suffix) => '$suffix\n\n原始错误：$raw';

  if (text.contains('401') || text.contains('authentication') ||
      text.contains('auth') && text.contains('required')) {
    return hint(
      '认证失败：用户名或密码/令牌不正确。\n'
      '· Gitee / GitHub 的「密码」位置要填私人访问令牌，不是登录密码；\n'
      '· 令牌需要有 repo（读写仓库）权限；\n'
      '· 用户名填账号名，GitHub 也可以填 x-access-token。',
    );
  }
  if (text.contains('403')) {
    return hint('没有权限访问该仓库（403）。请确认账号对仓库有读写权限，或令牌权限不足。');
  }
  if (text.contains('404') || text.contains('not found')) {
    return hint('仓库不存在或不可见（404）。私有仓库必须填正确凭据，仓库地址也要以 .git 结尾。');
  }
  if (text.contains('certificate') || text.contains('ssl') ||
      text.contains('tls')) {
    return hint('TLS/证书校验失败。请检查网络（是否有代理/抓包工具），或换用 https 地址。');
  }
  if (text.contains('could not resolve') || text.contains('resolve host') ||
      text.contains('name or service') || text.contains('timed out') ||
      text.contains('timeout')) {
    return hint('网络无法连接到代码托管服务器。请检查网络/代理，或换用手机网络重试。');
  }
  if (text.contains('does not exist') && text.contains('remote')) {
    return hint('远程仓库（origin）不存在，请先在设置里配置远程地址。');
  }
  return raw;
}
