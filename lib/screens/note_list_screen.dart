import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../models/note.dart';
import '../models/note_filter.dart';
import '../providers/vault_provider.dart';
import '../route_observer.dart';
import '../widgets/color_dot.dart';
import '../widgets/note_actions.dart';
import '../widgets/sheet_insets.dart';
import 'ai_chat_screen.dart';
import 'note_editor_screen.dart';
import 'note_view_screen.dart';

class NoteListScreen extends ConsumerStatefulWidget {
  const NoteListScreen({super.key});

  @override
  ConsumerState<NoteListScreen> createState() => _NoteListScreenState();
}

class _NoteListScreenState extends ConsumerState<NoteListScreen>
    with SnackbarDismissOnNavigate {
  final _search = TextEditingController();
  final _scaffoldKey = GlobalKey<ScaffoldState>();
  bool _searching = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      ref.read(vaultProvider.notifier).refresh();
    });
  }

  @override
  void dispose() {
    _search.dispose();
    super.dispose();
  }

  void _snack(String text) {
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(text)));
  }

  @override
  Widget build(BuildContext context) {
    final state = ref.watch(vaultProvider);

    ref.listen<VaultState>(vaultProvider, (previous, next) {
      if (next.error != null && next.error != previous?.error) {
        _snack(next.error!);
      } else if (next.message != null && next.message != previous?.message) {
        _snack(next.message!);
      }
    });

    final query = _search.text.trim().toLowerCase();
    // Sidebar filter first, free-text search on top of it.
    final scoped = state.visibleNotes;
    final notes = query.isEmpty
        ? scoped
        : scoped
            .where((n) =>
                n.title.toLowerCase().contains(query) ||
                n.relativePath.toLowerCase().contains(query))
            .toList();

    return Scaffold(
      key: _scaffoldKey,
      drawer: _VaultDrawer(
        state: state,
        onSelect: (filter) {
          ref.read(vaultProvider.notifier).setFilter(filter);
          Navigator.of(context).pop();
        },
      ),
      appBar: AppBar(
        title: _searching
            ? TextField(
                controller: _search,
                autofocus: true,
                decoration: const InputDecoration(
                  hintText: '搜索标题 / 路径',
                  border: InputBorder.none,
                ),
                onChanged: (_) => setState(() {}),
              )
            // Tapping the title opens the sidebar, the same gesture the desktop
            // app uses to reach Inbox / All notes / Views / Types.
            : InkWell(
                onTap: () => _scaffoldKey.currentState?.openDrawer(),
                borderRadius: BorderRadius.circular(8),
                child: Padding(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 6, vertical: 6),
                  child: Text(
                    state.filter.label == '全部笔记'
                        ? 'Tolaria'
                        : state.filter.label,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: Theme.of(context).textTheme.titleLarge,
                  ),
                ),
              ),
        titleSpacing: 0,
        actions: [
          IconButton(
            tooltip: '搜索',
            icon: Icon(_searching ? Icons.close : Icons.search),
            onPressed: () {
              setState(() {
                _searching = !_searching;
                if (!_searching) _search.clear();
              });
            },
          ),
          IconButton(
            tooltip: '拉取远程更新',
            icon: const Icon(Icons.download_rounded),
            onPressed: state.busy
                ? null
                : () => ref.read(vaultProvider.notifier).pullNow(),
          ),
          IconButton(
            tooltip: '提交并推送',
            icon: const Icon(Icons.sync_rounded),
            onPressed: state.busy
                ? null
                : () => ref.read(vaultProvider.notifier).syncNow(),
          ),
          IconButton(
            tooltip: '设置',
            icon: const Icon(Icons.settings_outlined),
            onPressed: () => Navigator.of(context).pushNamed('/settings'),
          ),
        ],
      ),
      floatingActionButton: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.end,
        children: [
          // The list screen has no single note in focus, so the assistant gets
          // the vault outline only. Both buttons need their own hero tag or the
          // FAB transition between routes throws.
          FloatingActionButton.small(
            heroTag: 'ai-fab',
            tooltip: '问 AI',
            onPressed: () => Navigator.of(context).push(
              MaterialPageRoute(builder: (_) => const AiChatScreen()),
            ),
            child: const Icon(Icons.auto_awesome_outlined),
          ),
          const SizedBox(height: 12),
          FloatingActionButton.extended(
            heroTag: 'new-note-fab',
            onPressed: _addNote,
            icon: const Icon(Icons.add),
            label: const Text('新建'),
          ),
        ],
      ),
      body: Stack(
        children: [
          RefreshIndicator(
            onRefresh: () => ref.read(vaultProvider.notifier).refresh(),
            child: notes.isEmpty
                ? _EmptyState(
                    query: query,
                    filterLabel: state.filter.label,
                  )
                : ListView.separated(
                    padding: const EdgeInsets.fromLTRB(8, 8, 8, 96),
                    itemCount: notes.length,
                    separatorBuilder: (_, __) =>
                        const Divider(height: 1, indent: 16, endIndent: 16),
                    itemBuilder: (context, index) {
                      final note = notes[index];
                      return ListTile(
                        title: Text(
                          note.title,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(fontWeight: FontWeight.w600),
                        ),
                        subtitle: Text(
                          note.noteType == null
                              ? note.relativePath
                              : '${note.noteType} · ${note.relativePath}',
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                        trailing: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            // Archived notes stay visible in "全部笔记" (that is
                            // what "all" means), so the row has to say so.
                            if (note.isArchived)
                              Padding(
                                padding: const EdgeInsets.only(right: 6),
                                child: Icon(
                                  Icons.archive_outlined,
                                  size: 16,
                                  color: Theme.of(context).colorScheme.outline,
                                ),
                              ),
                            Text(
                              _formatDate(note.modified),
                              style: Theme.of(context).textTheme.bodySmall,
                            ),
                          ],
                        ),
                        onTap: () => Navigator.of(context).push(
                          MaterialPageRoute(
                            builder: (_) => NoteViewScreen(note: note),
                          ),
                        ),
                        // Mobile equivalent of the desktop right-click menu.
                        onLongPress: () => _showNoteMenu(note),
                      );
                    },
                  ),
          ),
          if (state.busy)
            Positioned.fill(
              child: ColoredBox(
                color: Colors.black26,
                child: Center(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      const CircularProgressIndicator(),
                      const SizedBox(height: 12),
                      Text(
                        state.message ?? '处理中…',
                        style: const TextStyle(color: Colors.white),
                      ),
                    ],
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }

  String _formatDate(DateTime? date) {
    if (date == null) return '';
    String two(int v) => v.toString().padLeft(2, '0');
    return '${two(date.month)}-${two(date.day)} ${two(date.hour)}:${two(date.minute)}';
  }

  /// Long-press menu — the touch analogue of Tolaria's desktop right-click
  /// menu on a note row.
  Future<void> _showNoteMenu(Note note) async {
    final scheme = Theme.of(context).colorScheme;
    final category = note.noteType;
    final action = await showModalBottomSheet<String>(
      context: context,
      showDragHandle: true,
      // The default sheet is capped at 9/16 of the screen. With five rows plus
      // the gap under the last one the column overflows that cap and the
      // delete row gets clipped back onto the navigation band, so lift the cap.
      isScrollControlled: true,
      // The sheet is pinned to the bottom of the screen, so without this the
      // delete row sits on the navigation / back-swipe band: one stray tap on
      // the way to "back" removes the note.
      builder: (ctx) => Padding(
        padding: sheetBottomInset(ctx),
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
            ListTile(
              leading: const Icon(Icons.edit_outlined),
              title: const Text('重命名'),
              subtitle: Text(note.relativePath, maxLines: 1),
              onTap: () => Navigator.pop(ctx, 'rename'),
            ),
            ListTile(
              leading: const Icon(Icons.sell_outlined),
              title: const Text('移动到分类'),
              subtitle: Text(
                category == null ? '当前未分类（收件箱）' : '当前：$category',
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
              onTap: () => Navigator.pop(ctx, 'category'),
            ),
            ListTile(
              leading: Icon(
                note.isArchived ? Icons.unarchive_outlined : Icons.archive_outlined,
              ),
              title: Text(note.isArchived ? '取消归档' : '归档'),
              subtitle: Text(
                note.isArchived ? '移出「归档」，回到全部笔记' : '移进侧边栏的「归档」',
              ),
              onTap: () => Navigator.pop(ctx, 'archive'),
            ),
            ListTile(
              leading: const Icon(Icons.content_copy_rounded),
              title: const Text('复制文件路径'),
              onTap: () => Navigator.pop(ctx, 'copy'),
            ),
            const Divider(height: 1),
            ListTile(
              leading: Icon(Icons.delete_outline, color: scheme.error),
              title: Text('删除', style: TextStyle(color: scheme.error)),
              onTap: () => Navigator.pop(ctx, 'delete'),
            ),
          ],
          ),
        ),
      ),
    );
    if (!mounted || action == null) return;

    switch (action) {
      case 'copy':
        await Clipboard.setData(ClipboardData(text: note.relativePath));
        if (mounted) _snack('已复制：${note.relativePath}');
      case 'rename':
        await _renameNote(note);
      case 'category':
        await moveToCategory(context, ref, note);
      case 'archive':
        await toggleArchive(context, ref, note);
      case 'delete':
        await _deleteNote(note);
    }
  }

  Future<void> _renameNote(Note note) async {
    final controller = TextEditingController(text: note.title);
    final newTitle = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('重命名'),
        content: TextField(
          controller: controller,
          autofocus: true,
          decoration: const InputDecoration(
            labelText: '标题',
            helperText: '文件名会跟着改；其它笔记里指向旧名字的链接不会自动修改',
          ),
          onSubmitted: (value) => Navigator.pop(ctx, value.trim()),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('取消')),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, controller.text.trim()),
            child: const Text('确定'),
          ),
        ],
      ),
    );
    controller.dispose();
    if (newTitle == null || newTitle.isEmpty || newTitle == note.title) return;
    try {
      await ref.read(vaultProvider.notifier).renameNote(note.relativePath, newTitle);
      if (mounted) _snack('已重命名为「$newTitle」');
    } catch (e) {
      if (mounted) _snack('重命名失败：$e');
    }
  }

  Future<void> _deleteNote(Note note) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('删除笔记？'),
        content: Text(
          '将删除文件 ${note.relativePath}。\n删除后可通过 Git 历史找回（需在桌面端操作）。',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('取消'),
          ),
          FilledButton(
            style: FilledButton.styleFrom(
              backgroundColor: Theme.of(ctx).colorScheme.error,
            ),
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('删除'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    await ref.read(vaultProvider.notifier).deleteNote(note.relativePath);
    if (mounted) _snack('已删除 ${note.fileName}');
  }

  Future<void> _addNote() async {
    final controller = TextEditingController();
    final title = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('新建笔记'),
        content: TextField(
          controller: controller,
          autofocus: true,
          decoration: const InputDecoration(labelText: '标题'),
          onSubmitted: (value) => Navigator.pop(ctx, value.trim()),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, controller.text.trim()),
            child: const Text('创建'),
          ),
        ],
      ),
    );
    controller.dispose();
    if (title == null || title.isEmpty) return;
    final note = await ref.read(vaultProvider.notifier).addNote(title);
    if (!mounted) return;
    await Navigator.of(context).push(
      MaterialPageRoute(builder: (_) => NoteEditorScreen(note: note)),
    );
  }
}

class _EmptyState extends StatelessWidget {
  final String query;
  final String filterLabel;

  const _EmptyState({required this.query, required this.filterLabel});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return ListView(
      children: [
        SizedBox(height: MediaQuery.of(context).size.height * 0.2),
        Icon(Icons.menu_book_outlined,
            size: 64, color: theme.colorScheme.outline),
        const SizedBox(height: 16),
        Text(
          query.isNotEmpty
              ? '没有匹配「$query」的笔记'
              : filterLabel == '全部笔记'
                  ? '知识库还没有笔记'
                  : '「$filterLabel」里还没有笔记',
          textAlign: TextAlign.center,
          style: theme.textTheme.titleMedium,
        ),
        const SizedBox(height: 8),
        Text(
          filterLabel == '全部笔记'
              ? '点击右下角「新建」开始写作，或从桌面端推送后在顶部下拉拉取。'
              : '点左上角标题切换到「全部笔记」看看别的分组。',
          textAlign: TextAlign.center,
          style: theme.textTheme.bodySmall
              ?.copyWith(color: theme.colorScheme.outline),
        ),
      ],
    );
  }
}

/// The phone equivalent of Tolaria's desktop sidebar: Inbox / All notes /
/// Archive, then the vault's own saved views (`views/*.yml`) and the note types
/// found in frontmatter.
class _VaultDrawer extends StatelessWidget {
  const _VaultDrawer({required this.state, required this.onSelect});

  final VaultState state;
  final ValueChanged<NoteFilter> onSelect;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final index = state.index;
    final selected = state.filter;

    Widget sectionHeader(String text, IconData icon) => Padding(
          padding: const EdgeInsets.fromLTRB(16, 16, 16, 4),
          child: Row(
            children: [
              Icon(icon, size: 14, color: theme.colorScheme.outline),
              const SizedBox(width: 6),
              Text(
                text,
                style: theme.textTheme.labelMedium?.copyWith(
                  color: theme.colorScheme.outline,
                  letterSpacing: 0.6,
                ),
              ),
            ],
          ),
        );

    Widget entry({
      required Widget leading,
      required String label,
      required int count,
      required NoteFilter filter,
    }) {
      return ListTile(
        dense: true,
        leading: leading,
        title: Text(label, maxLines: 1, overflow: TextOverflow.ellipsis),
        trailing: count == 0
            ? null
            : Text('$count', style: theme.textTheme.bodySmall),
        selected: selected == filter,
        onTap: () => onSelect(filter),
      );
    }

    return Drawer(
      child: SafeArea(
        child: ListView(
          padding: EdgeInsets.zero,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 20, 16, 12),
              child: Row(
                children: [
                  Icon(Icons.menu_book_rounded,
                      color: theme.colorScheme.primary),
                  const SizedBox(width: 10),
                  Text('Tolaria',
                      style: theme.textTheme.titleLarge
                          ?.copyWith(fontWeight: FontWeight.w700)),
                ],
              ),
            ),
            entry(
              leading: const Icon(Icons.inbox_rounded),
              label: '收件箱',
              count: state.countFor(const NoteFilter.inbox()),
              filter: const NoteFilter.inbox(),
            ),
            entry(
              leading: const Icon(Icons.notes_rounded),
              label: '全部笔记',
              count: state.notes.length,
              filter: const NoteFilter.all(),
            ),
            entry(
              leading: const Icon(Icons.archive_outlined),
              label: '归档',
              count: state.countFor(const NoteFilter.archive()),
              filter: const NoteFilter.archive(),
            ),
            if (index.views.isNotEmpty) ...[
              const Divider(height: 16),
              sectionHeader('视图', Icons.filter_list_rounded),
              for (final view in index.views)
                entry(
                  leading: ColorDot(color: view.color, icon: Icons.label_outline),
                  label: view.name,
                  count: state.countFor(NoteFilter.view(view)),
                  filter: NoteFilter.view(view),
                ),
            ],
            if (index.sortedTypes.isNotEmpty) ...[
              const Divider(height: 16),
              sectionHeader('类型', Icons.sell_outlined),
              for (final type in index.sortedTypes)
                entry(
                  leading:
                      ColorDot(color: type.color, icon: Icons.sell_outlined),
                  label: type.label,
                  count: type.count,
                  filter: NoteFilter.type(type.value),
                ),
            ],
            const SizedBox(height: 24),
          ],
        ),
      ),
    );
  }
}
