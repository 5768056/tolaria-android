import 'dart:io';

import 'package:git2dart/git2dart.dart' as g;
import 'package:path/path.dart' as p;
import 'package:flutter_test/flutter_test.dart';

/// Probes how libgit2's clone behaves when the target directory already exists
/// (which is exactly what GitWorker._clone does: it pre-creates the staging
/// directory before cloning into it). If the clone lands in a *sub*directory
/// named after the remote instead of the target itself, the promoted vault
/// would be empty — the root cause of the "clone succeeded but nothing is
/// here" class of bugs.
void main() {
  test('clone lands inside a pre-created empty directory', () async {
    final tmp = Directory.systemTemp.createTempSync('clone_probe_');
    try {
      // A source repo with one commit.
      final src = Directory(p.join(tmp.path, 'src'));
      src.createSync(recursive: true);
      final srcRepo = g.Repository.init(path: src.path, initialHead: 'refs/heads/main');
      File(p.join(src.path, 'hello.md')).writeAsStringSync('# hello\n');
      final index = srcRepo.index;
      index.addAll(const ['*'], flags: const {g.GitIndexAddOption.defaults});
      index.write();
      final sig = g.Signature.create(name: 'probe', email: 'probe@local');
      g.Commit.create(
        repo: srcRepo,
        updateRef: 'HEAD',
        author: sig,
        committer: sig,
        message: 'init',
        tree: g.Tree.lookup(repo: srcRepo, oid: index.writeTree()),
        parents: [],
      );

      // The target, pre-created and empty — mirroring _stagingDir().
      final staging = Directory(p.join(tmp.path, 'staging'));
      staging.createSync(recursive: true);

      final cloned = g.Repository.clone(url: src.path, localPath: staging.path);
      try {
        // Where did the working tree land?
        final workTreeOk = File(p.join(staging.path, 'hello.md')).existsSync();
        // False would mean libgit2 put things somewhere else entirely.
        expect(workTreeOk, isTrue,
            reason: 'clone did not land in the pre-created target directory');
        expect(cloned.path, isNotNull);
      } finally {
        cloned.free();
      }
    } finally {
      tmp.deleteSync(recursive: true);
    }
  });
}
