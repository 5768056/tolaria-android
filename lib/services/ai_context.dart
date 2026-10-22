import '../models/ai_config.dart';
import '../models/note.dart';

/// Turns vault state into the prompt the model actually sees.
///
/// The desktop app sends a compacted head/tail snapshot of the open note plus
/// an MCP handle, because its agent can call `get_note(path)` for the rest.
/// A phone model has no such tool, so the trade is different and deliberate:
///
///  * the open note gets a much larger slice of real text, truncated in the
///    middle rather than the end (conclusions usually live at the bottom);
///  * the rest of the vault is offered as a *file listing* only, not content.
///    Titles are cheap and let the model answer "you have a note about this,
///    it's called X" honestly instead of inventing one.
///
/// Everything here is plain string building — no network, no IO — so it is
/// unit-testable without a vault directory.
class AiContext {
  /// How much of the open note's body is sent verbatim.
  static const int bodyHead = 12000;
  static const int bodyTail = 4000;

  /// Upper bound on the vault outline entries.
  static const int maxOutlineEntries = 200;

  /// How many past turns are replayed. Beyond this the model mostly wastes
  /// context repeating itself.
  static const int maxHistoryMessages = 20;

  /// Builds the full message list for one request.
  ///
  /// [history] is the conversation so far (without the pending question);
  /// [question] is what the user just typed.
  static List<AiMessage> build({
    required AiConfig config,
    required List<AiMessage> history,
    required String question,
    Note? activeNote,
    List<Note> vaultNotes = const [],
  }) {
    final messages = <AiMessage>[];

    final system = _systemPrompt(
      activeNote: activeNote,
      vaultNotes: vaultNotes,
      includeContext: config.includeNoteContext,
    );
    if (system.isNotEmpty) {
      messages.add(AiMessage(role: 'system', content: system));
    }

    final recent = history.length > maxHistoryMessages
        ? history.sublist(history.length - maxHistoryMessages)
        : history;
    for (final message in recent) {
      // Error bubbles are UI-only; replaying them confuses the model.
      if (message.error) continue;
      if (message.content.trim().isEmpty) continue;
      messages.add(AiMessage(role: message.role, content: message.content));
    }

    messages.add(AiMessage(role: 'user', content: question.trim()));
    return messages;
  }

  /// A one-line description of what was attached, shown above the composer so
  /// the user can tell whether the answer had access to the note.
  static String scopeLabel({
    required AiConfig config,
    Note? activeNote,
    List<Note> vaultNotes = const [],
  }) {
    if (!config.includeNoteContext) return '仅当前对话（未附带笔记）';
    final parts = <String>[];
    if (activeNote != null) parts.add('当前笔记');
    if (vaultNotes.isNotEmpty) parts.add('知识库目录 ${vaultNotes.length} 篇');
    if (parts.isEmpty) return '仅当前对话（知识库为空）';
    return '已附带：${parts.join(' + ')}';
  }

  static String _systemPrompt({
    required Note? activeNote,
    required List<Note> vaultNotes,
    required bool includeContext,
  }) {
    final buffer = StringBuffer();
    buffer.writeln(
      '你是 Tolaria 笔记应用里的助手。用户正在 Android 手机上使用这个应用，'
      '你是它的 AI 面板。',
    );
    buffer.writeln();
    buffer.writeln('回答要求：');
    buffer.writeln('- 默认用简体中文回答；用户用其他语言提问时跟随用户。');
    buffer.writeln('- 直接给结论，不要"好的，我来帮你"这类开场。');
    buffer.writeln('- 可以使用 Markdown：标题、列表、表格、代码块。');
    buffer.writeln('- 只能依据下面给出的资料回答；资料不足时，直接说明缺什么，'
        '不要编造笔记里没有的内容。');
    buffer.writeln();

    if (!includeContext) {
      buffer.writeln('（本次对话没有附带用户的笔记内容。）');
      return buffer.toString();
    }

    if (vaultNotes.isNotEmpty) {
      buffer.writeln('【知识库目录】共 ${vaultNotes.length} 篇笔记'
          '${vaultNotes.length > maxOutlineEntries ? '，下面只列出前 $maxOutlineEntries 篇' : ''}：');
      final shown = vaultNotes.take(maxOutlineEntries).toList()
        ..sort((a, b) => a.relativePath.compareTo(b.relativePath));
      for (final note in shown) {
        final type = note.frontmatter['type'];
        final typeLabel = type == null ? '' : ' · ${_stringify(type)}';
        buffer.writeln('- ${note.relativePath} — ${note.title}$typeLabel');
      }
      buffer.writeln();
      buffer.writeln(
        '注意：目录只有标题和路径，没有正文。如果用户的提问需要某篇笔记的具体内容，'
        '而它不在下面"当前笔记"里，就说明你只能看到标题，请让用户打开那篇笔记再问。',
      );
      buffer.writeln();
    }

    if (activeNote != null) {
      buffer.writeln('【用户当前打开的笔记】');
      buffer.writeln('标题：${activeNote.title}');
      buffer.writeln('路径：${activeNote.relativePath}');
      final type = activeNote.frontmatter['type'];
      if (type != null) buffer.writeln('类型：${_stringify(type)}');
      final tags = activeNote.frontmatter['tags'] ?? activeNote.frontmatter['tag'];
      if (tags != null) buffer.writeln('标签：${_stringify(tags)}');
      buffer.writeln('正文：');
      buffer.writeln(_truncateBody(activeNote.body));
    }

    return buffer.toString();
  }

  /// Keeps both ends of a long note. Cutting only the tail loses the summary
  /// and conclusion, which is what most questions are actually about.
  static String _truncateBody(String body) {
    final text = body.trim();
    if (text.length <= bodyHead + bodyTail) return text;

    final head = text.substring(0, bodyHead);
    final tail = text.substring(text.length - bodyTail);
    final omitted = text.length - bodyHead - bodyTail;
    return '$head\n\n…（中间省略 $omitted 字）…\n\n$tail';
  }

  static String _stringify(Object? value) {
    if (value is List) return value.map(_stringify).join(', ');
    return value.toString();
  }
}
