import 'dart:async';
import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../models/ai_config.dart';
import '../models/note.dart';
import '../services/ai_context.dart';
import '../services/ai_service.dart';
import '../services/ai_session_store.dart';

/// Immutable snapshot of the assistant panel.
class AiChatState {
  const AiChatState({
    this.config = const AiConfig(),
    this.messages = const [],
    this.streaming = false,
    this.error,
    this.contextLabel = '',
    this.attachedNoteTitle,
    this.loaded = false,
  });

  final AiConfig config;
  final List<AiMessage> messages;
  final bool streaming;
  final String? error;
  final String contextLabel;
  final String? attachedNoteTitle;
  final bool loaded;

  bool get isEmpty => messages.isEmpty;

  AiChatState copyWith({
    AiConfig? config,
    List<AiMessage>? messages,
    bool? streaming,
    Object? error = _unset,
    String? contextLabel,
    Object? attachedNoteTitle = _unset,
    bool? loaded,
  }) {
    return AiChatState(
      config: config ?? this.config,
      messages: messages ?? this.messages,
      streaming: streaming ?? this.streaming,
      error: identical(error, _unset) ? this.error : error as String?,
      contextLabel: contextLabel ?? this.contextLabel,
      attachedNoteTitle: identical(attachedNoteTitle, _unset)
          ? this.attachedNoteTitle
          : attachedNoteTitle as String?,
      loaded: loaded ?? this.loaded,
    );
  }

  static const Object _unset = Object();
}

/// Owns the conversation and the endpoint configuration.
///
/// The conversation is restored from [AiSessionStore] on launch and written
/// back after every finished turn, so closing the app no longer throws away a
/// thread the user was in the middle of.
class AiChatNotifier extends StateNotifier<AiChatState> {
  AiChatNotifier() : super(const AiChatState()) {
    _loadConfig();
  }

  static const _kConfig = 'ai_config';

  StreamSubscription<String>? _subscription;
  Note? _activeNote;
  List<Note> _vaultNotes = const [];

  Future<void> _loadConfig() async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(_kConfig);
    AiConfig config = const AiConfig();
    if (raw != null && raw.isNotEmpty) {
      try {
        final decoded = jsonDecode(raw);
        if (decoded is Map) {
          config = AiConfig.fromMap(Map<String, Object?>.from(decoded));
        }
      } catch (_) {
        // A corrupt blob must not brick the panel; fall back to defaults.
      }
    }
    if (!mounted) return;
    state = state.copyWith(config: config, loaded: true, contextLabel: _label());

    // Restore the last conversation, but never over one that is already on
    // screen (the panel can outlive a config reload).
    if (state.messages.isNotEmpty) return;
    final saved = await AiSessionStore.loadChat();
    if (saved == null || saved.isEmpty || !mounted) return;
    state = state.copyWith(messages: saved);
  }

  /// Writes the transcript back. Best-effort and fire-and-forget: the answer
  /// is already on screen, and a failed save must not surface as an error.
  void _persist() {
    unawaited(AiSessionStore.saveChat(state.messages));
  }

  Future<void> saveConfig(AiConfig config) async {
    state = state.copyWith(config: config, contextLabel: _label(), error: null);
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_kConfig, jsonEncode(config.toMap()));
  }

  /// Tells the panel which note (if any) the user came from, so the prompt can
  /// include it. Called by the screen on open.
  void attachContext({Note? note, List<Note> notes = const []}) {
    _activeNote = note;
    _vaultNotes = notes;
    state = state.copyWith(
      attachedNoteTitle: note?.title,
      contextLabel: _label(),
    );
  }

  String _label() => AiContext.scopeLabel(
        config: state.config,
        activeNote: _activeNote,
        vaultNotes: _vaultNotes,
      );

  Future<void> send(String question) async {
    final text = question.trim();
    if (text.isEmpty || state.streaming) return;

    if (!state.config.isUsable) {
      state = state.copyWith(
        error: '还没配置 AI 服务。点右上角齿轮填接口地址和模型名。',
      );
      return;
    }
    if (state.config.needsKey && state.config.apiKey.trim().isEmpty) {
      state = state.copyWith(error: '还没填 API Key。点右上角齿轮配置。');
      return;
    }

    final history = [...state.messages];
    final messages = AiContext.build(
      config: state.config,
      history: history,
      question: text,
      activeNote: state.config.includeNoteContext ? _activeNote : null,
      vaultNotes: state.config.includeNoteContext ? _vaultNotes : const [],
    );

    final pending = [
      ...history,
      AiMessage(role: 'user', content: text),
      const AiMessage(role: 'assistant', content: ''),
    ];
    state = state.copyWith(
      messages: pending,
      streaming: true,
      error: null,
      contextLabel: _label(),
    );

    final service = AiService(state.config);
    final buffer = StringBuffer();

    _subscription = service.streamChat(messages).listen(
      (chunk) {
        buffer.write(chunk);
        _replaceLast(buffer.toString());
      },
      onError: (Object error) {
        final message =
            error is AiException ? error.message : '请求失败：$error';
        final detail = error is AiException ? error.detail : null;
        _finishWithError(message, detail);
      },
      onDone: () {
        _subscription = null;
        if (!mounted) return;
        if (buffer.isEmpty) {
          _finishWithError('模型没有返回任何内容。可能是模型名不对，或该接口不支持流式输出。', null);
          return;
        }
        state = state.copyWith(streaming: false);
        _persist();
      },
      cancelOnError: true,
    );
  }

  /// Aborts the in-flight request. The subscription's cancel path closes the
  /// socket, so the server stops generating.
  void stop() {
    _subscription?.cancel();
    _subscription = null;
    if (!mounted) return;
    final messages = [...state.messages];
    if (messages.isNotEmpty && messages.last.role == 'assistant') {
      if (messages.last.content.trim().isEmpty) {
        messages.removeLast();
      } else {
        messages[messages.length - 1] =
            messages.last.copyWith(content: '${messages.last.content}\n\n_(已停止)_');
      }
    }
    state = state.copyWith(messages: messages, streaming: false);
    _persist();
  }

  void clear() {
    stop();
    state = state.copyWith(messages: const [], error: null);
    unawaited(AiSessionStore.clearChat());
  }

  void clearError() {
    if (state.error == null) return;
    state = state.copyWith(error: null);
  }

  void _replaceLast(String content) {
    if (!mounted) return;
    final messages = [...state.messages];
    if (messages.isEmpty) return;
    messages[messages.length - 1] =
        messages.last.copyWith(content: content, error: false);
    state = state.copyWith(messages: messages);
  }

  void _finishWithError(String message, String? detail) {
    if (!mounted) return;
    final messages = [...state.messages];
    // Replace the empty placeholder with the error bubble, unless the model
    // already streamed something — then keep the partial answer and surface
    // the error separately so the user does not lose what arrived.
    if (messages.isNotEmpty &&
        messages.last.role == 'assistant' &&
        messages.last.content.trim().isEmpty) {
      messages.removeLast();
    }
    state = state.copyWith(
      messages: messages,
      streaming: false,
      error: detail == null || detail.isEmpty ? message : '$message\n\n$detail',
    );
    _persist();
  }

  @override
  void dispose() {
    _subscription?.cancel();
    super.dispose();
  }
}

final aiChatProvider =
    StateNotifierProvider<AiChatNotifier, AiChatState>((ref) {
  return AiChatNotifier();
});
