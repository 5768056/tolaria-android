import '../models/note.dart';

/// A single filter rule from a Tolaria `views/*.yml` file.
///
/// Tolaria's desktop sidebar is driven by these files, e.g.
///
/// ```yaml
/// name: 自媒体
/// order: 1
/// filters:
///   all:
///     - field: type
///       op: equals
///       value: 自媒体
/// ```
///
/// Supporting the same file format is what makes the Android sidebar show the
/// user's *own* views instead of a hardcoded list.
class ViewRule {
  const ViewRule({required this.field, required this.op, this.value});

  final String field;
  final String op;
  final Object? value;

  factory ViewRule.fromYaml(Map<dynamic, dynamic> raw) {
    return ViewRule(
      field: (raw['field'] ?? '').toString(),
      op: (raw['op'] ?? 'equals').toString(),
      value: raw['value'],
    );
  }

  bool matches(Note note) {
    final actual = note.frontmatter[field];
    switch (op) {
      case 'equals':
        return _stringOf(actual) == _stringOf(value);
      case 'not_equals':
        return _stringOf(actual) != _stringOf(value);
      case 'any_of':
        return _listOf(value).any((v) => _holds(actual, v));
      case 'none_of':
        return !_listOf(value).any((v) => _holds(actual, v));
      case 'contains':
        return _holds(actual, value);
      case 'not_contains':
        return !_holds(actual, value);
      case 'is_empty':
        return actual == null ||
            (actual is Iterable && actual.isEmpty) ||
            _stringOf(actual).isEmpty;
      case 'is_not_empty':
        return !(actual == null ||
            (actual is Iterable && actual.isEmpty) ||
            _stringOf(actual).isEmpty);
      default:
        // Unknown operator: do not filter the note out — showing a note in an
        // unexpected place beats hiding a vault behind a rule we cannot read.
        return true;
    }
  }

  static String _stringOf(Object? value) {
    if (value == null) return '';
    if (value is Iterable) return value.map(_stringOf).join(',');
    return value.toString();
  }

  static List<Object?> _listOf(Object? value) {
    if (value is List) return value;
    if (value == null) return const [];
    return <Object?>[value];
  }

  /// True when [actual] (scalar or list) contains [expected].
  static bool _holds(Object? actual, Object? expected) {
    final needle = _stringOf(expected);
    if (actual is Iterable) {
      return actual.any((item) => _stringOf(item) == needle);
    }
    return _stringOf(actual) == needle;
  }
}

/// A saved view loaded from `views/*.yml`.
class TolariaView {
  const TolariaView({
    required this.id,
    required this.name,
    required this.order,
    required this.rules,
    this.icon,
    this.color,
  });

  /// File name without extension — unique per view.
  final String id;
  final String name;
  final int order;
  final List<ViewRule> rules;
  final String? icon;
  final String? color;

  bool matches(Note note) => rules.every((rule) => rule.matches(note));
}

/// What the note list is currently showing.
class NoteFilter {
  const NoteFilter._(this.kind, this.label, {this.value, this.rules = const []});

  const NoteFilter.all() : this._(NoteFilterKind.all, '全部笔记');

  const NoteFilter.inbox() : this._(NoteFilterKind.inbox, '收件箱');

  const NoteFilter.archive() : this._(NoteFilterKind.archive, '归档');

  factory NoteFilter.type(String type) =>
      NoteFilter._(NoteFilterKind.type, type, value: type);

  factory NoteFilter.view(TolariaView view) => NoteFilter._(
        NoteFilterKind.view,
        view.name,
        value: view.id,
        rules: view.rules,
      );

  final NoteFilterKind kind;

  /// Shown in the app bar while this filter is active.
  final String label;

  /// Type name or view id, depending on [kind].
  final String? value;

  final List<ViewRule> rules;

  List<Note> apply(List<Note> notes) {
    switch (kind) {
      case NoteFilterKind.all:
        return notes;
      case NoteFilterKind.archive:
        return notes.where(_isArchived).toList();
      case NoteFilterKind.inbox:
        return notes.where((n) => _typeOf(n) == null).toList();
      case NoteFilterKind.type:
        return notes.where((n) => _typeOf(n) == value).toList();
      case NoteFilterKind.view:
        // Type definitions themselves are never content.
        return notes
            .where((n) => _typeOf(n) != 'Type' && rules.every((r) => r.matches(n)))
            .toList();
    }
  }

  /// The `type:` field, with Tolaria's "Type" definitions excluded.
  static String? _typeOf(Note note) {
    final type = note.noteType;
    return type == null || type.trim().isEmpty ? null : type.trim();
  }

  static bool _isArchived(Note note) => note.isArchived;

  @override
  bool operator ==(Object other) =>
      other is NoteFilter && other.kind == kind && other.value == value;

  @override
  int get hashCode => Object.hash(kind, value);
}

enum NoteFilterKind { all, inbox, archive, type, view }
