import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_markdown/flutter_markdown.dart';

import '../providers/agent_provider.dart';

/// Presentation for Agent mode: the tool cards, and the dialog that asks before
/// a file is touched.
///
/// Labels are Chinese and verb-first ("修改笔记", not `edit_note`) because the
/// tool name is developer vocabulary; what the user needs to recognise at a
/// glance is that the model is about to change a file.

class _ToolLook {
  const _ToolLook(this.icon, this.label, this.writes);
  final IconData icon;
  final String label;
  final bool writes;
}

const Map<String, _ToolLook> _tools = {
  'list_notes': _ToolLook(Icons.format_list_bulleted_rounded, '列出笔记', false),
  'read_note': _ToolLook(Icons.description_outlined, '读取笔记', false),
  'search_notes': _ToolLook(Icons.search_rounded, '搜索笔记', false),
  'note_meta': _ToolLook(Icons.info_outline_rounded, '查看属性', false),
  'create_note': _ToolLook(Icons.note_add_outlined, '新建笔记', true),
  'edit_note': _ToolLook(Icons.edit_outlined, '修改笔记', true),
  'append_note': _ToolLook(Icons.playlist_add_rounded, '追加内容', true),
  'fetch_url': _ToolLook(Icons.language_rounded, '打开网页', false),
  'web_search': _ToolLook(Icons.travel_explore_rounded, '联网搜索', false),
};

_ToolLook _lookOf(String name) =>
    _tools[name] ?? _ToolLook(Icons.build_outlined, name, false);

/// One tool call, collapsed to a single row until tapped.
///
/// The row is tappable rather than always-expanded because a "find the note,
/// read it, edit it" turn produces three cards; showing every argument inline
/// would bury the answer underneath the plumbing.
class AgentToolCard extends StatefulWidget {
  const AgentToolCard({super.key, required this.item});

  final AgentToolItem item;

  @override
  State<AgentToolCard> createState() => _AgentToolCardState();
}

class _AgentToolCardState extends State<AgentToolCard> {
  late bool _expanded = widget.item.isError;

  @override
  void didUpdateWidget(covariant AgentToolCard oldWidget) {
    super.didUpdateWidget(oldWidget);
    // A call that fails after the card was built should open itself; a silent
    // red dot the user has to hunt for is worse than no report at all.
    if (widget.item.isError && !oldWidget.item.isError) _expanded = true;
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final item = widget.item;
    final look = _lookOf(item.name);

    final accent = item.running
        ? theme.colorScheme.outline
        : item.isError
            ? theme.colorScheme.error
            : theme.colorScheme.primary;

    return Container(
      margin: const EdgeInsets.only(bottom: 8, right: 32),
      decoration: BoxDecoration(
        color: theme.colorScheme.surfaceContainerHighest.withValues(alpha: 0.35),
        borderRadius: BorderRadius.circular(12),
        border: Border(left: BorderSide(color: accent, width: 3)),
      ),
      clipBehavior: Clip.antiAlias,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          InkWell(
            onTap: () => setState(() => _expanded = !_expanded),
            child: Padding(
              padding: const EdgeInsets.fromLTRB(10, 8, 8, 8),
              child: Row(
                children: [
                  Icon(look.icon, size: 17, color: accent),
                  const SizedBox(width: 8),
                  Text(
                    look.label,
                    style: theme.textTheme.labelLarge
                        ?.copyWith(color: theme.colorScheme.onSurface),
                  ),
                  if (look.writes) ...[
                    const SizedBox(width: 6),
                    _Tag(
                      text: '改动',
                      color: theme.colorScheme.tertiary,
                    ),
                  ],
                  if (item.subject.isNotEmpty) ...[
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        item.subject,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: theme.textTheme.bodySmall?.copyWith(
                          color: theme.colorScheme.outline,
                          fontFamily: 'monospace',
                        ),
                      ),
                    ),
                  ] else
                    const Spacer(),
                  const SizedBox(width: 6),
                  if (item.running)
                    const SizedBox(
                      width: 14,
                      height: 14,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  else
                    Icon(
                      item.isError
                          ? Icons.error_outline_rounded
                          : Icons.check_circle_outline_rounded,
                      size: 16,
                      color: accent,
                    ),
                  Icon(
                    _expanded
                        ? Icons.keyboard_arrow_up_rounded
                        : Icons.keyboard_arrow_down_rounded,
                    size: 18,
                    color: theme.colorScheme.outline,
                  ),
                ],
              ),
            ),
          ),
          if (_expanded)
            Padding(
              padding: const EdgeInsets.fromLTRB(10, 0, 10, 10),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  if (item.name == 'edit_note') ...[
                    _Block(
                      label: '原文',
                      text: (item.arguments['old_string'] ?? '').toString(),
                      tint: theme.colorScheme.errorContainer,
                      onTint: theme.colorScheme.onErrorContainer,
                    ),
                    const SizedBox(height: 6),
                    _Block(
                      label: '改为',
                      text: (item.arguments['new_string'] ?? '').toString(),
                      tint: theme.colorScheme.primaryContainer,
                      onTint: theme.colorScheme.onPrimaryContainer,
                    ),
                  ] else if (_argsPreview(item).isNotEmpty)
                    _Block(
                      label: '参数',
                      text: _argsPreview(item),
                      tint: theme.colorScheme.surface,
                      onTint: theme.colorScheme.onSurface,
                    ),
                  if (item.result != null) ...[
                    const SizedBox(height: 6),
                    _Block(
                      label: item.isError ? '失败原因' : '结果',
                      text: item.result!,
                      tint: item.isError
                          ? theme.colorScheme.errorContainer
                          : theme.colorScheme.surface,
                      onTint: item.isError
                          ? theme.colorScheme.onErrorContainer
                          : theme.colorScheme.onSurface,
                    ),
                  ],
                ],
              ),
            ),
        ],
      ),
    );
  }

  /// `edit_note` shows its two strings as a diff, so its remaining args are
  /// noise; everything else prints the JSON the model sent.
  String _argsPreview(AgentToolItem item) {
    if (item.name == 'edit_note') {
      final path = item.arguments['path'];
      return path is String ? 'path: $path' : '';
    }
    final args = Map<String, dynamic>.from(item.arguments)
      ..removeWhere((_, value) => value == null || value == '');
    if (args.isEmpty) return '';
    const encoder = JsonEncoder.withIndent('  ');
    return encoder.convert(args);
  }
}

class _Tag extends StatelessWidget {
  const _Tag({required this.text, required this.color});

  final String text;
  final Color color;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 1),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.14),
        borderRadius: BorderRadius.circular(4),
      ),
      child: Text(
        text,
        style: theme.textTheme.labelSmall?.copyWith(color: color, fontSize: 10),
      ),
    );
  }
}

/// "The model is thinking" — shown between tool rounds, when nothing else on
/// screen moves. A run can sit here for 30+ seconds waiting on the API; without
/// this row that silence is indistinguishable from a hang.
class _WorkingCard extends StatefulWidget {
  @override
  State<_WorkingCard> createState() => _WorkingCardState();
}

class _WorkingCardState extends State<_WorkingCard>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller = AnimationController(
    duration: const Duration(milliseconds: 900),
    vsync: this,
  )..repeat(reverse: true);

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Container(
      margin: const EdgeInsets.only(bottom: 8, right: 32),
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      decoration: BoxDecoration(
        color: theme.colorScheme.surfaceContainerHighest.withValues(alpha: 0.35),
        borderRadius: BorderRadius.circular(12),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          const SizedBox(
            width: 14,
            height: 14,
            child: CircularProgressIndicator(strokeWidth: 2),
          ),
          const SizedBox(width: 10),
          FadeTransition(
            opacity: Tween(begin: 0.55, end: 1.0).animate(_controller),
            child: Text(
              '正在思考…',
              style: theme.textTheme.bodySmall
                  ?.copyWith(color: theme.colorScheme.onSurfaceVariant),
            ),
          ),
        ],
      ),
    );
  }
}

/// A labelled monospace box. Used for diffs, arguments and tool output.
class _Block extends StatelessWidget {
  const _Block({
    required this.label,
    required this.text,
    required this.tint,
    required this.onTint,
  });

  final String label;
  final String text;
  final Color tint;
  final Color onTint;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.fromLTRB(8, 6, 8, 7),
      decoration: BoxDecoration(
        color: tint,
        borderRadius: BorderRadius.circular(8),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            label,
            style: theme.textTheme.labelSmall?.copyWith(
              color: onTint.withValues(alpha: 0.65),
              fontSize: 10,
            ),
          ),
          const SizedBox(height: 2),
          SelectableText(
            text.length > 1200 ? '${text.substring(0, 1200)}…' : text,
            style: theme.textTheme.bodySmall?.copyWith(
              color: onTint,
              fontFamily: 'monospace',
              height: 1.35,
            ),
          ),
        ],
      ),
    );
  }
}

// --------------------------------------------------------------- approval

/// Asks before a write. Returns false when the dialog is dismissed by tapping
/// outside or pressing back — "no" must be the easy outcome.
Future<bool> showToolApproval(
  BuildContext context, {
  required String tool,
  required Map<String, dynamic> arguments,
}) async {
  final look = _lookOf(tool);
  final path = (arguments['path'] ?? arguments['title'] ?? '').toString();
  final approved = await showDialog<bool>(
    context: context,
    barrierDismissible: false,
    builder: (context) => AlertDialog(
      icon: Icon(look.icon),
      title: Text(path.isEmpty ? look.label : '${look.label}：$path'),
      content: SizedBox(
        width: double.maxFinite,
        child: SingleChildScrollView(
          child: _ApprovalBody(tool: tool, arguments: arguments),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(false),
          child: const Text('不改'),
        ),
        FilledButton(
          onPressed: () => Navigator.of(context).pop(true),
          child: const Text('允许这次改动'),
        ),
      ],
    ),
  );
  return approved ?? false;
}

class _ApprovalBody extends StatelessWidget {
  const _ApprovalBody({required this.tool, required this.arguments});

  final String tool;
  final Map<String, dynamic> arguments;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    const note =
        '模型想直接改这个文件。改动会立刻写进你的知识库，之后能用 git 撤回。';

    switch (tool) {
      case 'edit_note':
        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(note, style: theme.textTheme.bodySmall),
            const SizedBox(height: 10),
            _Block(
              label: '原文（将被替换）',
              text: (arguments['old_string'] ?? '').toString(),
              tint: theme.colorScheme.errorContainer,
              onTint: theme.colorScheme.onErrorContainer,
            ),
            const SizedBox(height: 6),
            _Block(
              label: '改为',
              text: (arguments['new_string'] ?? '').toString(),
              tint: theme.colorScheme.primaryContainer,
              onTint: theme.colorScheme.onPrimaryContainer,
            ),
          ],
        );
      case 'append_note':
        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('会在笔记末尾追加下面的内容，原有内容不动。',
                style: theme.textTheme.bodySmall),
            const SizedBox(height: 10),
            _Block(
              label: '追加内容',
              text: (arguments['text'] ?? '').toString(),
              tint: theme.colorScheme.primaryContainer,
              onTint: theme.colorScheme.onPrimaryContainer,
            ),
          ],
        );
      case 'create_note':
        final type = arguments['type'];
        final body = (arguments['body'] ?? '').toString();
        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              type is String && type.trim().isNotEmpty
                  ? '新笔记会写在「$type」分类下，同名文件不会被覆盖。'
                  : '会新建一篇笔记，同名文件不会被覆盖。',
              style: theme.textTheme.bodySmall,
            ),
            const SizedBox(height: 10),
            _Block(
              label: '正文',
              text: body.isEmpty ? '（空）' : body,
              tint: theme.colorScheme.primaryContainer,
              onTint: theme.colorScheme.onPrimaryContainer,
            ),
          ],
        );
      default:
        return Text(note, style: theme.textTheme.bodySmall);
    }
  }
}

/// Full-timeline view for Agent mode.
class AgentTimeline extends StatelessWidget {
  const AgentTimeline({
    super.key,
    required this.items,
    required this.onCopy,
    this.controller,
  });

  final List<AgentItem> items;
  final void Function(String text) onCopy;
  final ScrollController? controller;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return ListView.builder(
      controller: controller,
      padding: const EdgeInsets.fromLTRB(12, 12, 12, 8),
      itemCount: items.length,
      itemBuilder: (context, index) {
        final item = items[index];
        switch (item) {
          case AgentUserItem(:final text):
            return _UserBubble(text: text);
          case AgentAnswerItem(:final text):
            return _AnswerCard(text: text, onCopy: () => onCopy(text));
          case AgentToolItem():
            return AgentToolCard(item: item);
          case AgentWorkingItem():
            return _WorkingCard();
          case AgentNoticeItem(:final text):
            return Padding(
              padding: const EdgeInsets.fromLTRB(4, 0, 24, 10),
              child: Row(
                children: [
                  Icon(Icons.info_outline_rounded,
                      size: 14, color: theme.colorScheme.outline),
                  const SizedBox(width: 6),
                  Expanded(
                    child: Text(
                      text,
                      style: theme.textTheme.bodySmall
                          ?.copyWith(color: theme.colorScheme.outline),
                    ),
                  ),
                ],
              ),
            );
        }
      },
    );
  }
}

class _UserBubble extends StatelessWidget {
  const _UserBubble({required this.text});

  final String text;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Align(
      alignment: Alignment.centerRight,
      child: Container(
        constraints: BoxConstraints(
          maxWidth: MediaQuery.of(context).size.width * 0.82,
        ),
        margin: const EdgeInsets.only(bottom: 12, left: 32),
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
        decoration: BoxDecoration(
          color: theme.colorScheme.primaryContainer,
          borderRadius: const BorderRadius.only(
            topLeft: Radius.circular(16),
            topRight: Radius.circular(16),
            bottomLeft: Radius.circular(16),
            bottomRight: Radius.circular(4),
          ),
        ),
        child: SelectableText(
          text,
          style: theme.textTheme.bodyMedium
              ?.copyWith(color: theme.colorScheme.onPrimaryContainer),
        ),
      ),
    );
  }
}

class _AnswerCard extends StatelessWidget {
  const _AnswerCard({required this.text, required this.onCopy});

  final String text;
  final VoidCallback onCopy;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Container(
      margin: const EdgeInsets.only(bottom: 12, right: 24),
      padding: const EdgeInsets.fromLTRB(14, 10, 8, 4),
      decoration: BoxDecoration(
        color: theme.colorScheme.surfaceContainerHighest.withValues(alpha: 0.5),
        borderRadius: const BorderRadius.only(
          topLeft: Radius.circular(16),
          topRight: Radius.circular(16),
          bottomLeft: Radius.circular(4),
          bottomRight: Radius.circular(16),
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          MarkdownBody(
            data: text,
            selectable: true,
            styleSheet: MarkdownStyleSheet.fromTheme(theme).copyWith(
              p: theme.textTheme.bodyMedium,
              codeblockDecoration: BoxDecoration(
                color: theme.colorScheme.surface,
                borderRadius: BorderRadius.circular(8),
              ),
            ),
          ),
          Align(
            alignment: Alignment.centerLeft,
            child: IconButton(
              tooltip: '复制',
              visualDensity: VisualDensity.compact,
              icon: const Icon(Icons.copy_all_outlined, size: 18),
              onPressed: onCopy,
            ),
          ),
        ],
      ),
    );
  }
}
