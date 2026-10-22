/// Surgical edits to a note's YAML frontmatter.
///
/// `Note.toMarkdown()` re-serialises the whole metadata block: it reorders
/// keys, forces its own quoting style and flattens block scalars. That is
/// acceptable when the user rewrites a note, but archiving a note or moving it
/// into a category should not rewrite a type definition's `template: |`
/// payload. So these edits patch single lines and leave every other byte of
/// the file — including BOM and CRLF line endings — exactly as it was.
class FrontmatterEditor {
  /// Set [key] to [value], or delete it when [value] is null.
  ///
  /// [aliases] are the other spellings Tolaria accepts for the same field
  /// (`_archived` is also written as `archived` / `Archived`). When one of them
  /// is already present its spelling wins, so a vault that uses a legacy key
  /// keeps using it instead of sprouting a second copy of the field.
  static String upsert(
    String raw, {
    required String key,
    List<String> aliases = const [],
    Object? value,
  }) {
    final hadBom = raw.startsWith('\uFEFF');
    final body = hadBom ? raw.substring(1) : raw;
    final eol = body.contains('\r\n') ? '\r\n' : '\n';

    // Work on `\n`-split lines so indices stay simple, then rejoin with the
    // line ending the file already used.
    final lines = <String>[
      for (final line in body.split('\n'))
        line.endsWith('\r') ? line.substring(0, line.length - 1) : line,
    ];

    final open = lines.isNotEmpty && lines.first.trim() == '---' ? 0 : -1;
    var close = -1;
    if (open == 0) {
      for (var i = 1; i < lines.length; i++) {
        // The closing fence must start at column 0 — the same rule
        // MarkdownService uses, so both agree on where frontmatter ends.
        if (lines[i] == '---' || lines[i] == '...') {
          close = i;
          break;
        }
      }
    }

    final wanted = <String>{
      _normalize(key),
      for (final alias in aliases) _normalize(alias),
    };

    if (close == -1) {
      // No frontmatter yet. Nothing to remove; create a block when setting.
      if (value == null) return raw;
      final block = ['---', '$key: ${formatScalar(value)}', '---'];
      final rebuilt = [...block, ...lines].join(eol);
      return hadBom ? '\uFEFF$rebuilt' : rebuilt;
    }

    var found = -1;
    for (var i = open + 1; i < close; i++) {
      final name = _keyOf(lines[i]);
      if (name == null) continue;
      if (wanted.contains(_normalize(name))) {
        found = i;
        break;
      }
    }

    if (found == -1) {
      if (value == null) return raw;
      // Append at the end of the block, before any trailing blank lines.
      var at = close;
      while (at - 1 > open && lines[at - 1].trim().isEmpty) {
        at--;
      }
      lines.insert(at, '$key: ${formatScalar(value)}');
    } else {
      final end = _blockEnd(lines, found, close);
      final spelling = _keyOf(lines[found]) ?? key;
      if (value == null) {
        lines.removeRange(found, end);
      } else {
        lines.replaceRange(found, end, ['$spelling: ${formatScalar(value)}']);
      }
    }

    final rebuilt = lines.join(eol);
    return hadBom ? '\uFEFF$rebuilt' : rebuilt;
  }

  /// Index just past the last line that belongs to the key starting at [start].
  ///
  /// A key's value continues on indented lines: YAML lists (`  - a`), nested
  /// maps and block scalars (`  template: |`). Blank lines inside a block
  /// scalar are only kept when more indented content follows, so a blank
  /// separator line between two top-level keys is not swallowed.
  static int _blockEnd(List<String> lines, int start, int close) {
    var end = start + 1;
    while (end < close) {
      final line = lines[end];
      if (line.trim().isEmpty) {
        var probe = end + 1;
        while (probe < close && lines[probe].trim().isEmpty) {
          probe++;
        }
        if (probe < close && _isIndented(lines[probe])) {
          end = probe;
          continue;
        }
        return end;
      }
      if (!_isIndented(line)) return end;
      end++;
    }
    return end;
  }

  static bool _isIndented(String line) =>
      line.startsWith(' ') || line.startsWith('\t');

  /// The raw key of a top-level `key: value` line, or null when [line] is not
  /// one (blank, indented, a `- item` sequence entry or a `#` comment).
  static String? _keyOf(String line) {
    if (line.isEmpty || _isIndented(line)) return null;
    if (line.startsWith('#') || line.startsWith('-')) return null;
    final colon = line.indexOf(':');
    if (colon <= 0) return null;
    var name = line.substring(0, colon).trim();
    if (name.length >= 2 &&
        ((name.startsWith('"') && name.endsWith('"')) ||
            (name.startsWith("'") && name.endsWith("'")))) {
      name = name.substring(1, name.length - 1);
    }
    return name.isEmpty ? null : name;
  }

  /// Tolaria treats `Is A` and `is_a` as the same field, so compare that way.
  static String _normalize(String key) =>
      key.trim().toLowerCase().replaceAll(' ', '_');

  /// Render a scalar the way a hand-written vault would: bare where YAML
  /// allows it (Chinese text included), quoted only where it would otherwise
  /// be misread or rejected.
  static String formatScalar(Object value) {
    if (value is bool) return value ? 'true' : 'false';
    if (value is num) return value.toString();
    final text = value.toString();
    if (text.isEmpty) return '""';
    return _needsQuotes(text) ? '"${text.replaceAll('"', '\\"')}"' : text;
  }

  /// Characters that change meaning at the start of a YAML scalar.
  static final _unsafeStart = RegExp(r'''^[\s\-?:,\[\]{}#&*!|>'"%@`]''');
  static final _looksLikeNonString = RegExp(
    r'^(true|false|null|yes|no|on|off|~|-?\d+(\.\d+)?)$',
    caseSensitive: false,
  );

  static bool _needsQuotes(String text) {
    if (_unsafeStart.hasMatch(text)) return true;
    if (text.contains(': ') || text.contains(' #')) return true;
    if (text.endsWith(':') || text.contains('\n') || text.contains('\t')) {
      return true;
    }
    return _looksLikeNonString.hasMatch(text);
  }
}
