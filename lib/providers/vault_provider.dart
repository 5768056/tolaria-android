import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import '../models/note.dart';
import '../models/note_filter.dart';
import '../models/vault_config.dart';
import '../services/credentials_store.dart';
import '../services/git_job_runner.dart';
import '../services/git_service.dart';
import '../services/settings_service.dart';
import '../services/vault_index.dart';
import '../services/vault_service.dart';

class VaultState {
  final VaultConfig? config;
  final List<Note> notes;
  final bool loading;
  final bool busy;
  final String? error;
  final String? message;
  final int progress;

  /// Sidebar structure: saved views + type counts.
  final VaultIndex index;

  /// What the list is filtered to.
  final NoteFilter filter;

  const VaultState({
    this.config,
    this.notes = const [],
    this.loading = false,
    this.busy = false,
    this.error,
    this.message,
    this.progress = 0,
    this.index = VaultIndex.empty,
    this.filter = const NoteFilter.all(),
  });

  String? get vaultPath => config?.vaultPath;

  /// Notes matching [filter] — what the list screen renders.
  List<Note> get visibleNotes => filter.apply(notes);

  int countFor(NoteFilter f) => f.apply(notes).length;

  static const Object _unset = Object();

  VaultState copyWith({
    VaultConfig? config,
    List<Note>? notes,
    bool? loading,
    bool? busy,
    Object? error = _unset,
    Object? message = _unset,
    int? progress,
    VaultIndex? index,
    NoteFilter? filter,
  }) {
    return VaultState(
      config: config ?? this.config,
      notes: notes ?? this.notes,
      loading: loading ?? this.loading,
      busy: busy ?? this.busy,
      error: identical(error, _unset) ? this.error : error as String?,
      message: identical(message, _unset) ? this.message : message as String?,
      progress: progress ?? this.progress,
      index: index ?? this.index,
      filter: filter ?? this.filter,
    );
  }
}

class VaultNotifier extends StateNotifier<VaultState> {
  final SettingsService _settings;
  GitCredentials? _credentials;

  /// Sidebar dot colours for categories created from the phone. Tolaria's
  /// desktop picker offers named swatches, but vaults authored elsewhere (this
  /// one included) store hex, which is what the phone's sidebar can render.
  static const _viewPalette = [
    '#E8743B',
    '#2FA36B',
    '#D4A72C',
    '#2F6FD0',
    '#8B5CF0',
    '#5B6B7B',
    '#C24E7D',
    '#3AA6A6',
  ];

  VaultNotifier(this._settings) : super(const VaultState()) {
    _restore();
  }

  GitCredentials? get credentials => _credentials;

  Future<void> _restore() async {
    final config = await _settings.loadConfig();
    if (config == null) {
      // A staging directory left behind means a previous clone was interrupted
      // (app killed, crash, cancelled mid-transfer). Say so, otherwise the user
      // just sees an empty form and assumes nothing happened last time.
      await _warnIfInterruptedClone();
      return;
    }
    try {
      final notes = VaultService(config.vaultPath).loadNotes();
      state = state.copyWith(
        config: config,
        notes: notes,
        index: VaultIndex.load(config.vaultPath, notes),
      );
      // Git credentials live in the keystore (the user asked for them to
      // survive restarts). Loading them here means sync works right after a
      // cold start, without a trip through settings first.
      final stored = await CredentialsStore().load();
      if (stored != null && mounted) setCredentials(stored);
    } catch (e) {
      state = state.copyWith(config: config, error: '读取知识库失败：$e');
    }
  }

  void setCredentials(GitCredentials credentials) {
    _credentials = credentials;
  }

  GitService _git(String path) {
    final git = GitService.create(path);
    git.useCredentials(_credentials);
    git.onProgress = (progress) {
      if (!mounted) return;
      final bytes = progress.receivedBytes > 0
          ? '（已接收 ${progress.receivedLabel}）'
          : '';
      state = state.copyWith(
        progress: progress.percent,
        // libgit2 counts objects, so the percentage can hold still for a long
        // time on a fat pack. Showing the byte counter alongside it is what
        // tells the user "still working" instead of "frozen".
        message: progress.percent > 0
            ? '正在传输… ${progress.percent}%$bytes'
            : '正在传输…$bytes',
      );
    };
    return git;
  }

  /// Aborts an in-flight network operation (clone / push / pull).
  ///
  /// The UI is released immediately — waiting for libgit2 to unwind would look
  /// exactly like the freeze we are trying to avoid. The worker keeps running
  /// for a few more seconds; its result is thrown away in [cloneVault].
  void cancelOperation() {
    GitJobRunner.cancel();
    if (!state.busy) return;
    state = state.copyWith(busy: false, progress: 0, message: '已取消');
  }

  Future<void> refresh() async {
    final config = state.config;
    if (config == null) return;
    state = state.copyWith(loading: true, error: null);
    try {
      final notes = VaultService(config.vaultPath).loadNotes();
      state = state.copyWith(
        notes: notes,
        index: VaultIndex.load(config.vaultPath, notes),
        loading: false,
      );
    } catch (e) {
      state = state.copyWith(loading: false, error: '读取知识库失败：$e');
    }
  }

  Future<void> cloneVault({
    required String url,
    required String branch,
    required String authorName,
    required String authorEmail,
    GitCredentials? credentials,
  }) async {
    state = state.copyWith(
      busy: true,
      error: null,
      message: '正在连接远程仓库…',
      progress: 0,
    );
    Directory? staging;
    try {
      // Clone into a staging directory first. Wiping the live vault up front —
      // as an earlier version did — loses every note if the clone then fails.
      staging = await _stagingDir();
      final git = _git(staging.path);
      final outcome = await git.clone(
        url,
        credentials: credentials,
        branch: (branch.trim().isEmpty) ? null : branch.trim(),
      );

      final vaultDir = await _promoteStaging(staging);
      staging = null;

      final config = VaultConfig(
        vaultPath: vaultDir.path,
        remoteUrl: url,
        // Use the branch that actually got checked out: a vault on `master`
        // must not start pushing to a brand-new `main`.
        branch: outcome.branch,
        authorName: authorName,
        authorEmail: authorEmail,
      );
      await _settings.saveConfig(config);
      _credentials = credentials;
      // The clone landed; the remembered form values have served their purpose.
      await _settings.clearSetupDraft();
      final notes = VaultService(vaultDir.path).loadNotes();
      state = state.copyWith(
        config: config,
        notes: notes,
        index: VaultIndex.load(vaultDir.path, notes),
        filter: const NoteFilter.all(),
        busy: false,
        progress: 100,
        message: '克隆完成，共 ${notes.length} 条笔记（分支 ${config.branch}）',
      );
    } on GitJobCancelled {
      state = state.copyWith(busy: false, message: '已取消克隆');
    } catch (e) {
      state = state.copyWith(busy: false, error: '克隆失败：${_describe(e)}');
    } finally {
      _removeQuietly(staging);
    }
  }

  Future<void> createEmptyVault({
    required String url,
    required String branch,
    required String authorName,
    required String authorEmail,
  }) async {
    state = state.copyWith(busy: true, error: null, message: '正在初始化仓库…');
    Directory? staging;
    try {
      staging = await _stagingDir();
      final git = _git(staging.path);
      await git.init();
      if (url.trim().isNotEmpty) {
        await git.configureRemote(url.trim());
      }

      final vaultDir = await _promoteStaging(staging);
      staging = null;

      final config = VaultConfig(
        vaultPath: vaultDir.path,
        remoteUrl: url.trim(),
        branch: (branch.trim().isEmpty) ? 'main' : branch.trim(),
        authorName: authorName,
        authorEmail: authorEmail,
      );
      await _settings.saveConfig(config);
      await _settings.clearSetupDraft();
      VaultService(vaultDir.path).createNote('欢迎使用 Tolaria');
      final notes = VaultService(vaultDir.path).loadNotes();
      state = state.copyWith(
        config: config,
        notes: notes,
        index: VaultIndex.load(vaultDir.path, notes),
        filter: const NoteFilter.all(),
        busy: false,
        message: '已创建空知识库',
      );
    } catch (e) {
      state = state.copyWith(busy: false, error: '初始化失败：${_describe(e)}');
    } finally {
      _removeQuietly(staging);
    }
  }

  Future<Note> addNote(String title) async {
    final config = state.config;
    if (config == null) throw StateError('知识库未打开');
    final note = VaultService(config.vaultPath).createNote(title);
    await refresh();
    return note;
  }

  Future<void> saveNote(Note note) async {
    final config = state.config;
    if (config == null) return;
    VaultService(config.vaultPath).saveNote(note);
    await refresh();
  }

  Future<void> deleteNote(String relativePath) async {
    final config = state.config;
    if (config == null) return;
    VaultService(config.vaultPath).deleteNote(relativePath);
    await refresh();
  }

  Future<Note> renameNote(String relativePath, String newTitle) async {
    final config = state.config;
    if (config == null) throw StateError('知识库未打开');
    final note = VaultService(config.vaultPath).renameNote(relativePath, newTitle);
    await refresh();
    return note;
  }

  /// Archive (`true`) or restore (`false`). Throws on failure so the caller can
  /// show the error next to the action that failed.
  Future<void> setArchived(Note note, bool archived) async {
    final config = state.config;
    if (config == null) throw StateError('知识库未打开');
    VaultService(config.vaultPath).setArchived(note.relativePath, archived);
    await refresh();
  }

  /// Move [note] into the category [type], or out of every category when null.
  Future<void> setType(Note note, String? type) async {
    final config = state.config;
    if (config == null) throw StateError('知识库未打开');
    VaultService(config.vaultPath).setType(note.relativePath, type);
    await refresh();
  }

  /// Create a new category: a `views/<name>.yml` filter plus, implicitly, the
  /// `type:` value notes put on themselves. Returns the category name so the
  /// caller can immediately file the note into it.
  Future<String> createCategory(String name) async {
    final config = state.config;
    if (config == null) throw StateError('知识库未打开');
    final label = name.trim();
    if (label.isEmpty) throw ArgumentError('分类名不能为空');
    final nextOrder = state.index.views.fold<int>(
          0,
          (max, view) => view.order > max ? view.order : max,
        ) +
        1;
    VaultService(config.vaultPath).createCategoryView(
      name: label,
      order: nextOrder,
      // Cycle through the palette the vault already uses so a new dot does not
      // land on the same colour as its neighbour.
      color: _viewPalette[state.index.views.length % _viewPalette.length],
    );
    await refresh();
    return label;
  }

  Future<void> syncNow() async {
    final config = state.config;
    if (config == null) return;
    state = state.copyWith(
      busy: true,
      error: null,
      message: '正在提交…',
      progress: 0,
    );
    try {
      final git = _git(config.vaultPath);
      final stamp = DateTime.now().toIso8601String();
      final committed = await git.commitAll(
        'Tolaria 移动端同步 $stamp',
        authorName: config.authorName,
        authorEmail: config.authorEmail,
      );

      if (config.remoteUrl.trim().isEmpty) {
        state = state.copyWith(
          busy: false,
          message: committed ? '已提交到本地仓库（未配置远程）' : '没有需要提交的改动',
        );
        return;
      }

      state = state.copyWith(message: '正在推送…', progress: 0);
      final branch = await git.currentBranch() ?? config.branch;
      await git.push(branch: branch, credentials: _credentials);
      state = state.copyWith(
        busy: false,
        progress: 100,
        message: committed ? '已提交并推送到 $branch' : '没有新改动，已检查远程分支 $branch',
      );
    } on GitJobCancelled {
      state = state.copyWith(busy: false, message: '已取消同步');
    } catch (e) {
      state = state.copyWith(busy: false, error: '同步失败：${_describe(e)}');
    }
  }

  Future<void> pullNow() async {
    final config = state.config;
    if (config == null) return;
    state = state.copyWith(
      busy: true,
      error: null,
      // Split from "正在拉取…" so the user can tell "checking" apart from
      // "downloading". Most pulls turn out to need no transfer at all, and a
      // message that never changed made even those look busy.
      message: '正在检查远程…',
      progress: 0,
    );
    final watch = Stopwatch()..start();
    try {
      final git = _git(config.vaultPath);
      final outcome = await git.pull(
        branch: config.branch,
        credentials: _credentials,
      );
      watch.stop();

      if (outcome.status == PullStatus.upToDate) {
        // Nothing crossed the wire, so the files on disk did not change either:
        // re-reading every note would be pure cost on the common path.
        // Showing the elapsed time is deliberate — "已是最新（0.4 秒）" is the
        // only way the user can tell a fast pull apart from a pull that
        // silently did nothing.
        state = state.copyWith(
          busy: false,
          progress: 100,
          message: '已是最新（${_elapsedLabel(watch)}）',
        );
        return;
      }

      final notes = VaultService(config.vaultPath).loadNotes();
      if (outcome.status == PullStatus.conflict) {
        // Still reload: the conflict markers landed in the working tree and the
        // user has to be able to see them to resolve anything.
        state = state.copyWith(
          notes: notes,
          index: VaultIndex.load(config.vaultPath, notes),
          busy: false,
          error: '拉取产生冲突，请打开带冲突标记的文件手动解决后再同步。',
        );
        return;
      }

      final label = outcome.commits > 0
          ? '已拉取 ${outcome.commits} 个新提交（${_elapsedLabel(watch)}）'
          : '拉取完成（${_elapsedLabel(watch)}）';
      state = state.copyWith(
        notes: notes,
        index: VaultIndex.load(config.vaultPath, notes),
        busy: false,
        progress: 100,
        message: label,
      );
    } on GitJobCancelled {
      state = state.copyWith(busy: false, message: '已取消拉取');
    } catch (e) {
      state = state.copyWith(busy: false, error: '拉取失败：${_describe(e)}');
    }
  }

  String _elapsedLabel(Stopwatch watch) {
    final ms = watch.elapsedMilliseconds;
    if (ms < 1000) return '${ms}ms';
    return '${(ms / 1000).toStringAsFixed(1)} 秒';
  }

  /// Switches the sidebar selection. Purely in-memory — a filter is a view of
  /// the vault, never a change to it.
  void setFilter(NoteFilter filter) {
    if (filter == state.filter) return;
    state = state.copyWith(filter: filter);
  }

  Future<void> updateConfig(VaultConfig config) async {
    await _settings.saveConfig(config);
    state = state.copyWith(config: config, message: '设置已保存');
  }

  Future<void> resetVault() async {
    await _settings.clearVault();
    _credentials = null;
    state = const VaultState();
  }

  // -------------------------------------------------------------------------
  // Helpers
  // -------------------------------------------------------------------------

  /// Empty scratch directory next to the real vault, same filesystem so the
  /// final `rename` is atomic-ish and cheap.
  Future<Directory> _stagingDir() async {
    final docs = await getApplicationDocumentsDirectory();
    final staging = Directory(p.join(docs.path, '.tolaria_vault_incoming'));
    if (staging.existsSync()) staging.deleteSync(recursive: true);
    staging.createSync(recursive: true);
    return staging;
  }

  /// If a previous clone was interrupted, its staging directory still holds
  /// partial content. Surfacing that on the first-run screen explains why the
  /// form looks untouched even though the user filled it in last time.
  Future<void> _warnIfInterruptedClone() async {
    try {
      final docs = await getApplicationDocumentsDirectory();
      final staging = Directory(p.join(docs.path, '.tolaria_vault_incoming'));
      if (!staging.existsSync()) return;
      final hasContent = staging.listSync().isNotEmpty;
      if (hasContent && mounted) {
        state = state.copyWith(
          message: '检测到上次未完成的克隆（可能被中断）。重新填写并点「克隆」即可继续。',
        );
      }
    } catch (_) {
      // Never let a diagnostic break startup.
    }
  }

  /// Moves the freshly prepared staging directory into place, keeping the
  /// previous vault until the swap succeeded.
  Future<Directory> _promoteStaging(Directory staging) async {
    final docs = await getApplicationDocumentsDirectory();
    final target = Directory(p.join(docs.path, 'tolaria_vault'));
    final backup = Directory(p.join(docs.path, '.tolaria_vault_previous'));

    if (backup.existsSync()) backup.deleteSync(recursive: true);
    final hadPrevious = target.existsSync();
    if (hadPrevious) target.renameSync(backup.path);

    try {
      staging.renameSync(target.path);
    } catch (e) {
      // Restore the previous vault rather than leaving the user with nothing.
      if (hadPrevious && !target.existsSync() && backup.existsSync()) {
        backup.renameSync(target.path);
      }
      rethrow;
    }

    if (backup.existsSync()) backup.deleteSync(recursive: true);
    return target;
  }

  void _removeQuietly(Directory? dir) {
    if (dir == null) return;
    try {
      if (dir.existsSync()) dir.deleteSync(recursive: true);
    } catch (_) {
      // Best effort: a leftover staging dir is harmless and gets reused next
      // time because `_stagingDir` wipes it first.
    }
  }

  String _describe(Object error) {
    if (error is GitOperationError) return error.message;
    return error.toString();
  }
}

final settingsServiceProvider = Provider<SettingsService>((ref) {
  return SettingsService();
});

final vaultProvider = StateNotifierProvider<VaultNotifier, VaultState>((ref) {
  return VaultNotifier(ref.watch(settingsServiceProvider));
});
