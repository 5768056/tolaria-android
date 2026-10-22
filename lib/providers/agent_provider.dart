import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../models/ai_config.dart';
import '../models/note.dart';
import '../services/agent/agent_runner.dart';
import '../services/agent/agent_tool.dart';
import '../services/ai_session_store.dart';
import '../services/vault_service.dart';
import 'ai_provider.dart';
import 'vault_provider.dart';

/// Conversation timeline for Agent mode.
///
/// Chat mode keeps one bubble per turn; agent mode needs a mixed timeline —
/// prose, tool calls, their results, notices — because the interesting part of
/// an agent run is *what it did*, not just what it said. These items are that
/// timeline, kept separate from [AiMessage] so the chat transcript stays a
/// plain role/content list.
sealed class AgentItem {
  const AgentItem();
}

class AgentUserItem extends AgentItem {
  const AgentUserItem(this.text);
  final String text;
}

/// Assistant prose: either a remark before a tool round or the final answer.
class AgentAnswerItem extends AgentItem {
  const AgentAnswerItem(this.text);
  final String text;
}

/// Non-fatal information from the loop (step cap, dropped calls).
class AgentNoticeItem extends AgentItem {
  const AgentNoticeItem(this.text);
  final String text;
}

/// Synthetic "the model is thinking" row. Not part of [items]: the screen
/// appends it while `running` and no tool call is in flight, so the user can
/// tell a slow model from a stuck one. Between two tool rounds — the longest
/// silent stretch in a run — this is the only thing on screen.
class AgentWorkingItem extends AgentItem {
  const AgentWorkingItem();
}

/// One tool call. `result == null` means it is still running.
class AgentToolItem extends AgentItem {
  const AgentToolItem({
    required this.name,
    required this.arguments,
    this.result,
    this.isError = false,
  });

  final String name;
  final Map<String, dynamic> arguments;
  final String? result;
  final bool isError;

  bool get running => result == null;

  /// The argument worth showing in the collapsed row — a path beats a JSON blob.
  String get subject {
    for (final key in const ['path', 'title', 'pattern', 'url', 'query']) {
      final value = arguments[key];
      if (value is String && value.trim().isNotEmpty) return value.trim();
    }
    return '';
  }

  AgentToolItem finish(String content, {required bool error}) => AgentToolItem(
        name: name,
        arguments: arguments,
        result: content,
        isError: error,
      );
}

class AgentChatState {
  const AgentChatState({
    this.items = const [],
    this.running = false,
    this.error,
  });

  final List<AgentItem> items;
  final bool running;
  final String? error;

  bool get isEmpty => items.isEmpty;

  static const Object _unset = Object();

  AgentChatState copyWith({
    List<AgentItem>? items,
    bool? running,
    Object? error = _unset,
  }) {
    return AgentChatState(
      items: items ?? this.items,
      running: running ?? this.running,
      error: identical(error, _unset) ? this.error : error as String?,
    );
  }
}

/// Decide whether a write may happen. Answering false is not a failure: the
/// model is told the user declined, and can propose something else.
typedef AgentApprover = Future<bool> Function(
    AgentTool tool, Map<String, dynamic> arguments);

/// Drives [AgentRunner] and turns its events into timeline items.
///
/// The runner is recreated per turn on purpose: a stale one would keep the old
/// endpoint after the user edits the AI settings mid-conversation.
class AgentChatNotifier extends StateNotifier<AgentChatState> {
  AgentChatNotifier({
    required AiConfig Function() readConfig,
    required String? Function() readVaultPath,
    required Future<void> Function() onVaultChanged,
  })  : _readConfig = readConfig,
        _readVaultPath = readVaultPath,
        _onVaultChanged = onVaultChanged,
        super(const AgentChatState()) {
    _restore();
  }

  final AiConfig Function() _readConfig;
  final String? Function() _readVaultPath;
  final Future<void> Function() _onVaultChanged;

  AgentRunner? _runner;
  Note? _activeNote;
  bool _stopped = false;
  bool _wrote = false;

  /// Whether the newest timeline item is an answer that is still being typed
  /// out. Deltas append to it; anything else (a tool card, a whole answer, a
  /// new question) closes it so the next delta starts a fresh bubble.
  bool _answerOpen = false;

  /// The transcript of the whole conversation so far, replayed at the start of
  /// every follow-up turn.
  ///
  /// This used to be kept only for a literal "继续": any other message started
  /// from zero, so "那第二点呢" reached the model as a brand-new conversation
  /// with no idea what "第二点" referred to. Every turn now continues the same
  /// transcript, which is what makes the phone feel like the desktop panel.
  /// Null until the first successful run.
  List<Map<String, dynamic>>? _transcript;

  /// Signature of the note body that was last put into the prompt. A follow-up
  /// on the same note must not re-upload 12k characters; a different (or
  /// edited) note must.
  String? _contextSignature;

  /// The note the user came from, sent as context so the model does not have to
  /// spend a tool round re-reading what is already on screen.
  void attachActiveNote(Note? note) => _activeNote = note;

  /// Brings back the timeline and the transcript after a restart, so reopening
  /// the app continues yesterday's thread instead of showing an empty panel.
  Future<void> _restore() async {
    final saved = await AiSessionStore.loadAgent();
    if (saved == null || !mounted) return;

    final items = <AgentItem>[];
    for (final json in saved.items) {
      final item = _decodeItem(json);
      if (item != null) items.add(item);
    }
    if (items.isEmpty && saved.transcript == null) return;

    _transcript = saved.transcript;
    // The note may have been edited while the app was closed, so the first
    // turn after a restart always restates it rather than trusting the body
    // that was in context when the session was written.
    _contextSignature = null;
    state = state.copyWith(items: items);
  }

  Future<void> _persist() async {
    final items = <Map<String, dynamic>>[];
    for (final item in state.items) {
      final json = _encodeItem(item);
      if (json != null) items.add(json);
    }
    await AiSessionStore.saveAgent(items: items, transcript: _transcript);
  }

  Future<void> send(String question, {AgentApprover? approve}) async {
    final text = question.trim();
    if (text.isEmpty || state.running) return;

    final config = _readConfig();
    if (!config.isUsable) {
      state = state.copyWith(error: '还没配置 AI 服务。点右上角齿轮填接口地址和模型名。');
      return;
    }
    if (config.protocol != AiProtocol.openai) {
      state = state.copyWith(
        error: 'Agent 模式需要 OpenAI 兼容接口。当前服务商不支持，切回问答模式即可。',
      );
      return;
    }
    if (config.needsKey && config.apiKey.trim().isEmpty) {
      state = state.copyWith(error: '还没填 API Key。点右上角齿轮配置。');
      return;
    }
    final vaultPath = _readVaultPath();
    if (vaultPath == null) {
      state = state.copyWith(error: '知识库还没打开。');
      return;
    }

    // Only restate the open note when it is new or was edited since it was
    // last sent. Re-sending it on every follow-up would spend the context
    // budget on the same 12k characters and push the conversation out.
    final signature =
        config.includeNoteContext ? _signatureOf(_activeNote) : null;
    final contextChanged = signature != null && signature != _contextSignature;
    final history = (_transcript?.isNotEmpty ?? false) ? _transcript : null;

    final runner = AgentRunner(
      vault: VaultService(vaultPath),
      config: config,
      maxSteps: 12,
      outputTemplate: config.outputTemplate,
      searchApiKey: config.searchApiKey,
      searchProvider: config.searchProvider,
      // Rate-limit retries happen while the event stream is parked inside an
      // await, so they cannot arrive as an event. Surfacing them here is the
      // difference between "waiting" and "frozen".
      onNotice: (message) {
        if (!mounted) return;
        state = state.copyWith(
          items: [...state.items, AgentNoticeItem(message)],
        );
      },
      // No approver means no writes: appearing to "ask the model to change a
      // file" and having it change silently is the one failure mode this
      // feature must not have.
      approve: (tool, args) async {
        final decide = approve;
        final ok = decide == null ? false : await decide(tool, args);
        // Only an approved write can have touched the disk; a refusal must not
        // trigger a pointless full reload of the vault.
        if (ok) _wrote = true;
        return ok;
      },
    );
    _runner = runner;
    _stopped = false;
    _wrote = false;
    // A new question always starts a new bubble, even if the previous answer
    // was cut off mid-sentence.
    _answerOpen = false;

    state = state.copyWith(
      items: [...state.items, AgentUserItem(text)],
      running: true,
      error: null,
    );

    var completed = false;
    try {
      await for (final event in runner.run(
        text,
        noteContext: contextChanged ? _noteContext(config) : null,
        // Every turn continues the same transcript. "继续" no longer needs its
        // own code path: it is just another follow-up now.
        history: history,
      )) {
        if (_stopped) break;
        _apply(event);
      }
      completed = true;
    } on AgentException catch (error) {
      if (!_stopped && mounted) state = state.copyWith(error: error.message);
    } catch (error) {
      if (!_stopped && mounted) {
        state = state.copyWith(error: '出错了：$error');
      }
    } finally {
      _runner = null;
      // Commit the transcript only when the turn actually went through. A run
      // that never reached the endpoint would otherwise be remembered as an
      // unanswered user message — and the note would be marked as already sent
      // even though the model never saw it.
      if (completed) {
        _transcript = runner.lastMessages;
        if (contextChanged) _contextSignature = signature;
        await _persist();
      }
      if (mounted) state = state.copyWith(running: false);
      // Anything the model changed must show up in the note list immediately;
      // otherwise the user edits a file that looks untouched. The transcript
      // is kept either way — the error bar above it explains the failure.
      if (_wrote && mounted) await _onVaultChanged();
      _wrote = false;
    }
  }

  void _apply(AgentEvent event) {
    if (!mounted) return;
    final items = [...state.items];
    switch (event) {
      case AgentText(:final text):
        if (text.trim().isEmpty) return;
        items.add(AgentAnswerItem(text.trim()));
        _answerOpen = false;
      case AgentTextDelta(:final text):
        if (text.isEmpty) return;
        // Grow the bubble that is already on screen while the answer arrives.
        // A new bubble starts after a tool round, so "我先查一下" and the final
        // answer stay separate instead of being glued together.
        if (_answerOpen && items.isNotEmpty && items.last is AgentAnswerItem) {
          final last = items.removeLast() as AgentAnswerItem;
          items.add(AgentAnswerItem(last.text + text));
        } else {
          items.add(AgentAnswerItem(text));
          _answerOpen = true;
        }
      case AgentNotice(:final text):
        items.add(AgentNoticeItem(text));
      case AgentToolStarted(:final name, :final arguments):
        _answerOpen = false;
        items.add(AgentToolItem(name: name, arguments: arguments));
      case AgentToolFinished(:final name, :final content, :final isError):
        // Events arrive in call order, so the newest still-running item with
        // this name is the one that just finished.
        for (var i = items.length - 1; i >= 0; i--) {
          final item = items[i];
          if (item is AgentToolItem && item.running && item.name == name) {
            items[i] = item.finish(content, error: isError);
            break;
          }
        }
      case AgentFinished():
        break;
    }
    state = state.copyWith(items: items);
  }

  /// Stops the loop. The in-flight HTTP request is not aborted mid-body (dart:io
  /// gives no clean way to interrupt a response read), but its result is thrown
  /// away and no further tool runs.
  void stop() {
    _stopped = true;
    _runner?.cancel();
    _runner = null;
    _answerOpen = false;
    if (!mounted) return;
    final items = [...state.items];
    for (var i = items.length - 1; i >= 0; i--) {
      final item = items[i];
      if (item is AgentToolItem && item.running) {
        items[i] = item.finish('已停止。', error: false);
      }
    }
    items.add(const AgentNoticeItem('已停止。'));
    state = state.copyWith(items: items, running: false);
  }

  void clear() {
    _stopped = true;
    _runner?.cancel();
    _runner = null;
    // A cleared panel is a new conversation: keeping the transcript would make
    // the model answer the first question of the new chat with the old context.
    _transcript = null;
    _contextSignature = null;
    _answerOpen = false;
    state = const AgentChatState();
    unawaited(AiSessionStore.clearAgent());
  }

  void clearError() {
    if (state.error == null) return;
    state = state.copyWith(error: null);
  }

  /// What identifies the exact note body that was last sent. Path alone is not
  /// enough: the point of re-sending is that the user edited the note between
  /// two questions. Length is a cheap proxy for "it changed" and, unlike a
  /// content hash, costs nothing to compute on a phone.
  static String? _signatureOf(Note? note) {
    if (note == null) return null;
    return '${note.relativePath}|${note.body.length}';
  }

  /// The active note as prompt context, truncated the same way Chat mode does,
  /// so a 40k-character note does not crowd out the conversation.
  String? _noteContext(AiConfig config) {
    final note = _activeNote;
    if (note == null || !config.includeNoteContext) return null;
    final body = note.body;
    final head = body.length > 12000
        ? '${body.substring(0, 12000)}\n\n…（后面还有 ${body.length - 12000} 字符，需要时用 read_note 读）'
        : body;
    return '《${note.title}》（${note.relativePath}）\n$head';
  }

  @override
  void dispose() {
    _stopped = true;
    _runner?.cancel();
    super.dispose();
  }
}

/// Timeline item ⇄ JSON, so a conversation survives being killed.
///
/// [AgentWorkingItem] is synthetic ("正在思考…") and is never persisted: a
/// restored panel showing it would look like a run stuck forever.
Map<String, dynamic>? _encodeItem(AgentItem item) {
  switch (item) {
    case AgentUserItem(:final text):
      return {'kind': 'user', 'text': text};
    case AgentAnswerItem(:final text):
      return {'kind': 'answer', 'text': text};
    case AgentNoticeItem(:final text):
      return {'kind': 'notice', 'text': text};
    case AgentToolItem(:final name, :final arguments, :final result, :final isError):
      return {
        'kind': 'tool',
        'name': name,
        'arguments': arguments,
        // A card that was mid-flight when the app died comes back as
        // interrupted; leaving it null would restore a spinner that never stops.
        'result': result ?? '（应用关闭时中断）',
        'isError': isError,
      };
    case AgentWorkingItem():
      return null;
  }
}

AgentItem? _decodeItem(Map<String, dynamic> json) {
  final text = (json['text'] ?? '').toString();
  switch (json['kind']) {
    case 'user':
      return text.isEmpty ? null : AgentUserItem(text);
    case 'answer':
      return text.isEmpty ? null : AgentAnswerItem(text);
    case 'notice':
      return text.isEmpty ? null : AgentNoticeItem(text);
    case 'tool':
      final args = json['arguments'];
      return AgentToolItem(
        name: (json['name'] ?? '').toString(),
        arguments: args is Map
            ? Map<String, dynamic>.from(args)
            : const <String, dynamic>{},
        result: (json['result'] ?? '').toString(),
        isError: json['isError'] == true,
      );
    default:
      return null;
  }
}

final agentChatProvider =
    StateNotifierProvider<AgentChatNotifier, AgentChatState>((ref) {
  return AgentChatNotifier(
    readConfig: () => ref.read(aiChatProvider).config,
    readVaultPath: () => ref.read(vaultProvider).config?.vaultPath,
    onVaultChanged: () => ref.read(vaultProvider.notifier).refresh(),
  );
});
