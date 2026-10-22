import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

import '../models/ai_config.dart';

/// Keeps the AI panel's conversation across app restarts.
///
/// The desktop app writes every AI conversation to disk
/// (`ai-workspace-sessions.json`) and can reopen an old one; the phone used to
/// keep its panel in memory only, so killing the app silently threw away the
/// thread the user was in the middle of.
///
/// Two independent keys, one per mode. They are written from two different
/// notifiers on their own schedules, and a single document would mean one mode
/// overwriting the other's turn whenever both had something to save.
///
/// This layer only moves JSON around: the shape of an agent timeline item is
/// [AgentItem]'s business, so the encoding lives in `agent_provider.dart` next
/// to the type it decodes.
///
/// Persistence is a convenience, never a precondition. Every call is
/// best-effort, because a corrupt or unavailable store must not stop the panel
/// from answering — and that is also what keeps widget tests, which have no
/// plugin channels, from having to care about it.
class AiSessionStore {
  static const _agentKey = 'ai_session_agent_v1';
  static const _chatKey = 'ai_session_chat_v1';

  /// Caps that keep a long-running conversation from turning into a megabyte
  /// of JSON on every save. The transcript is pruned again on the way to the
  /// model, so dropping the oldest messages here loses nothing it would use.
  static const int _maxItems = 120;
  static const int _maxTranscript = 60;

  static Future<void> saveAgent({
    required List<Map<String, dynamic>> items,
    required List<Map<String, dynamic>>? transcript,
  }) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(
        _agentKey,
        jsonEncode(<String, Object?>{
          'savedAt': DateTime.now().toIso8601String(),
          'items': _tail(items, _maxItems),
          'transcript': transcript == null
              ? null
              : _tail(transcript, _maxTranscript),
        }),
      );
    } catch (_) {
      // No store, no problem: the panel keeps working for this session.
    }
  }

  static Future<
      ({
        List<Map<String, dynamic>> items,
        List<Map<String, dynamic>>? transcript,
      })?> loadAgent() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final raw = prefs.getString(_agentKey);
      if (raw == null || raw.isEmpty) return null;
      final decoded = jsonDecode(raw);
      if (decoded is! Map) return null;

      final items = [
        for (final entry in (decoded['items'] as List? ?? const []))
          if (entry is Map) Map<String, dynamic>.from(entry),
      ];
      final rawTranscript = decoded['transcript'];
      final transcript = rawTranscript is List
          ? [
              for (final m in rawTranscript)
                if (m is Map) Map<String, dynamic>.from(m),
            ]
          : null;
      if (items.isEmpty && transcript == null) return null;
      return (items: items, transcript: transcript);
    } catch (_) {
      return null;
    }
  }

  static Future<void> saveChat(List<AiMessage> messages) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(
        _chatKey,
        jsonEncode(<String, Object?>{
          'savedAt': DateTime.now().toIso8601String(),
          'messages': [
            for (final m in _tail(messages, _maxItems)) m.toMap(),
          ],
        }),
      );
    } catch (_) {
      // See saveAgent.
    }
  }

  static Future<List<AiMessage>?> loadChat() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final raw = prefs.getString(_chatKey);
      if (raw == null || raw.isEmpty) return null;
      final decoded = jsonDecode(raw);
      if (decoded is! Map) return null;
      final rawMessages = decoded['messages'];
      if (rawMessages is! List || rawMessages.isEmpty) return null;
      return [
        for (final m in rawMessages)
          if (m is Map) AiMessage.fromMap(Map<String, Object?>.from(m)),
      ];
    } catch (_) {
      return null;
    }
  }

  static Future<void> clearAgent() => _remove(_agentKey);
  static Future<void> clearChat() => _remove(_chatKey);

  static Future<void> _remove(String key) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.remove(key);
    } catch (_) {
      // See saveAgent.
    }
  }

  static List<T> _tail<T>(List<T> list, int max) =>
      list.length <= max ? list : list.sublist(list.length - max);
}
