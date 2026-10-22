import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:yaml/yaml.dart';

import '../models/note.dart';
import '../models/note_filter.dart';

/// One entry of the sidebar's "类型" section.
///
/// Tolaria declares note types with a Markdown file whose frontmatter is
/// `type: Type` (e.g. `个人成长.md` with `_icon` / `_color` / `_order`). The
/// label, icon and order therefore come from that definition when it exists,
/// and fall back to the raw `type:` value used by the content notes.
class NoteTypeInfo {
  const NoteTypeInfo({
    required this.value,
    required this.label,
    required this.count,
    this.icon,
    this.color,
    this.order = 999,
  });

  /// The value stored in content notes' `type:` field.
  final String value;
  final String label;
  final int count;
  final String? icon;
  final String? color;
  final int order;
}

/// Reads the parts of a Tolaria vault that describe *structure* rather than
/// content: `views/*.yml` (the sidebar's saved views) and the `type:` values
/// carried in each note's frontmatter.
///
/// Both are plain files/directories inside the vault, so nothing here is
/// Tolaria-proprietary — a vault edited on desktop and read here stays in sync.
class VaultIndex {
  const VaultIndex({
    this.views = const [],
    this.types = const [],
    this.typeCounts = const {},
  });

  /// Saved views, already sorted by their `order:` field.
  final List<TolariaView> views;

  /// Note types with their counts, ordered like the desktop sidebar.
  final List<NoteTypeInfo> types;

  /// `type:` value → number of notes (type definitions excluded).
  final Map<String, int> typeCounts;

  static const empty = VaultIndex();

  bool get isEmpty => views.isEmpty && types.isEmpty;

  /// Reads `<vault>/views/*.yml` and aggregates the `type:` fields of [notes].
  static VaultIndex load(String rootPath, List<Note> notes) {
    return VaultIndex(
      views: _loadViews(rootPath),
      types: _buildTypes(notes),
    )._withCounts(notes);
  }

  VaultIndex _withCounts(List<Note> notes) {
    final counts = <String, int>{};
    for (final note in notes) {
      final type = _typeValueOf(note);
      // `type: Type` marks a *definition* of a note type, not content.
      if (type == null || type == 'Type') continue;
      counts[type] = (counts[type] ?? 0) + 1;
    }
    final merged = <NoteTypeInfo>[];
    for (final type in types) {
      merged.add(NoteTypeInfo(
        value: type.value,
        label: type.label,
        count: counts[type.value] ?? 0,
        icon: type.icon,
        color: type.color,
        order: type.order,
      ));
    }
    // Types that have content but no definition file still deserve an entry.
    final known = types.map((t) => t.value).toSet();
    for (final entry in counts.entries) {
      if (known.contains(entry.key)) continue;
      merged.add(NoteTypeInfo(
        value: entry.key,
        label: entry.key,
        count: entry.value,
      ));
    }
    merged.sort((a, b) {
      final byOrder = a.order.compareTo(b.order);
      if (byOrder != 0) return byOrder;
      final byCount = b.count.compareTo(a.count);
      return byCount != 0 ? byCount : a.label.compareTo(b.label);
    });
    return VaultIndex(
      views: views,
      types: merged,
      typeCounts: counts,
    );
  }

  /// Types in sidebar order, empty ones skipped.
  List<NoteTypeInfo> get sortedTypes =>
      types.where((t) => t.count > 0).toList();

  /// Values a note can be moved into — what the "移动到分类" sheet lists.
  ///
  /// A category in Tolaria *is* the `type:` field: the sidebar's views are
  /// saved filters over it (`field: type, op: equals, value: X`). So the only
  /// honest choices are values that already exist somewhere — a declared type
  /// definition, or a value some note actually carries. Views contribute
  /// nothing but the label and colour the user already sees next to them; a
  /// view that filters on some other field is deliberately left out, because
  /// writing `type:` would not put the note in it.
  List<NoteTypeInfo> get categories {
    final byValue = <String, NoteTypeInfo>{};
    for (final type in types) {
      byValue[type.value] = NoteTypeInfo(
        value: type.value,
        label: type.label,
        count: typeCounts[type.value] ?? 0,
        icon: type.icon,
        color: type.color,
        order: type.order,
      );
    }
    for (final entry in typeCounts.entries) {
      byValue.putIfAbsent(
        entry.key,
        () => NoteTypeInfo(
          value: entry.key,
          label: entry.key,
          count: entry.value,
        ),
      );
    }

    for (final view in views) {
      if (view.rules.length != 1) continue;
      final rule = view.rules.single;
      if (rule.field != 'type' || rule.op != 'equals') continue;
      final value = (rule.value ?? '').toString().trim();
      final known = byValue[value];
      if (known == null) continue;
      byValue[value] = NoteTypeInfo(
        value: value,
        label: view.name,
        count: known.count,
        icon: known.icon ?? view.icon,
        // The sidebar dot is what the user recognises, so the view wins when
        // it has a colour of its own.
        color: view.color ?? known.color,
        order: known.order < 999 ? known.order : view.order,
      );
    }

    final list = byValue.values.toList()
      ..sort((a, b) {
        final byOrder = a.order.compareTo(b.order);
        if (byOrder != 0) return byOrder;
        final byCount = b.count.compareTo(a.count);
        return byCount != 0 ? byCount : a.label.compareTo(b.label);
      });
    return list;
  }

  /// Reads `<vault>/views/*.yml`. A missing directory is normal (a vault
  /// without custom views) and yields an empty list.
  static List<TolariaView> _loadViews(String rootPath) {
    final dir = Directory(p.join(rootPath, 'views'));
    if (!dir.existsSync()) return const [];

    final views = <TolariaView>[];
    for (final entity in dir.listSync(followLinks: false)) {
      if (entity is! File) continue;
      final ext = p.extension(entity.path).toLowerCase();
      if (ext != '.yml' && ext != '.yaml') continue;
      try {
        final raw = loadYaml(entity.readAsStringSync());
        if (raw is! Map) continue;
        final filters = raw['filters'];
        final rules = <ViewRule>[];
        if (filters is Map) {
          // Tolaria nests rules under `all:` (AND). `any:` (OR) is not seen in
          // the wild yet; if it appears, everything under it is treated as AND
          // rather than silently dropping the whole view.
          for (final group in filters.values) {
            if (group is List) {
              for (final rule in group) {
                if (rule is Map) rules.add(ViewRule.fromYaml(rule));
              }
            }
          }
        }
        views.add(TolariaView(
          id: p.basenameWithoutExtension(entity.path),
          name: (raw['name'] ?? p.basenameWithoutExtension(entity.path))
              .toString(),
          order: (raw['order'] is num) ? (raw['order'] as num).toInt() : 999,
          rules: rules,
          icon: raw['icon']?.toString(),
          color: raw['color']?.toString(),
        ));
      } catch (_) {
        // A malformed view file must not take the whole sidebar down.
        continue;
      }
    }

    views.sort((a, b) {
      final byOrder = a.order.compareTo(b.order);
      return byOrder != 0 ? byOrder : a.name.compareTo(b.name);
    });
    return views;
  }

  /// Collects `type: Type` definition files into sidebar entries.
  static List<NoteTypeInfo> _buildTypes(List<Note> notes) {
    final types = <NoteTypeInfo>[];
    for (final note in notes) {
      if (_typeValueOf(note) != 'Type') continue;
      final fileName = p.basenameWithoutExtension(note.fileName);
      types.add(NoteTypeInfo(
        // Content notes reference the type by name, which matches the file
        // name of its definition.
        value: fileName,
        label: (note.frontmatter['_sidebar_label'] ?? note.title).toString(),
        count: 0,
        icon: note.frontmatter['_icon']?.toString(),
        color: note.frontmatter['_color']?.toString(),
        order: (note.frontmatter['_order'] is num)
            ? (note.frontmatter['_order'] as num).toInt()
            : 999,
      ));
    }
    return types;
  }

  static String? _typeValueOf(Note note) => note.noteType;
}
