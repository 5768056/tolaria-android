import 'package:flutter/material.dart';
import 'package:flutter_markdown/flutter_markdown.dart';

import '../services/markdown_service.dart';

/// Renders note Markdown, turning `[[wikilinks]]` into tappable links.
class NoteMarkdown extends StatelessWidget {
  final String body;
  final void Function(String target) onWikilinkTap;

  const NoteMarkdown({
    super.key,
    required this.body,
    required this.onWikilinkTap,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final data = MarkdownService.preprocessWikilinks(body);

    return MarkdownBody(
      data: data,
      selectable: true,
      onTapLink: (text, href, title) {
        if (href == null) return;
        final target = MarkdownService.decodeWikilinkHref(href);
        if (target != null) onWikilinkTap(target);
      },
      styleSheet: MarkdownStyleSheet.fromTheme(theme).copyWith(
        h1: theme.textTheme.headlineSmall?.copyWith(fontWeight: FontWeight.w700),
        h2: theme.textTheme.titleLarge?.copyWith(fontWeight: FontWeight.w700),
        h3: theme.textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w600),
        blockSpacing: 12,
        code: theme.textTheme.bodyMedium?.copyWith(
          fontFamily: 'monospace',
          backgroundColor: theme.colorScheme.surfaceContainerHighest,
        ),
        codeblockDecoration: BoxDecoration(
          color: theme.colorScheme.surfaceContainerHighest,
          borderRadius: BorderRadius.circular(8),
        ),
        blockquoteDecoration: BoxDecoration(
          color: theme.colorScheme.surfaceContainerHighest.withValues(alpha: 0.5),
          border: Border(
            left: BorderSide(color: theme.colorScheme.primary, width: 3),
          ),
        ),
        a: TextStyle(
          color: theme.colorScheme.primary,
          decoration: TextDecoration.underline,
        ),
      ),
    );
  }
}
