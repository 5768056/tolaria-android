import 'package:flutter_secure_storage/flutter_secure_storage.dart';

import 'git_service.dart' show GitCredentials;

/// Git credentials at rest.
///
/// `shared_preferences` is a plain XML file on disk, so a Gitee token in it is
/// a token in plain text. The user explicitly asked for credentials to survive
/// an app restart, so they go through the platform keystore instead
/// (Android Keystore + EncryptedSharedPreferences under the hood).
///
/// The token is deliberately *not* in the setup draft either — only this
/// explicit opt-in path stores it.
class CredentialsStore {
  CredentialsStore({FlutterSecureStorage? storage})
      : _storage = storage ??
            const FlutterSecureStorage(
              // The setup screen drafts in SharedPreferences, so a plaintext
              // fallback would silently undo the point of this class.
              iOptions: IOSOptions(accessibility: KeychainAccessibility.first_unlock),
            );

  final FlutterSecureStorage _storage;

  static const _kUsername = 'git_username';
  static const _kPassword = 'git_password';

  Future<GitCredentials?> load() async {
    final username = await _storage.read(key: _kUsername);
    final password = await _storage.read(key: _kPassword);
    if ((username == null || username.isEmpty) &&
        (password == null || password.isEmpty)) {
      return null;
    }
    return GitCredentials(username: username, password: password);
  }

  Future<void> save(GitCredentials credentials) async {
    if (credentials.isEmpty) {
      await clear();
      return;
    }
    final username = credentials.username;
    final password = credentials.password;
    if (username != null && username.isNotEmpty) {
      await _storage.write(key: _kUsername, value: username);
    } else {
      await _storage.delete(key: _kUsername);
    }
    if (password != null && password.isNotEmpty) {
      await _storage.write(key: _kPassword, value: password);
    } else {
      await _storage.delete(key: _kPassword);
    }
  }

  Future<void> clear() async {
    await _storage.delete(key: _kUsername);
    await _storage.delete(key: _kPassword);
  }
}
