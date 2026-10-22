import 'dart:async';
import 'dart:isolate';

import 'git_progress.dart';
import 'git_worker.dart';

/// Raised when the background git job fails. [message] is user-facing (Chinese,
/// with an actionable hint); [detail] is the raw native error for diagnostics.
class GitOperationError implements Exception {
  GitOperationError(this.message, [this.detail]);

  final String message;
  final String? detail;

  @override
  String toString() => detail == null ? message : '$message\n($detail)';
}

/// Raised when the user cancelled a running job.
class GitJobCancelled implements Exception {
  @override
  String toString() => '操作已取消';
}

/// A job that outlived its timeout — the isolate may still be inside libgit2,
/// so the runner refuses new jobs for a while after this is thrown.
class _GitJobTimeout extends GitOperationError {
  _GitJobTimeout(super.message);
}

/// Runs libgit2 work on a throwaway isolate so the UI thread stays responsive.
///
/// Why this exists: every `git2dart` call is synchronous FFI. A clone of a
/// moderately sized vault takes far longer than Android's 5 s ANR budget, so
/// doing it on the UI isolate froze the app ("Tolaria 没有响应"). One isolate per
/// job also means a hung network operation can be killed outright.
abstract final class GitJobRunner {
  static Isolate? _active;
  static bool _cancelRequested = false;
  static bool _draining = false;
  static Timer? _drainTimer;

  /// True while a job is in flight — used to refuse overlapping operations.
  static bool get busy => _active != null || _draining;

  /// True once the user pressed "取消" on the running job.
  ///
  /// **Never `Isolate.kill()` a job that is inside libgit2.** Killing the
  /// isolate tears down the Dart heap while libgit2's own network threads are
  /// still mid-flight; the next progress callback lands on freed memory and the
  /// whole process disappears (observed on Android: tapping 取消 closed the
  /// app instantly, no Dart exception, just a native crash).
  ///
  /// So cancelling is cooperative: the flag makes [run] discard the result and
  /// throw [GitJobCancelled] as soon as libgit2 returns. The transfer may keep
  /// streaming for a few more seconds in the background, which is a fair price
  /// for not losing the user's app.
  static void cancel() {
    if (_active == null) return;
    _cancelRequested = true;
  }

  static Future<Object?> run(
    Map<String, Object?> job, {
    void Function(GitProgress progress)? onProgress,
    Duration timeout = const Duration(minutes: 15),
  }) async {
    if (_active != null || _draining) {
      throw GitOperationError(
        (_cancelRequested || _draining)
            ? '上一个操作正在后台收尾，请等几秒再试。'
            : '已有 git 操作正在进行，请稍候。',
      );
    }
    _cancelRequested = false;

    try {
      try {
        final value = await _runInIsolate(job, onProgress, timeout);
        if (_cancelRequested) throw GitJobCancelled();
        return value;
      } on _GitJobTimeout {
        // libgit2 may still be streaming: block new jobs instead of letting a
        // second operation land on the same working tree.
        _startDraining();
        rethrow;
      } on GitOperationError catch (error) {
        if (!_isUnusableIsolate(error)) rethrow;
        // Some ROMs refuse to dlopen a bundled .so from a secondary isolate.
        // Degrade to running on this isolate: the UI stalls during the
        // transfer, but the user still gets their clone/push.
        return runGitJobSync(job, onProgress: onProgress);
      }
    } finally {
      _active = null;
      _cancelRequested = false;
    }
  }

  /// Blocks new jobs briefly after an operation that did not finish cleanly.
  static void _startDraining() {
    _draining = true;
    _drainTimer?.cancel();
    _drainTimer = Timer(const Duration(seconds: 45), () => _draining = false);
  }

  static bool _isUnusableIsolate(GitOperationError error) {
    final text = '${error.detail ?? ''} ${error.message}'.toLowerCase();
    if (!text.contains('libgit2')) return false;
    return text.contains('open') ||
        text.contains('load') ||
        text.contains('shared object') ||
        text.contains('invalid argument');
  }

  static Future<Object?> _runInIsolate(
    Map<String, Object?> job,
    void Function(GitProgress progress)? onProgress,
    Duration timeout,
  ) async {
    final replies = ReceivePort();
    final errors = ReceivePort();
    final done = Completer<Object?>();

    void settle(Object? value, {Object? error}) {
      if (done.isCompleted) return;
      if (error != null) {
        done.completeError(error);
      } else {
        done.complete(value);
      }
    }

    final replySub = replies.listen((message) {
      if (message is Map) {
        if (message.containsKey('progress')) {
          final progress = GitProgress.fromMap(message['progress']);
          if (progress != null) onProgress?.call(progress);
          return;
        }
        if (message['ok'] == true) {
          settle(message['value']);
        } else {
          settle(
            null,
            error: GitOperationError(
              (message['error'] as String?) ?? '未知 git 错误',
              message['detail'] as String?,
            ),
          );
        }
        return;
      }
      // `onExit` reports null. Reaching here without a result means the worker
      // died before answering (killed by us, or crashed natively).
      settle(
        null,
        error: _cancelRequested
            ? GitJobCancelled()
            : GitOperationError('git 后台任务意外结束（可能是内存不足）。'),
      );
    });

    final errorSub = errors.listen((message) {
      final text = message is List && message.isNotEmpty
          ? message.first.toString()
          : message.toString();
      settle(null, error: GitOperationError('git 后台任务出错：$text'));
    });

    try {
      _active = await Isolate.spawn(
        gitJobMain,
        <Object?>[replies.sendPort, job],
        onError: errors.sendPort,
        onExit: replies.sendPort,
        debugName: 'tolaria-git-${job['op']}',
      );

      return await done.future.timeout(
        timeout,
        onTimeout: () => throw _GitJobTimeout(
          '操作超时（${timeout.inMinutes} 分钟无响应）。请检查网络后重试。',
        ),
      );
    } finally {
      // Intentionally NOT killing the isolate: see [cancel]. Closing the ports
      // below means anything it still sends is dropped, and libgit2 will return
      // on its own (it has its own socket timeouts). A killed isolate mid-FFI
      // is what crashed the app on "取消".
      _active = null;
      await replySub.cancel();
      await errorSub.cancel();
      replies.close();
      errors.close();
    }
  }
}
