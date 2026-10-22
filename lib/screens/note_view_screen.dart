import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../models/note.dart';
import '../providers/vault_provider.dart';
import '../services/vault_service.dart';
import '../widgets/note_actions.dart';
import '../widgets/note_markdown.dart';
import 'ai_chat_screen.dart';
import 'note_editor_screen.dart';

class NoteViewScreen extends ConsumerWidget {
  final Note note;

  const NoteViewScreen({super.key, required this.note});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final state = ref.watch(vaultProvider);
    Note current = note;
    for (final n in state.notes) {
      if (n.relativePath == note.relativePath) {
        current = n;
        break;
      }
    }
    final theme = Theme.of(context);

    // Screen-scoped messenger: the undo prompt from the overflow menu dies
    // with this screen instead of following the user back to the list on the
    // app-level messenger, where it would sit there looking stuck.
    return ScaffoldMessenger(
      child: Scaffold(
        appBar: AppBar(
          title: Text(current.title, overflow: TextOverflow.ellipsis),
          actions: [
            // Opens the assistant with this note attached as context — the phone
            // equivalent of asking Tolaria's desktop AI panel about the open note.
            IconButton(
              tooltip: '问 AI',
              icon: const Icon(Icons.auto_awesome_outlined),
              onPressed: () {
                Navigator.of(context).push(
                MaterialPageRoute(
                  builder: (_) => AiChatScreen(activeNote: current),
                ),
              );
            },
          ),
          IconButton(
            tooltip: '编辑',
            icon: const Icon(Icons.edit_outlined),
            onPressed: () {
              Navigator.of(context).push(
                MaterialPageRoute(
                  builder: (_) => NoteEditorScreen(note: current),
                ),
              );
            },
          ),
          // Archive / categorise / delete live behind one menu: delete used to
          // be a plain icon sitting next to "edit", which is one mis-tap away
          // from losing a note.
          PopupMenuButton<String>(
            tooltip: '更多',
            onSelected: (value) => _onMenuSelected(context, ref, current, value),
            itemBuilder: (ctx) => [
              _menuItem(
                value: 'category',
                icon: Icons.sell_outlined,
                label: '移动到分类',
              ),
              _menuItem(
                value: 'archive',
                icon: current.isArchived
                    ? Icons.unarchive_outlined
                    : Icons.archive_outlined,
                label: current.isArchived ? '取消归档' : '归档',
              ),
              _menuItem(
                value: 'copy',
                icon: Icons.content_copy_rounded,
                label: '复制文件路径',
              ),
              const PopupMenuDivider(),
              _menuItem(
                value: 'delete',
                icon: Icons.delete_outline,
                label: '删除',
                color: Theme.of(ctx).colorScheme.error,
              ),
            ],
          ),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(20, 16, 20, 40),
        children: [
          Text(
            current.relativePath,
            style: theme.textTheme.bodySmall
                ?.copyWith(color: theme.colorScheme.outline),
          ),
          if (current.isArchived || current.noteType != null) ...[
            const SizedBox(height: 8),
            Wrap(
              spacing: 8,
              runSpacing: 6,
              children: [
                if (current.noteType != null)
                  _Badge(
                    icon: Icons.sell_outlined,
                    label: current.noteType!,
                    color: theme.colorScheme.primary,
                  ),
                if (current.isArchived)
                  _Badge(
                    icon: Icons.archive_outlined,
                    label: '已归档',
                    color: theme.colorScheme.outline,
                  ),
              ],
            ),
          ],
          const SizedBox(height: 16),
          NoteMarkdown(
            body: current.body,
            onWikilinkTap: (target) => _openWikilink(context, ref, target),
          ),
        ],
      ),
      ),
    );
  }

  static PopupMenuItem<String> _menuItem({
    required String value,
    required IconData icon,
    required String label,
    Color? color,
  }) {
    return PopupMenuItem<String>(
      value: value,
      child: Row(
        children: [
          Icon(icon, size: 20, color: color),
          const SizedBox(width: 12),
          Text(label, style: TextStyle(color: color)),
        ],
      ),
    );
  }

  Future<void> _onMenuSelected(
    BuildContext context,
    WidgetRef ref,
    Note current,
    String value,
  ) async {
    switch (value) {
      case 'category':
        await moveToCategory(context, ref, current);
      case 'archive':
        await toggleArchive(context, ref, current);
      case 'copy':
        await Clipboard.setData(ClipboardData(text: current.relativePath));
        if (context.mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text('已复制：${current.relativePath}')),
          );
        }
      case 'delete':
        if (context.mounted) await _confirmDelete(context, ref, current);
    }
  }

  void _openWikilink(BuildContext context, WidgetRef ref, String target) {
    final config = ref.read(vaultProvider).config;
    if (config == null) return;
    final notes = ref.read(vaultProvider).notes;
    final resolved =
        VaultService(config.vaultPath).resolveWikilink(target, notes);
    if (resolved == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('未找到笔记：$target')),
      );
      return;
    }
    Navigator.of(context).push(
      MaterialPageRoute(builder: (_) => NoteViewScreen(note: resolved)),
    );
  }

  Future<void> _confirmDelete(
    BuildContext context,
    WidgetRef ref,
    Note current,
  ) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('删除笔记'),
        content: Text('确定删除「${current.title}」吗？此操作会删除磁盘文件。'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('删除'),
          ),
        ],
      ),
    );
    if (ok == true && context.mounted) {
      await ref.read(vaultProvider.notifier).deleteNote(current.relativePath);
      if (context.mounted) Navigator.of(context).pop();
    }
  }
}

/// Small rounded label for the note's category / archived state.
class _Badge extends StatelessWidget {
  const _Badge({
    required this.icon,
    required this.label,
    required this.color,
  });

  final IconData icon;
  final String label;
  final Color color;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.10),
        borderRadius: BorderRadius.circular(999),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 14, color: color),
          const SizedBox(width: 4),
          Text(
            label,
            style: Theme.of(context)
                .textTheme
                .labelMedium
                ?.copyWith(color: color),
          ),
        ],
      ),
    );
  }
}
