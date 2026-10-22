import 'package:path/path.dart' as p;
import 'package:yaml/yaml.dart';

/// Result of splitting a raw `.md` file into YAML frontmatter + body.
class ParsedNote {
  final Map<String, dynamic> frontmatter;
  final String body;
  const ParsedNote(this.frontmatter, this.body);
}

/// Tolaria-compatible Markdown helpers.
///
/// Tolaria keeps notes as plain Markdown with optional YAML frontmatter and
/// `[[wikilinks]]` inside the body. Nothing here is proprietary.
class MarkdownService {
  /// Split a raw file into frontmatter map + body.
  ///
  /// Accepts both `\n` and `\r\n` line endings and tolerates a leading BOM.
  static ParsedNote parse(String raw) {
    var text = raw;
    if (text.startsWith('\uFEFF')) text = text.substring(1);

    if (text.startsWith('---')) {
      final lines = text.split('\n');
      if (lines.isNotEmpty && lines.first.trim() == '---') {
        var end = -1;
        for (var i = 1; i < lines.length; i++) {
          // The closing fence must start at column 0. Tolaria's own type
          // definitions embed a YAML block scalar (`template: |`) whose lines
          // are indented and may contain `---`; trimming before comparing ends
          // the frontmatter early and leaks "type: Note" into the body.
          final line = lines[i].replaceAll('\r', '');
          if (line == '---' || line == '...') {
            end = i;
            break;
          }
        }
        if (end != -1) {
          final yamlStr = lines.sublist(1, end).join('\n').trim();
          final body = lines.sublist(end + 1).join('\n');
          return ParsedNote(_decodeYaml(yamlStr), body);
        }
      }
    }
    return ParsedNote(const {}, text);
  }

  static Map<String, dynamic> _decodeYaml(String yamlStr) {
    if (yamlStr.isEmpty) return const {};
    try {
      final decoded = loadYaml(yamlStr);
      if (decoded is Map) {
        final out = <String, dynamic>{};
        decoded.forEach((key, value) {
          out[key.toString()] = value is YamlNode ? value.value : value;
        });
        return out;
      }
    } catch (_) {
      // Malformed frontmatter is tolerated: treat as plain body-less note.
    }
    return const {};
  }

  /// Human-readable title for a note.
  static String deriveTitle(
    Map<String, dynamic> frontmatter,
    String body,
    String relativePath,
  ) {
    final fmTitle = frontmatter['title'];
    if (fmTitle != null && fmTitle.toString().trim().isNotEmpty) {
      return fmTitle.toString().trim();
    }
    final h1 = RegExp(r'^#\s+(.+)$', multiLine: true).firstMatch(body);
    if (h1 != null) {
      final t = h1.group(1)!.trim();
      if (t.isNotEmpty) return t;
    }
    return p.basenameWithoutExtension(relativePath);
  }

  /// Extract `[[Link]]` / `[[Link|alias]]` targets from a body.
  static List<String> extractWikilinks(String body) {
    final links = <String>[];
    for (final m in RegExp(r'\[\[([^\]]+)\]\]').allMatches(body)) {
      links.add(m.group(1)!.split('|').first.trim());
    }
    return links;
  }

  /// Convert `[[Target]]` and `[[Target|Alias]]` into standard Markdown links
  /// using a custom `wikilink:` scheme that the Markdown widget intercepts.
  static String preprocessWikilinks(String body) {
    return body.replaceAllMapped(RegExp(r'\[\[([^\]]+)\]\]'), (m) {
      final inner = m.group(1)!.trim();
      final parts = inner.split('|');
      final target = parts.first.trim();
      final label = parts.length > 1 ? parts[1].trim() : target;
      final encoded = Uri.encodeComponent(target);
      return '[$label](wikilink:$encoded)';
    });
  }

  /// Convert a `wikilink:` href back into a note target string.
  static String? decodeWikilinkHref(String href) {
    const prefix = 'wikilink:';
    if (!href.startsWith(prefix)) return null;
    return Uri.decodeComponent(href.substring(prefix.length));
  }
}
