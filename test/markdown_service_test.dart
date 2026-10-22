import 'package:flutter_test/flutter_test.dart';
import 'package:tolaria_android/models/note.dart';
import 'package:tolaria_android/services/markdown_service.dart';

void main() {
  group('MarkdownService.parse', () {
    test('splits YAML frontmatter from the body', () {
      const raw = '---\ntitle: "Hello World"\ntags: [a, b]\n---\n# Heading\n\nbody text\n';
      final parsed = MarkdownService.parse(raw);
      expect(parsed.frontmatter['title'], 'Hello World');
      expect(parsed.body.trim(), '# Heading\n\nbody text');
    });

    test('treats a file without frontmatter as pure body', () {
      final parsed = MarkdownService.parse('# Just a note\n');
      expect(parsed.frontmatter, isEmpty);
      expect(parsed.body, '# Just a note\n');
    });

    test('tolerates a BOM and CRLF line endings', () {
      const raw = '\uFEFF---\r\ntitle: Windows\r\n---\r\nbody\r\n';
      final parsed = MarkdownService.parse(raw);
      expect(parsed.frontmatter['title'], 'Windows');
      expect(parsed.body.contains('body'), isTrue);
    });

    // Tolaria's own type definitions (note.md, Skill.md, …) embed a Markdown
    // template as a YAML block scalar. Those lines are indented and can contain
    // `---`, which must NOT be mistaken for the closing fence — otherwise the
    // note body starts inside the frontmatter and the reader shows YAML.
    test('ignores an indented --- inside a YAML block scalar', () {
      const raw = '---\n'
          'type: Type\n'
          'color: gray\n'
          '_sidebar_label: 笔记\n'
          'template: |\n'
          '  ---\\\n'
          '  \\\n'
          '  type: Note\\\n'
          '  ---\n'
          '---\n'
          '# 笔记\n\n'
          '正文\n';
      final parsed = MarkdownService.parse(raw);
      expect(parsed.frontmatter['type'], 'Type');
      expect(parsed.frontmatter['_sidebar_label'], '笔记');
      expect(parsed.frontmatter.containsKey('template'), isTrue);
      expect(parsed.body.trim(), startsWith('# 笔记'));
      expect(parsed.body.contains('type: Note'), isFalse);
    });

    test('survives malformed frontmatter instead of throwing', () {
      final parsed = MarkdownService.parse('---\n[unclosed\n---\nbody\n');
      expect(parsed.frontmatter, isEmpty);
      expect(parsed.body.contains('body'), isTrue);    });

    test('an unterminated frontmatter block is kept as body', () {
      const raw = '---\ntitle: broken\nno closing fence\n';
      final parsed = MarkdownService.parse(raw);
      expect(parsed.frontmatter, isEmpty);
      expect(parsed.body, raw);
    });
  });

  group('MarkdownService.deriveTitle', () {
    test('prefers frontmatter title', () {
      expect(
        MarkdownService.deriveTitle({'title': 'FM'}, '# H1\n', 'a/b.md'),
        'FM',
      );
    });

    test('falls back to the first H1', () {
      expect(MarkdownService.deriveTitle({}, '# H1\n\ntext', 'a/b.md'), 'H1');
    });

    test('falls back to the file name', () {
      expect(MarkdownService.deriveTitle({}, 'no heading', 'dir/My Note.md'),
          'My Note');
    });
  });

  group('wikilinks', () {
    test('extracts targets including aliases', () {
      final links = MarkdownService.extractWikilinks(
        'see [[Alpha]] and [[Beta|the beta]] and [[Gamma]]',
      );
      expect(links, ['Alpha', 'Beta', 'Gamma']);
    });

    test('round-trips through markdown link syntax', () {
      final md = MarkdownService.preprocessWikilinks('a [[My Note|x]] b');
      expect(md, 'a [x](wikilink:My%20Note) b');
      final href = RegExp(r'\((wikilink:[^)]+)\)').firstMatch(md)!.group(1)!;
      expect(MarkdownService.decodeWikilinkHref(href), 'My Note');
    });

    test('leaves ordinary links untouched', () {
      expect(MarkdownService.decodeWikilinkHref('https://example.com'), isNull);
    });
  });

  group('Note.toMarkdown', () {
    test('writes frontmatter back and keeps the body verbatim', () {
      const note = Note(
        relativePath: 'n.md',
        title: 'T',
        frontmatter: {'title': 'T', 'pinned': true},
        body: '# Body\n',
      );
      final raw = note.toMarkdown();
      expect(raw, startsWith('---\n'));
      expect(raw, contains('title: "T"'));
      expect(raw, contains('pinned: true'));
      expect(raw, endsWith('# Body\n'));
    });

    test('omits the frontmatter block entirely when empty', () {
      const note = Note(
        relativePath: 'n.md',
        title: 'T',
        frontmatter: {},
        body: 'plain\n',
      );
      expect(note.toMarkdown(), 'plain\n');
    });

    test('round-trips through parse()', () {
      const note = Note(
        relativePath: 'n.md',
        title: 'T',
        frontmatter: {'title': 'Round Trip'},
        body: 'body [[Link]]\n',
      );
      final parsed = MarkdownService.parse(note.toMarkdown());
      expect(parsed.frontmatter['title'], 'Round Trip');
      expect(parsed.body, 'body [[Link]]\n');
    });
  });
}
