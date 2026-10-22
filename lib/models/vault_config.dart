/// Non-secret configuration for a vault, persisted between sessions.
///
/// Credentials (passwords / tokens) are intentionally NOT stored here — they
/// are held in memory for the current session only. Persisting secrets in
/// plaintext SharedPreferences would be a security smell.
class VaultConfig {
  final String vaultPath;
  final String remoteUrl;
  final String branch;
  final String authorName;
  final String authorEmail;

  const VaultConfig({
    required this.vaultPath,
    this.remoteUrl = '',
    this.branch = 'main',
    this.authorName = 'Tolaria User',
    this.authorEmail = 'tolaria@localhost',
  });

  VaultConfig copyWith({
    String? vaultPath,
    String? remoteUrl,
    String? branch,
    String? authorName,
    String? authorEmail,
  }) {
    return VaultConfig(
      vaultPath: vaultPath ?? this.vaultPath,
      remoteUrl: remoteUrl ?? this.remoteUrl,
      branch: branch ?? this.branch,
      authorName: authorName ?? this.authorName,
      authorEmail: authorEmail ?? this.authorEmail,
    );
  }
}
