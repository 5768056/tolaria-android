import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../models/note.dart';
import '../models/note_filter.dart';
import '../providers/vault_provider.dart';
import 'category_picker.dart';

/// Note actions shared by the list screen's long-press menu and the reading
/// screen's overflow menu.
///
/// They live here rather than inside either screen so both entry points behave
/// identically — the same confirmation, the same undo, the same messages.

/// The undo prompt shown after a category move or archive toggle.
///
/// [SnackBar.persist] defaults to `action != null` — the framework parks any
/// snack bar that carries a button until the user taps it, and the 4-second
/// timer silently does nothing ("撤销提示不会消失，一直存在"). Undo prompts are
/// transient by design, so persist is pinned to false here; the route
/// observer (`SnackbarDismissOnNavigate`) hides them even earlier when the
/// user navigates away.
SnackBar undoSnackBar({required String message, VoidCallback? onUndo}) {
  return SnackBar(
    content: Text(message),
    persist: false,
    action: onUndo == null
        ? null
        : SnackBarAction(label: '撤销', onPressed: onUndo),
  );
}

/// Archive or restore [note], reporting the result with an undo action.
Future<void> toggleArchive(
  BuildContext context,
  WidgetRef ref,
  Note note,
) async {
  final messenger = ScaffoldMessenger.of(context);
  final archived = !note.isArchived;
  try {
    await ref.read(vaultProvider.notifier).setArchived(note, archived);
  } catch (e) {
    messenger.showSnackBar(SnackBar(content: Text('${archived ? '归档' : '取消归档'}失败：$e')));
    return;
  }
  messenger.hideCurrentSnackBar();
  messenger.showSnackBar(undoSnackBar(
    message: archived ? '已归档「${note.title}」' : '已取消归档「${note.title}」',
    onUndo: () async {
      try {
        await ref.read(vaultProvider.notifier).setArchived(note, !archived);
      } catch (e) {
        messenger.showSnackBar(SnackBar(content: Text('撤销失败：$e')));
      }
    },
  ));
}

/// Pick a category for [note] and write it into the note's `type:` field.
Future<void> moveToCategory(
  BuildContext context,
  WidgetRef ref,
  Note note,
) async {
  final messenger = ScaffoldMessenger.of(context);
  final state = ref.read(vaultProvider);

  // Re-read the note from the index: the caller may hold a snapshot from
  // before the last refresh (e.g. after an archive toggle).
  final current = state.notes.firstWhere(
    (n) => n.relativePath == note.relativePath,
    orElse: () => note,
  );

  final result = await showCategoryPicker(
    context,
    noteTitle: current.title,
    categories: state.index.categories,
    currentType: current.noteType,
    countOf: (type) => state.countFor(NoteFilter.type(type)),
  );
  if (result == null) return;

  final notifier = ref.read(vaultProvider.notifier);
  final previous = current.noteType;
  try {
    var type = result.type;
    if (result.isNewCategory && type != null) {
      type = await notifier.createCategory(type);
    }
    await notifier.setType(current, type);
    messenger.hideCurrentSnackBar();
    messenger.showSnackBar(undoSnackBar(
      message: type == null ? '已移出分类' : '已移到「$type」',
      // Moving back to the current type would be a no-op — no undo to offer.
      onUndo: type == previous
          ? null
          : () async {
              try {
                await notifier.setType(current, previous);
              } catch (e) {
                messenger.showSnackBar(SnackBar(content: Text('撤销失败：$e')));
              }
            },
    ));
  } catch (e) {
    messenger.showSnackBar(SnackBar(content: Text('分类失败：$e')));
  }
}
