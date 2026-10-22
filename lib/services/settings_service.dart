import 'package:shared_preferences/shared_preferences.dart';

import '../models/vault_config.dart';

/// Persists non-secret vault configuration between app launches.
class SettingsService {
  static const _kPath = 'vault_path';
  static const _kRemote = 'remote_url';
  static const _kBranch = 'branch';
  static const _kName = 'author_name';
  static const _kEmail = 'author_email';

  // Setup-form draft keys. Only non-sensitive fields are remembered — the
  // password / token box is deliberately excluded so a cloned-from-elsewhere
  // token never lands in plain-text prefs.
  static const _kDraftUrl = 'setup_draft_url';
  static const _kDraftBranch = 'setup_draft_branch';
  static const _kDraftName = 'setup_draft_name';
  static const _kDraftEmail = 'setup_draft_email';
  static const _kDraftUsername = 'setup_draft_username';

  Future<SharedPreferences> get _prefs => SharedPreferences.getInstance();

  Future<VaultConfig?> loadConfig() async {
    final prefs = await _prefs;
    final path = prefs.getString(_kPath);
    if (path == null || path.isEmpty) return null;
    return VaultConfig(
      vaultPath: path,
      remoteUrl: prefs.getString(_kRemote) ?? '',
      branch: prefs.getString(_kBranch) ?? 'main',
      authorName: prefs.getString(_kName) ?? 'Tolaria User',
      authorEmail: prefs.getString(_kEmail) ?? 'tolaria@localhost',
    );
  }

  Future<void> saveConfig(VaultConfig config) async {
    final prefs = await _prefs;
    await prefs.setString(_kPath, config.vaultPath);
    await prefs.setString(_kRemote, config.remoteUrl);
    await prefs.setString(_kBranch, config.branch);
    await prefs.setString(_kName, config.authorName);
    await prefs.setString(_kEmail, config.authorEmail);
  }

  Future<void> clearVault() async {
    final prefs = await _prefs;
    await prefs.remove(_kPath);
  }

  /// Remembers what the user typed on the first-run screen so a failed or
  /// interrupted clone does not force them to retype the URL and author info.
  /// The token is intentionally not included.
  Future<void> saveSetupDraft({
    required String url,
    required String branch,
    required String name,
    required String email,
    required String username,
  }) async {
    final prefs = await _prefs;
    await prefs.setString(_kDraftUrl, url);
    await prefs.setString(_kDraftBranch, branch);
    await prefs.setString(_kDraftName, name);
    await prefs.setString(_kDraftEmail, email);
    await prefs.setString(_kDraftUsername, username);
  }

  Future<Map<String, String>> loadSetupDraft() async {
    final prefs = await _prefs;
    return {
      'url': prefs.getString(_kDraftUrl) ?? '',
      'branch': prefs.getString(_kDraftBranch) ?? '',
      'name': prefs.getString(_kDraftName) ?? '',
      'email': prefs.getString(_kDraftEmail) ?? '',
      'username': prefs.getString(_kDraftUsername) ?? '',
    };
  }

  Future<void> clearSetupDraft() async {
    final prefs = await _prefs;
    await prefs.remove(_kDraftUrl);
    await prefs.remove(_kDraftBranch);
    await prefs.remove(_kDraftName);
    await prefs.remove(_kDraftEmail);
    await prefs.remove(_kDraftUsername);
  }
}
