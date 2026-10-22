import 'dart:io';

import 'package:path/path.dart' as p;

import '../vault_service.dart';

/// The vault's own operating manual, the way a CLI agent would find it.
///
/// Desktop Tolaria runs Claude Code / Codex / opencode *inside* the vault
/// directory, so those tools pick up `AGENTS.md` (and the older spellings
/// `CLAUDE.md` / `GEMINI.md`) on their own and follow the vault's own rules:
/// which frontmatter fields a note carries, what a "Skill" note looks like,
/// which folder new notes belong in.
///
/// The phone has no working directory to inherit — it is an app, not a shell —
/// so that file has to be found and carried into the system prompt explicitly.
/// It is deliberately the *same* file the desktop reads: one manual, both
/// clients. Nothing here ever writes to it.
class ProjectInstructions {
  const ProjectInstructions({
    required this.fileName,
    required this.text,
    required this.truncated,
  });

  /// The file actually used, e.g. `AGENTS.md`.
  final String fileName;

  /// Its content, already capped to [ProjectInstructionsLoader.maxChars].
  final String text;

  /// True when the file was longer than the cap and got cut.
  final bool truncated;
}

/// Reads `AGENTS.md` from the vault root.
class ProjectInstructionsLoader {
  /// Order matters: `AGENTS.md` is the cross-tool convention, the other two are
  /// older spellings a vault may still carry. The first one found wins, exactly
  /// like the CLI agents do it.
  static const List<String> candidates = ['AGENTS.md', 'CLAUDE.md', 'GEMINI.md'];

  /// Roughly 1.5k tokens of Chinese. The manual is re-sent at the start of every
  /// conversation, and the tool schemas plus the vault outline already take a
  /// bite out of the context; a 40k-character manual would push a free-tier
  /// model over its limit before the first question is even asked.
  static const int maxChars = 6000;

  /// The manual for [vault], or null when there is none.
  static ProjectInstructions? load(VaultService vault) {
    if (!vault.exists) return null;
    final file = _find(vault);
    if (file == null) return null;

    final text = file.readAsStringSync().replaceAll('\r\n', '\n').trim();
    if (text.isEmpty) return null;

    final truncated = text.length > maxChars;
    var body = text;
    if (truncated) {
      // Cut on a line boundary when one is close to the cap: half a rule is
      // worse than one rule fewer, and a cut mid-table produces nonsense.
      final cut = text.lastIndexOf('\n', maxChars);
      body = text.substring(0, cut > maxChars * 0.6 ? cut : maxChars);
    }
    return ProjectInstructions(
      fileName: p.basename(file.path),
      text: body,
      truncated: truncated,
    );
  }

  static File? _find(VaultService vault) {
    for (final name in candidates) {
      final exact = File(p.join(vault.rootPath, name));
      if (exact.existsSync()) return exact;
    }

    // Android storage is case-sensitive, but a vault synced from macOS or
    // Windows may spell the file `agents.md`. Only files, never directories:
    // a folder named `AGENTS.md` would otherwise be read as a file.
    final entries = vault.root.listSync();
    for (final name in candidates) {
      final wanted = name.toLowerCase();
      for (final entity in entries) {
        if (entity is File && p.basename(entity.path).toLowerCase() == wanted) {
          return entity;
        }
      }
    }
    return null;
  }
}
