import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_markdown/flutter_markdown.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../models/ai_config.dart';
import '../models/note.dart';
import '../providers/agent_provider.dart';
import '../providers/ai_provider.dart';
import '../providers/vault_provider.dart';
import '../services/agent/agent_tool.dart';
import '../widgets/agent_view.dart';
import 'ai_settings_screen.dart';

/// Which engine answers: the plain streaming chat, or the tool-using agent.
///
/// Both are kept because they fail differently. Chat streams token by token and
/// works on every provider; Agent can read and edit the vault but needs an
/// OpenAI-compatible endpoint that speaks `tool_calls`.
enum AiMode { chat, agent }

/// The phone counterpart of Tolaria's AI panel.
///
/// Desktop parity note: the desktop panel can drive a local CLI agent that
/// edits files through MCP. The phone cannot spawn that process, so the same
/// contract is reimplemented in Dart (`AgentRunner` + `vault_tools.dart`): the
/// model gets the eight vault tools and never gets a shell.
class AiChatScreen extends ConsumerStatefulWidget {
  const AiChatScreen({super.key, this.activeNote});

  /// The note the user came from, if any. Sent as context when the config
  /// allows it.
  final Note? activeNote;

  @override
  ConsumerState<AiChatScreen> createState() => _AiChatScreenState();
}

class _AiChatScreenState extends ConsumerState<AiChatScreen> {
  final _input = TextEditingController();
  final _scroll = ScrollController();
  final _inputFocus = FocusNode();

  /// Agent mode is the default: it is the reason this build exists, and the
  /// chat fallback is one tap away.
  AiMode _mode = AiMode.agent;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      _attachContext();
    });
  }

  /// Tells both engines which note the user came from. Called on open and again
  /// after returning from settings, since the endpoint may have just changed.
  void _attachContext() {
    final notes = ref.read(vaultProvider).notes;
    ref.read(aiChatProvider.notifier).attachContext(
          note: widget.activeNote,
          notes: notes,
        );
    ref.read(agentChatProvider.notifier).attachActiveNote(widget.activeNote);
  }

  @override
  void dispose() {
    _input.dispose();
    _scroll.dispose();
    _inputFocus.dispose();
    super.dispose();
  }

  /// Length of the answer currently being typed out. A streamed reply grows
  /// without adding a timeline item, so item count alone would miss it.
  static int _lastAnswerLength(List<AgentItem> items) {
    if (items.isEmpty) return 0;
    final last = items.last;
    return last is AgentAnswerItem ? last.text.length : 0;
  }

  void _scrollToBottom({bool animate = true}) {
    if (!_scroll.hasClients) return;
    final target = _scroll.position.maxScrollExtent;
    if (animate) {
      _scroll.animateTo(
        target,
        duration: const Duration(milliseconds: 180),
        curve: Curves.easeOut,
      );
    } else {
      _scroll.jumpTo(target);
    }
  }

  Future<void> _send() async {
    final text = _input.text.trim();
    if (text.isEmpty) return;

    if (_mode == AiMode.agent) {
      if (ref.read(agentChatProvider).running) return;
      _input.clear();
      // Not awaited: the notifier owns the loop and reports progress through
      // state. Awaiting here would keep the keyboard's "sending" frame alive
      // for the whole run.
      unawaited(ref.read(agentChatProvider.notifier).send(text, approve: _approve));
      _scrollToBottom();
      return;
    }

    _input.clear();
    await ref.read(aiChatProvider.notifier).send(text);
    _scrollToBottom();
  }

  /// Called by the agent loop before every write. Blocks the loop until the
  /// user answers; declining is a normal outcome, not an error.
  Future<bool> _approve(AgentTool tool, Map<String, dynamic> arguments) async {
    if (!mounted) return false;
    return showToolApproval(context, tool: tool.name, arguments: arguments);
  }

  void _stop() {
    if (_mode == AiMode.agent) {
      ref.read(agentChatProvider.notifier).stop();
    } else {
      ref.read(aiChatProvider.notifier).stop();
    }
  }

  void _clear() {
    ref.read(aiChatProvider.notifier).clear();
    ref.read(agentChatProvider.notifier).clear();
  }

  Future<void> _openSettings() async {
    await Navigator.of(context).push(
      MaterialPageRoute(builder: (_) => const AiSettingsScreen()),
    );
    if (!mounted) return;
    // The endpoint may have just been configured; keep the scope label honest.
    _attachContext();
  }

  @override
  Widget build(BuildContext context) {
    final state = ref.watch(aiChatProvider);
    final agent = ref.watch(agentChatProvider);
    final theme = Theme.of(context);

    final running = _mode == AiMode.agent ? agent.running : state.streaming;
    final error = _mode == AiMode.agent ? agent.error : state.error;
    final isEmpty = _mode == AiMode.agent ? agent.isEmpty : state.isEmpty;

    ref.listen<AiChatState>(aiChatProvider, (previous, next) {
      final grew = next.messages.isNotEmpty &&
          (previous?.messages.length != next.messages.length ||
              (next.messages.last.content.length !=
                  (previous?.messages.isNotEmpty ?? false
                      ? previous!.messages.last.content.length
                      : 0)));
      if (grew && next.streaming) {
        WidgetsBinding.instance.addPostFrameCallback((_) => _scrollToBottom());
      }
    });
    ref.listen<AgentChatState>(agentChatProvider, (previous, next) {
      // New items (a tool card, a paragraph) push the view down, and a streamed
      // answer grows the last item in place without changing the count. Follow
      // both, the same way Chat mode follows streamed tokens.
      final grew = next.items.length != (previous?.items.length ?? 0) ||
          _lastAnswerLength(next.items) !=
              _lastAnswerLength(previous?.items ?? const []);
      if (grew && next.running) {
        WidgetsBinding.instance.addPostFrameCallback((_) => _scrollToBottom());
      }
    });

    return Scaffold(
      appBar: AppBar(
        title: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            const Text('AI 助手'),
            Text(
              state.contextLabel.isEmpty ? '正在准备…' : state.contextLabel,
              style: theme.textTheme.labelSmall
                  ?.copyWith(color: theme.colorScheme.outline),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
          ],
        ),
        // A hairline that never finishes: the run can sit silently for half a
        // minute between tool rounds, and without this the screen looks dead.
        bottom: running
            ? const PreferredSize(
                preferredSize: Size.fromHeight(2),
                child: LinearProgressIndicator(minHeight: 2),
              )
            : null,
        actions: [
          // Which engine answers is a per-question decision, so the switch sits
          // in the app bar rather than in settings. It is a chip rather than a
          // segmented control because the app bar already carries two lines of
          // title on a phone-width screen.
          _ModeChip(
            mode: _mode,
            enabled: !running,
            onChanged: (mode) => setState(() => _mode = mode),
          ),
          IconButton(
            tooltip: '清空对话',
            icon: const Icon(Icons.refresh_rounded),
            onPressed: isEmpty ? null : _clear,
          ),
          IconButton(
            tooltip: 'AI 设置',
            icon: const Icon(Icons.tune_rounded),
            onPressed: _openSettings,
          ),
        ],
      ),
      body: Column(
        children: [
          if (error != null)
            _ErrorBar(
              message: error,
              onClose: () => _mode == AiMode.agent
                  ? ref.read(agentChatProvider.notifier).clearError()
                  : ref.read(aiChatProvider.notifier).clearError(),
            ),
          Expanded(
            child: isEmpty
                ? _EmptyState(
                    mode: _mode,
                    hasNote: widget.activeNote != null,
                    onPick: (text) {
                      _input.text = text;
                      _inputFocus.requestFocus();
                    },
                  )
                : _mode == AiMode.agent
                    ? AgentTimeline(
                        items: _agentTimelineItems(agent),
                        controller: _scroll,
                        onCopy: _copy,
                      )
                    : ListView.builder(
                        controller: _scroll,
                        padding: const EdgeInsets.fromLTRB(12, 12, 12, 8),
                        itemCount: state.messages.length,
                        itemBuilder: (context, index) {
                          final message = state.messages[index];
                          final isLast = index == state.messages.length - 1;
                          return _MessageBubble(
                            message: message,
                            streaming:
                                state.streaming && isLast && !message.isUser,
                            onCopy: () => _copy(message.content),
                            onSaveAsNote: message.isUser
                                ? null
                                : () => _saveAsNote(index),
                          );
                        },
                      ),
          ),
        ],
      ),
      // The composer lives in the bottom bar slot, not at the end of the body,
      // so SnackBars ("已存为笔记") appear above it instead of being painted
      // underneath the input field.
      //
      // The IME padding is load-bearing: Scaffold anchors this slot at the raw
      // window bottom, which on edge-to-edge Android (15+, enforced by
      // targetSdk 35+) is *behind* the keyboard — the window no longer shrinks
      // for it. Padding by viewInsets keeps the input above the keys; on older
      // Androids, where the window does resize, the inset is already 0 and
      // nothing moves.
      bottomNavigationBar: Padding(
        padding: EdgeInsets.only(bottom: MediaQuery.viewInsetsOf(context).bottom),
        child: _Composer(
          controller: _input,
          focusNode: _inputFocus,
          streaming: running,
          agentMode: _mode == AiMode.agent,
          onSend: _send,
          onStop: _stop,
        ),
      ),
    );
  }

  /// The agent timeline plus a synthetic "thinking" row while a run is between
  /// events — a running tool card already spins on its own, so the row is only
  /// added when nothing else on screen is moving.
  List<AgentItem> _agentTimelineItems(AgentChatState agent) {
    if (!agent.running) return agent.items;
    final last = agent.items.isEmpty ? null : agent.items.last;
    if (last is AgentToolItem && last.running) return agent.items;
    return [...agent.items, const AgentWorkingItem()];
  }

  Future<void> _copy(String text) async {
    await Clipboard.setData(ClipboardData(text: text));
    if (!mounted) return;
    ScaffoldMessenger.of(context)
        .showSnackBar(const SnackBar(content: Text('已复制')));
  }

  /// Chat-mode convenience: promote an answer into the vault in one tap.
  ///
  /// Agent mode has a real `create_note` tool, so this button only appears in
  /// the chat transcript — there it is the only way to keep an answer.
  ///
  /// The note is titled after the *question that produced it*, not the answer's
  /// first line — saving three answers from one session otherwise produced
  /// three notes all called "这是一段模拟回答…", which is useless in a list.
  Future<void> _saveAsNote(int index) async {
    final messages = ref.read(aiChatProvider).messages;
    if (index < 0 || index >= messages.length) return;
    final message = messages[index];
    final content = message.content.trim();
    if (content.isEmpty) return;

    final vault = ref.read(vaultProvider);
    if (vault.config == null) {
      ScaffoldMessenger.of(context)
          .showSnackBar(const SnackBar(content: Text('知识库未打开')));
      return;
    }

    // Walk back to the prompt this answer belongs to.
    String? question;
    for (var i = index - 1; i >= 0; i--) {
      if (messages[i].isUser) {
        question = messages[i].content;
        break;
      }
    }

    final title = _titleFrom(question ?? content);
    try {
      final notifier = ref.read(vaultProvider.notifier);
      final created = await notifier.addNote(title);
      await notifier.saveNote(Note(
        relativePath: created.relativePath,
        title: created.title,
        frontmatter: created.frontmatter,
        body: content,
        modified: DateTime.now(),
      ));
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('已存为笔记：${created.relativePath}')),
      );
    } catch (error) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('保存失败：$error')),
      );
    }
  }

  /// First meaningful line becomes the note title, stripped of Markdown
  /// decoration so the filename stays readable.
  static String _titleFrom(String content) {
    for (final line in content.split('\n')) {
      final cleaned = line
          .replaceAll(RegExp(r'^[#>\-*\d.\s]+'), '')
          .replaceAll(RegExp(r'[*_`]'), '')
          .trim();
      if (cleaned.isEmpty) continue;
      return cleaned.length > 40 ? cleaned.substring(0, 40) : cleaned;
    }
    return 'AI 回答';
  }
}

class _ErrorBar extends StatelessWidget {
  const _ErrorBar({required this.message, required this.onClose});

  final String message;
  final VoidCallback onClose;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Container(
      width: double.infinity,
      color: theme.colorScheme.errorContainer,
      padding: const EdgeInsets.fromLTRB(16, 10, 8, 10),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(Icons.error_outline,
              size: 20, color: theme.colorScheme.onErrorContainer),
          const SizedBox(width: 8),
          Expanded(
            child: SelectableText(
              message,
              style: theme.textTheme.bodySmall
                  ?.copyWith(color: theme.colorScheme.onErrorContainer),
            ),
          ),
          IconButton(
            visualDensity: VisualDensity.compact,
            icon: Icon(Icons.close, size: 18,
                color: theme.colorScheme.onErrorContainer),
            onPressed: onClose,
          ),
        ],
      ),
    );
  }
}

class _EmptyState extends ConsumerWidget {
  const _EmptyState({
    required this.mode,
    required this.hasNote,
    required this.onPick,
  });

  final AiMode mode;
  final bool hasNote;
  final ValueChanged<String> onPick;

  static const _notePrompts = [
    '总结这篇笔记的要点',
    '把这部分改写成更简洁的表述',
    '这篇笔记还缺什么？给我补充建议',
    '找出文中前后矛盾或可疑的地方',
  ];

  static const _generalPrompts = [
    '我这个知识库里都有什么？',
    '帮我理一下「自媒体」这个类型下的笔记',
    '把一段想法整理成结构化笔记',
  ];

  /// Agent prompts name an action on a file, because that is what this mode can
  /// do — suggesting "总结这篇笔记" here would waste its only advantage.
  static const _agentPrompts = [
    '我这个知识库有多少篇笔记？哪些还没归档？',
    '找出内容重复或标题相近的笔记，列给我',
    '在今天的笔记末尾加一句：今天把 Tolaria 搬到手机上了',
  ];

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final agentMode = mode == AiMode.agent;
    final prompts = agentMode
        ? _agentPrompts
        : (hasNote ? _notePrompts : _generalPrompts);

    return ListView(
      controller: null,
      padding: const EdgeInsets.fromLTRB(24, 32, 24, 24),
      children: [
        Icon(
          agentMode ? Icons.auto_fix_high_rounded : Icons.auto_awesome_outlined,
          size: 56,
          color: theme.colorScheme.primary,
        ),
        const SizedBox(height: 16),
        Text(
          agentMode
              ? '让 AI 直接动你的笔记'
              : (hasNote ? '就当前笔记提问' : '问问你的知识库'),
          textAlign: TextAlign.center,
          style: theme.textTheme.titleMedium,
        ),
        const SizedBox(height: 8),
        Text(
          agentMode
              ? '它可以列出、搜索、读取你的笔记，也能新建和修改——每次改动前都会先问你。'
                  '它跑不了命令，也碰不到知识库以外的文件。'
              : (hasNote
                  ? '这篇笔记的内容会一起发给模型，回答里可以直接引用。'
                  : '从笔记页进来时会自动带上那篇笔记；这里也可以直接提问。'),
          textAlign: TextAlign.center,
          style: theme.textTheme.bodySmall
              ?.copyWith(color: theme.colorScheme.outline),
        ),
        const SizedBox(height: 28),
        for (final prompt in prompts)
          Padding(
            padding: const EdgeInsets.only(bottom: 8),
            child: OutlinedButton(
              onPressed: () => onPick(prompt),
              style: OutlinedButton.styleFrom(
                alignment: Alignment.centerLeft,
                padding:
                    const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
              ),
              child: Text(prompt, textAlign: TextAlign.left),
            ),
          ),
      ],
    );
  }
}

class _MessageBubble extends StatelessWidget {
  const _MessageBubble({
    required this.message,
    required this.streaming,
    required this.onCopy,
    this.onSaveAsNote,
  });

  final AiMessage message;
  final bool streaming;
  final VoidCallback onCopy;
  final VoidCallback? onSaveAsNote;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    if (message.isUser) {
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
            message.content,
            style: theme.textTheme.bodyMedium
                ?.copyWith(color: theme.colorScheme.onPrimaryContainer),
          ),
        ),
      );
    }

    final body = message.content.trim();
    final waiting = streaming && body.isEmpty;

    return Container(
      margin: const EdgeInsets.only(bottom: 12, right: 24),
      padding: const EdgeInsets.fromLTRB(14, 10, 8, 6),
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
          if (waiting)
            Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                const SizedBox(
                  width: 14,
                  height: 14,
                  child: CircularProgressIndicator(strokeWidth: 2),
                ),
                const SizedBox(width: 10),
                Text('正在思考…', style: theme.textTheme.bodySmall),
              ],
            )
          else
            MarkdownBody(
              data: streaming ? '$body▌' : body,
              selectable: true,
              styleSheet: MarkdownStyleSheet.fromTheme(theme).copyWith(
                p: theme.textTheme.bodyMedium,
                codeblockDecoration: BoxDecoration(
                  color: theme.colorScheme.surface,
                  borderRadius: BorderRadius.circular(8),
                ),
              ),
            ),
          if (!streaming && body.isNotEmpty)
            Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                IconButton(
                  tooltip: '复制',
                  visualDensity: VisualDensity.compact,
                  icon: const Icon(Icons.copy_all_outlined, size: 18),
                  onPressed: onCopy,
                ),
                if (onSaveAsNote != null)
                  IconButton(
                    tooltip: '存为笔记',
                    visualDensity: VisualDensity.compact,
                    icon: const Icon(Icons.note_add_outlined, size: 18),
                    onPressed: onSaveAsNote,
                  ),
              ],
            ),
        ],
      ),
    );
  }
}

/// The mode switch: a chip that opens a menu.
///
/// A chip instead of a segmented control because the app bar already carries a
/// two-line title; showing both modes side by side would push the title off a
/// narrow phone. The label always states the *current* engine, so a wrong
/// answer to "why didn't it edit my file" is one glance away.
class _ModeChip extends StatelessWidget {
  const _ModeChip({
    required this.mode,
    required this.enabled,
    required this.onChanged,
  });

  final AiMode mode;
  final bool enabled;
  final ValueChanged<AiMode> onChanged;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final agent = mode == AiMode.agent;
    final accent =
        agent ? theme.colorScheme.primary : theme.colorScheme.onSurfaceVariant;

    return PopupMenuButton<AiMode>(
      enabled: enabled,
      tooltip: agent ? '当前：Agent（能读改笔记）' : '当前：问答（只回答问题）',
      onSelected: onChanged,
      itemBuilder: (context) => [
        _modeItem(
          context,
          value: AiMode.agent,
          icon: Icons.auto_fix_high_rounded,
          title: 'Agent 改库',
          subtitle: '能列出、搜索、读取，也能新建和修改笔记；每次改动前先问你',
        ),
        _modeItem(
          context,
          value: AiMode.chat,
          icon: Icons.forum_outlined,
          title: '问答',
          subtitle: '只根据发给它的内容回答，不碰你的文件；所有服务商都能用',
        ),
      ],
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 4),
        child: Container(
          padding: const EdgeInsets.fromLTRB(9, 5, 4, 5),
          decoration: BoxDecoration(
            color: accent.withValues(alpha: enabled ? 0.12 : 0.06),
            borderRadius: BorderRadius.circular(20),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(
                agent ? Icons.auto_fix_high_rounded : Icons.forum_outlined,
                size: 14,
                color: accent,
              ),
              const SizedBox(width: 4),
              Text(
                agent ? 'Agent' : '问答',
                style: theme.textTheme.labelMedium?.copyWith(color: accent),
              ),
              Icon(Icons.arrow_drop_down_rounded, size: 16, color: accent),
            ],
          ),
        ),
      ),
    );
  }

  PopupMenuItem<AiMode> _modeItem(
    BuildContext context, {
    required AiMode value,
    required IconData icon,
    required String title,
    required String subtitle,
  }) {
    final theme = Theme.of(context);
    final selected = value == mode;
    return PopupMenuItem<AiMode>(
      value: value,
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(
            icon,
            size: 18,
            color: selected
                ? theme.colorScheme.primary
                : theme.colorScheme.onSurfaceVariant,
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  title,
                  style: theme.textTheme.bodyMedium?.copyWith(
                    fontWeight: selected ? FontWeight.w600 : FontWeight.w400,
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  subtitle,
                  style: theme.textTheme.bodySmall
                      ?.copyWith(color: theme.colorScheme.outline),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _Composer extends StatelessWidget {
  const _Composer({
    required this.controller,
    required this.focusNode,
    required this.streaming,
    required this.agentMode,
    required this.onSend,
    required this.onStop,
  });

  final TextEditingController controller;
  final FocusNode focusNode;
  final bool streaming;
  final bool agentMode;
  final VoidCallback onSend;
  final VoidCallback onStop;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return SafeArea(
      top: false,
      child: Container(
        padding: const EdgeInsets.fromLTRB(12, 8, 8, 8),
        decoration: BoxDecoration(
          border: Border(
            top: BorderSide(color: theme.dividerColor.withValues(alpha: 0.4)),
          ),
        ),
        // Text in, text out — no attachment tray. The model is text-only, so a
        // "+" that only ever produced a path reference was room in the layout
        // for something the user never needed.
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.end,
          children: [
            Expanded(
              child: TextField(
                controller: controller,
                focusNode: focusNode,
                minLines: 1,
                maxLines: 5,
                textInputAction: TextInputAction.newline,
                decoration: InputDecoration(
                  hintText: agentMode ? '让它读、找、改你的笔记…' : '问点什么…',
                  isDense: true,
                  filled: true,
                  fillColor: theme.colorScheme.surfaceContainerHighest
                      .withValues(alpha: 0.5),
                  contentPadding:
                      const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
                  border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(22),
                    borderSide: BorderSide.none,
                  ),
                ),
              ),
            ),
            const SizedBox(width: 6),
            IconButton.filled(
              onPressed: streaming ? onStop : onSend,
              icon: Icon(streaming
                  ? Icons.stop_rounded
                  : Icons.arrow_upward_rounded),
              tooltip: streaming ? '停止' : '发送',
            ),
          ],
        ),
      ),
    );
  }
}
