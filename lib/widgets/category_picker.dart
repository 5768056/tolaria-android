import 'package:flutter/material.dart';

import '../services/vault_index.dart';
import 'color_dot.dart';
import 'sheet_insets.dart';

/// What the user chose in the category sheet.
///
/// A null [type] means "no category" (the note goes back to the inbox), while
/// an entirely null result means the sheet was dismissed.
class CategoryPickerResult {
  const CategoryPickerResult({this.type, this.isNewCategory = false});

  final String? type;

  /// True when [type] is a name the user just typed, so the caller should
  /// create the sidebar view for it before filing the note.
  final bool isNewCategory;
}

/// Bottom sheet for filing a note into one of the vault's categories.
///
/// The list comes from [VaultIndex.categories], i.e. `type:` values that
/// actually exist. Nothing is invented here — picking a row writes the same
/// field the desktop app's sidebar reads.
Future<CategoryPickerResult?> showCategoryPicker(
  BuildContext context, {
  required String noteTitle,
  required List<NoteTypeInfo> categories,
  required String? currentType,
  required int Function(String type) countOf,
}) async {
  final theme = Theme.of(context);
  final choice = await showModalBottomSheet<CategoryPickerResult>(
    context: context,
    showDragHandle: true,
    // Without this the sheet is capped at 9/16 of the screen, which fits three
    // categories and turns a nine-entry list into a scroll hunt.
    isScrollControlled: true,
    builder: (ctx) {
      return Padding(
        padding: sheetBottomInset(ctx),
        child: ConstrainedBox(
          constraints: BoxConstraints(
            maxHeight: MediaQuery.of(ctx).size.height * 0.72,
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(20, 0, 20, 12),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text('移动到分类', style: theme.textTheme.titleMedium),
                    const SizedBox(height: 2),
                    Text(
                      noteTitle,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: theme.textTheme.bodySmall
                          ?.copyWith(color: theme.colorScheme.outline),
                    ),
                  ],
                ),
              ),
              Flexible(
                child: ListView(
                  shrinkWrap: true,
                  children: [
                    ListTile(
                      leading: Icon(
                        Icons.inbox_outlined,
                        color: theme.colorScheme.outline,
                      ),
                      title: const Text('不分类'),
                      subtitle: const Text('回到收件箱'),
                      selected: currentType == null,
                      trailing: currentType == null
                          ? const Icon(Icons.check_rounded, size: 20)
                          : null,
                      onTap: () => Navigator.pop(
                        ctx,
                        const CategoryPickerResult(),
                      ),
                    ),
                    const Divider(height: 1, indent: 16, endIndent: 16),
                    for (final category in categories)
                      ListTile(
                        leading: ColorDot(
                          color: category.color,
                          icon: Icons.label_outline,
                        ),
                        title: Text(
                          category.label,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                        trailing: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Text(
                              '${countOf(category.value)}',
                              style: theme.textTheme.bodySmall,
                            ),
                            if (currentType == category.value) ...[
                              const SizedBox(width: 8),
                              const Icon(Icons.check_rounded, size: 20),
                            ],
                          ],
                        ),
                        selected: currentType == category.value,
                        onTap: () => Navigator.pop(
                          ctx,
                          CategoryPickerResult(type: category.value),
                        ),
                      ),
                    if (categories.isEmpty)
                      Padding(
                        padding: const EdgeInsets.fromLTRB(20, 8, 20, 8),
                        child: Text(
                          '这台设备上还没有分类。新建一个，它会作为视图写进知识库的 views 目录。',
                          style: theme.textTheme.bodySmall
                              ?.copyWith(color: theme.colorScheme.outline),
                        ),
                      ),
                  ],
                ),
              ),
              const Divider(height: 1),
              ListTile(
                leading: Icon(
                  Icons.create_new_folder_outlined,
                  color: theme.colorScheme.primary,
                ),
                title: Text(
                  '新建分类…',
                  style: TextStyle(color: theme.colorScheme.primary),
                ),
                onTap: () => Navigator.pop(
                  ctx,
                  const CategoryPickerResult(isNewCategory: true),
                ),
              ),
            ],
          ),
        ),
      );
    },
  );

  if (choice == null) return null;
  if (!choice.isNewCategory) return choice;
  if (!context.mounted) return null;

  final name = await _askCategoryName(context);
  if (name == null) return null;

  // Another spelling of a category that already exists: file it there instead
  // of creating a second sidebar entry that filters the same notes.
  final hit = categories.where(
    (c) =>
        c.value.toLowerCase() == name.toLowerCase() ||
        c.label.toLowerCase() == name.toLowerCase(),
  );
  if (hit.isNotEmpty) return CategoryPickerResult(type: hit.first.value);
  return CategoryPickerResult(type: name, isNewCategory: true);
}

/// Ask for a category name. Returns the trimmed text, or null when cancelled.
Future<String?> _askCategoryName(BuildContext context) async {
  final controller = TextEditingController();
  final name = await showDialog<String>(
    context: context,
    builder: (ctx) => AlertDialog(
      title: const Text('新建分类'),
      content: TextField(
        controller: controller,
        autofocus: true,
        decoration: const InputDecoration(
          labelText: '分类名',
          helperText: '会写进 views/ 目录，桌面端也能看到',
        ),
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
  if (name == null || name.isEmpty) return null;
  return name;
}
