/// Progress reported by a git transfer (clone / push / pull).
///
/// libgit2 counts *objects*, not bytes of a known total, so [percent] can sit
/// still for a long stretch while a large pack streams in — the counter only
/// advances once whole objects have been indexed. [receivedBytes] keeps
/// climbing during that window, which is why it is surfaced separately: the UI
/// shows "已接收 1.2 MB" so a slow clone cannot be mistaken for a hung one.
///
/// Lives in its own file (not in `git_service.dart`) to keep the dependency
/// graph acyclic: the worker isolate imports this, while `git_service.dart`
/// imports the worker's runner.
class GitProgress {
  const GitProgress({
    required this.percent,
    this.receivedBytes = 0,
    this.receivedObjects = 0,
    this.totalObjects = 0,
  });

  /// 0-100, derived from received / total objects.
  final int percent;

  /// Bytes of pack data received so far.
  final int receivedBytes;

  final int receivedObjects;
  final int totalObjects;

  /// Human-readable byte count, e.g. "1.2 MB".
  String get receivedLabel {
    if (receivedBytes < 1024) return '$receivedBytes B';
    if (receivedBytes < 1024 * 1024) {
      return '${(receivedBytes / 1024).toStringAsFixed(1)} KB';
    }
    return '${(receivedBytes / (1024 * 1024)).toStringAsFixed(1)} MB';
  }

  /// Serialisable form for crossing an isolate boundary.
  Map<String, Object?> toMap() => <String, Object?>{
        'percent': percent,
        'bytes': receivedBytes,
        'objects': receivedObjects,
        'total': totalObjects,
      };

  static GitProgress? fromMap(Object? raw) {
    if (raw is! Map) return null;
    final percent = raw['percent'];
    if (percent is! num) return null;
    return GitProgress(
      percent: percent.toInt().clamp(0, 100),
      receivedBytes: (raw['bytes'] as num?)?.toInt() ?? 0,
      receivedObjects: (raw['objects'] as num?)?.toInt() ?? 0,
      totalObjects: (raw['total'] as num?)?.toInt() ?? 0,
    );
  }
}
