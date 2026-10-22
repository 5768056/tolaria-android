/// A single note inside a Tolaria vault.
///
/// Tolaria stores every note as a plain Markdown file with optional YAML
/// frontmatter. This app is format-compatible: it never invents a proprietary
/// container, it just reads/writes the same `.md` files on disk.
class Note {
  /// Path relative to the vault root, always using `/` separators.
  final String relativePath;

  final String title;
  final Map<String, dynamic> frontmatter;

  /// Markdown body WITHOUT the frontmatter block.
  final String body;

  final DateTime? modified;

  const Note({
    required this.relativePath,
    required this.title,
    required this.frontmatter,
    required this.body,
    this.modified,
  });

  String get fileName => relativePath.split('/').last;

  /// Archived flag, honouring the spellings Tolaria accepts.
  ///
  /// The canonical key is `_archived` (that is what the desktop app writes),
  /// but older vaults and hand-edited notes use the bare forms too.
  bool get isArchived {
    for (final key in const [
      '_archived',
      'archived',
      'Archived',
      'archive',
      'is_archived',
    ]) {
      final value = frontmatter[key];
      if (value is bool) return value;
      if (value is String) return value.toLowerCase() == 'true';
    }
    return false;
  }

  /// The `type:` value, which is what Tolaria's sidebar views filter on.
  ///
  /// Returns null for notes that carry no type — those are the ones the
  /// sidebar counts as "收件箱" (inbox).
  String? get noteType {
    final raw = frontmatter['type'] ?? frontmatter['is_a'] ?? frontmatter['Is A'];
    if (raw == null) return null;
    final text = raw is Iterable
        ? (raw.isEmpty ? '' : raw.first.toString())
        : raw.toString();
    final trimmed = text.trim();
    return trimmed.isEmpty ? null : trimmed;
  }

  /// Rebuild the on-disk content (frontmatter + body).
  String toMarkdown() {
    if (frontmatter.isEmpty) return body;
    final buffer = StringBuffer();
    buffer.writeln('---');
    frontmatter.forEach((key, value) {
      buffer.writeln('$key: ${_yamlScalar(value)}');
    });
    buffer.writeln('---');
    buffer.write(body);
    return buffer.toString();
  }

  static String _yamlScalar(dynamic value) {
    if (value == null) return 'null';
    if (value is num || value is bool) return value.toString();
    if (value is List) {
      return '[${value.map(_yamlScalar).join(', ')}]';
    }
    final s = value.toString().replaceAll('"', '\\"');
    return '"$s"';
  }
}
