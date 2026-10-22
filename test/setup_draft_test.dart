import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:tolaria_android/services/settings_service.dart';

/// The setup draft is what keeps a failed or interrupted first-run clone from
/// forcing a full retype — the exact complaint behind this feature.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
  });

  test('setup draft round-trips the non-sensitive fields', () async {
    final settings = SettingsService();
    await settings.saveSetupDraft(
      url: 'https://gitee.com/me/vault.git',
      branch: 'main',
      name: '我',
      email: 'me@example.com',
      username: 'someone',
    );
    final draft = await settings.loadSetupDraft();
    expect(draft['url'], 'https://gitee.com/me/vault.git');
    expect(draft['branch'], 'main');
    expect(draft['name'], '我');
    expect(draft['email'], 'me@example.com');
    expect(draft['username'], 'someone');
  });

  test('clearing the draft empties every field', () async {
    final settings = SettingsService();
    await settings.saveSetupDraft(
      url: 'https://gitee.com/me/vault.git',
      branch: 'main',
      name: '我',
      email: 'me@example.com',
      username: 'someone',
    );
    await settings.clearSetupDraft();
    final draft = await settings.loadSetupDraft();
    expect(draft.values.every((v) => v.isEmpty), isTrue);
  });

  test('no draft stored means empty defaults, not stale values', () async {
    final draft = await SettingsService().loadSetupDraft();
    expect(draft['url'], '');
    expect(draft['username'], '');
  });
}
