import 'dart:io';

import 'package:path/path.dart' as p;

import '../models/note.dart';
import '../models/note_filter.dart';
import 'frontmatter_editor.dart';
import 'markdown_service.dart';

/// Read/write notes as plain `.md` files inside a local vault directory.
///
/// The vault directory is also a git working tree (`.git` lives alongside the
/// notes), so this service only ever touches Markdown files and never the
/// `.git` internals.
class VaultService {
  final String rootPath;

  VaultService(this.rootPath);

  Directory get root => Directory(rootPath);

  bool get exists => root.existsSync();

  List<Note> loadNotes() {
    final notes = <Note>[];
    if (!root.existsSync()) return notes;

    for (final entity in root.listSync(recursive: true, followLinks: false)) {
      if (entity is! File) continue;
      final rel = p.relative(entity.path, from: rootPath).replaceAll('\\', '/');
      if (_isGitPath(rel)) continue;
      if (p.extension(entity.path).toLowerCase() != '.md') continue;

      final raw = entity.readAsStringSync();
      final parsed = MarkdownService.parse(raw);
      notes.add(Note(
        relativePath: rel,
        title: MarkdownService.deriveTitle(parsed.frontmatter, parsed.body, rel),
        frontmatter: parsed.frontmatter,
        body: parsed.body,
        modified: entity.statSync().modified,
      ));
    }

    notes.sort((a, b) {
      final am = a.modified ?? DateTime.fromMillisecondsSinceEpoch(0);
      final bm = b.modified ?? DateTime.fromMillisecondsSinceEpoch(0);
      return bm.compareTo(am);
    });
    return notes;
  }

  Note? findNote(String relativePath) {
    final file = File(p.join(rootPath, relativePath));
    if (!file.existsSync()) return null;
    final raw = file.readAsStringSync();
    final parsed = MarkdownService.parse(raw);
    return Note(
      relativePath: relativePath,
      title: MarkdownService.deriveTitle(parsed.frontmatter, parsed.body, relativePath),
      frontmatter: parsed.frontmatter,
      body: parsed.body,
      modified: file.statSync().modified,
    );
  }

  /// Resolve a `[[wikilink]]` target to a note.
  ///
  /// Matches, in order: exact relative path, filename without extension, then
  /// case-insensitive title. Returns null when nothing matches.
  Note? resolveWikilink(String target, List<Note> notes) {
    final normalized = target.trim();
    if (normalized.isEmpty) return null;

    final exact = _firstWhereOrNull(notes, (n) => n.relativePath == normalized);
    if (exact != null) return exact;

    final withMd = _firstWhereOrNull(
      notes,
      (n) => n.fileName.toLowerCase() == '$normalized.md'.toLowerCase(),
    );
    if (withMd != null) return withMd;

    final byName = _firstWhereOrNull(
      notes,
      (n) =>
          p.basenameWithoutExtension(n.fileName).toLowerCase() ==
          normalized.toLowerCase(),
    );
    if (byName != null) return byName;

    return _firstWhereOrNull(
      notes,
      (n) => n.title.toLowerCase() == normalized.toLowerCase(),
    );
  }

  static Note? _firstWhereOrNull(
    Iterable<Note> items,
    bool Function(Note note) test,
  ) {
    for (final note in items) {
      if (test(note)) return note;
    }
    return null;
  }

  void saveNote(Note note) {
    final file = File(p.join(rootPath, note.relativePath));
    file.parent.createSync(recursive: true);
    file.writeAsStringSync(note.toMarkdown());
  }

  /// Create a brand-new note from a title, returning it. Ensures the filename
  /// is unique by appending a numeric suffix when needed.
  Note createNote(String title) {
    final base = _slugify(title);
    var candidate = '$base.md';
    var i = 2;
    while (File(p.join(rootPath, candidate)).existsSync()) {
      candidate = '$base-$i.md';
      i++;
    }
    final note = Note(
      relativePath: candidate,
      title: title,
      frontmatter: {'title': title},
      body: '# $title\n\n',
    );
    saveNote(note);
    return note;
  }

  void deleteNote(String relativePath) {
    final file = File(p.join(rootPath, relativePath));
    if (file.existsSync()) file.deleteSync();
  }

  /// Archive or restore a note.
  ///
  /// Tolaria's canonical key is `_archived`; unarchiving removes the field
  /// rather than storing `false`, so a restored note looks like one that was
  /// never archived.
  Note setArchived(String relativePath, bool archived) => _patch(
        relativePath,
        key: '_archived',
        aliases: const ['archived', 'Archived', 'archive', 'is_archived'],
        value: archived ? true : null,
      );

  /// Move a note into [type], or out of every category when [type] is null.
  ///
  /// This is the whole of Tolaria's categorisation model: `type:` plus saved
  /// views that filter on it. Nothing else in the vault needs to change for a
  /// note to appear under the right sidebar entry.
  Note setType(String relativePath, String? type) {
    final trimmed = type?.trim();
    return _patch(
      relativePath,
      key: 'type',
      aliases: const ['is_a', 'Is A'],
      value: (trimmed == null || trimmed.isEmpty) ? null : trimmed,
    );
  }

  /// Rewrite one frontmatter field in place, leaving the body untouched.
  Note _patch(
    String relativePath, {
    required String key,
    required List<String> aliases,
    required Object? value,
  }) {
    final file = File(p.join(rootPath, relativePath));
    if (!file.existsSync()) throw StateError('笔记不存在：$relativePath');
    final raw = file.readAsStringSync();
    final next = FrontmatterEditor.upsert(
      raw,
      key: key,
      aliases: aliases,
      value: value,
    );
    if (next != raw) file.writeAsStringSync(next);
    return findNote(relativePath)!;
  }

  /// Write `views/<slug>.yml` so a brand-new category shows up in the sidebar
  /// on both this app and the desktop one.
  ///
  /// The file is Tolaria's own view format — one `type equals` rule, nothing
  /// proprietary — so creating a category here is the same operation as
  /// creating a view on the desktop.
  TolariaView createCategoryView({
    required String name,
    required int order,
    String? color,
  }) {
    final label = name.trim();
    if (label.isEmpty) throw ArgumentError('分类名不能为空');

    final dir = Directory(p.join(rootPath, 'views'));
    dir.createSync(recursive: true);

    final base = _slugify(label);
    var stem = base;
    var i = 2;
    while (File(p.join(dir.path, '$stem.yml')).existsSync()) {
      stem = '$base-$i';
      i++;
    }

    final buffer = StringBuffer()
      ..writeln('name: ${FrontmatterEditor.formatScalar(label)}')
      ..writeln('order: $order')
      ..writeln('sort: "modified:desc"');
    if (color != null && color.trim().isNotEmpty) {
      buffer.writeln('color: ${FrontmatterEditor.formatScalar(color.trim())}');
    }
    buffer
      ..writeln('filters:')
      ..writeln('  all:')
      ..writeln('    - field: type')
      ..writeln('      op: equals')
      ..writeln('      value: ${FrontmatterEditor.formatScalar(label)}');
    File(p.join(dir.path, '$stem.yml')).writeAsStringSync(buffer.toString());

    return TolariaView(
      id: stem,
      name: label,
      order: order,
      color: color,
      rules: [ViewRule(field: 'type', op: 'equals', value: label)],
    );
  }

  /// Renames a note: moves the file (keeping its folder) and rewrites the
  /// `title` in frontmatter plus the leading `#` heading.
  ///
  /// Wikilinks in other notes are intentionally NOT rewritten — Tolaria has no
  /// rename propagation either, and silently editing dozens of unrelated files
  /// behind the user's back would be worse than a broken link they can see.
  Note renameNote(String relativePath, String newTitle) {
    final title = newTitle.trim();
    if (title.isEmpty) throw ArgumentError('标题不能为空');

    final oldFile = File(p.join(rootPath, relativePath));
    if (!oldFile.existsSync()) throw StateError('笔记不存在：$relativePath');

    final existing = findNote(relativePath);
    final dir = p.dirname(relativePath);
    String candidate(String stem) =>
        (dir == '.' || dir.isEmpty) ? '$stem.md' : '$dir/$stem.md';

    final slug = _slugify(title);
    var newPath = candidate(slug);
    var i = 2;
    while (newPath != relativePath &&
        File(p.join(rootPath, newPath)).existsSync()) {
      newPath = candidate('$slug-$i');
      i++;
    }

    final note = Note(
      relativePath: newPath,
      title: title,
      frontmatter: <String, dynamic>{
        ...?existing?.frontmatter,
        'title': title,
      },
      body: _withHeading(existing?.body ?? '', title),
    );
    saveNote(note);
    if (newPath != relativePath) oldFile.deleteSync();
    return note;
  }

  /// Replace the first `# heading` of a note, or prepend one when missing.
  static String _withHeading(String body, String title) {
    final lines = body.split('\n');
    final headingIndex = lines.indexWhere((l) => l.trim().isNotEmpty);
    if (headingIndex >= 0 && lines[headingIndex].trimLeft().startsWith('#')) {
      lines[headingIndex] = '# $title';
      return lines.join('\n');
    }
    return '# $title\n\n$body';
  }

  static bool _isGitPath(String rel) =>
      rel == '.git' || rel.startsWith('.git/') || rel.contains('/.git/');

  static String _slugify(String title) {
    final slug = title
        .toLowerCase()
        .trim()
        .replaceAll(RegExp(r'[^\w\u4e00-\u9fa5\s-]'), '')
        .replaceAll(RegExp(r'\s+'), '-')
        .replaceAll(RegExp(r'-+'), '-');
    return slug.isEmpty ? 'untitled' : slug;
  }
}
