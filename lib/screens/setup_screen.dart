import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../providers/vault_provider.dart';
import '../services/git_service.dart';
import '../services/settings_service.dart';

/// First-run screen: clone an existing Tolaria vault (a Git repo) or create a
/// new empty vault and point it at a remote.
class SetupScreen extends ConsumerStatefulWidget {
  const SetupScreen({super.key});

  @override
  ConsumerState<SetupScreen> createState() => _SetupScreenState();
}

class _SetupScreenState extends ConsumerState<SetupScreen> {
  final _formKey = GlobalKey<FormState>();
  final _url = TextEditingController();
  final _branch = TextEditingController();
  final _name = TextEditingController(text: 'Tolaria User');
  final _email = TextEditingController(text: 'tolaria@localhost');
  final _username = TextEditingController();
  final _password = TextEditingController();

  /// Seconds spent on the current clone/init. libgit2's percentage can sit on
  /// one value for a long stretch, so a ticking counter is the honest "we are
  /// still working" signal.
  Timer? _ticker;
  int _waited = 0;

  /// Remembers the non-sensitive form fields so a failed or interrupted clone
  /// never forces a retype. The token box is deliberately not remembered.
  final SettingsService _drafts = SettingsService();

  @override
  void initState() {
    super.initState();
    _loadDraft();
    // Persist on every edit; SharedPreferences writes are cheap and this is a
    // one-screen form. The password box is excluded on purpose.
    for (final controller in [_url, _branch, _name, _email, _username]) {
      controller.addListener(_saveDraft);
    }
  }

  Future<void> _loadDraft() async {
    final draft = await _drafts.loadSetupDraft();
    if (!mounted) return;
    setState(() {
      if (draft['url']!.isNotEmpty) _url.text = draft['url']!;
      if (draft['branch']!.isNotEmpty) _branch.text = draft['branch']!;
      if (draft['name']!.isNotEmpty) _name.text = draft['name']!;
      if (draft['email']!.isNotEmpty) _email.text = draft['email']!;
      if (draft['username']!.isNotEmpty) _username.text = draft['username']!;
    });
  }

  Future<void> _saveDraft() => _drafts.saveSetupDraft(
        url: _url.text.trim(),
        branch: _branch.text.trim(),
        name: _name.text.trim(),
        email: _email.text.trim(),
        username: _username.text.trim(),
      );

  void _startTicker() {
    _ticker?.cancel();
    _waited = 0;
    _ticker = Timer.periodic(const Duration(seconds: 1), (timer) {
      if (!mounted) {
        timer.cancel();
        return;
      }
      setState(() => _waited++);
    });
  }

  void _stopTicker() {
    _ticker?.cancel();
    _ticker = null;
    if (_waited != 0) setState(() => _waited = 0);
  }

  @override
  void dispose() {
    _ticker?.cancel();
    for (final controller in [_url, _branch, _name, _email, _username]) {
      controller.removeListener(_saveDraft);
    }
    _url.dispose();
    _branch.dispose();
    _name.dispose();
    _email.dispose();
    _username.dispose();
    _password.dispose();
    super.dispose();
  }

  GitCredentials _creds() => GitCredentials(
        username: _username.text.trim().isEmpty ? null : _username.text.trim(),
        password: _password.text.isEmpty ? null : _password.text,
      );

  String get _branchValue => _branch.text.trim();

  Future<void> _clone() async {
    if (!_formKey.currentState!.validate()) return;
    if (_url.text.trim().isEmpty) {
      _snack('请填写远程仓库地址（https 或 ssh 均可）。');
      return;
    }
    final notifier = ref.read(vaultProvider.notifier);
    notifier.setCredentials(_creds());
    await notifier.cloneVault(
      url: _url.text.trim(),
      branch: _branchValue,
      authorName: _name.text.trim(),
      authorEmail: _email.text.trim(),
      credentials: _creds(),
    );
  }

  Future<void> _createEmpty() async {
    if (!_formKey.currentState!.validate()) return;
    final notifier = ref.read(vaultProvider.notifier);
    await notifier.createEmptyVault(
      url: _url.text.trim(),
      branch: _branchValue,
      authorName: _name.text.trim(),
      authorEmail: _email.text.trim(),
    );
  }

  void _snack(String text) {
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(text)));
  }

  @override
  Widget build(BuildContext context) {
    final state = ref.watch(vaultProvider);

    ref.listen<VaultState>(vaultProvider, (previous, next) {
      if (next.busy && !(previous?.busy ?? false)) {
        _startTicker();
      } else if (!next.busy && (previous?.busy ?? false)) {
        _stopTicker();
      }
      if (next.error != null && next.error != previous?.error) {
        _snack(next.error!);
      }
    });

    final theme = Theme.of(context);

    return Scaffold(
      body: SafeArea(
        child: Stack(
          children: [
            Form(
              key: _formKey,
              child: ListView(
                padding: const EdgeInsets.fromLTRB(20, 32, 20, 32),
                children: [
                  Icon(Icons.menu_book_rounded,
                      size: 56, color: theme.colorScheme.primary),
                  const SizedBox(height: 12),
                  Text('Tolaria',
                      textAlign: TextAlign.center,
                      style: theme.textTheme.headlineMedium
                          ?.copyWith(fontWeight: FontWeight.w700)),
                  const SizedBox(height: 6),
                  Text(
                    '将你的 Markdown 知识库（Git 仓库）同步到 Android',
                    textAlign: TextAlign.center,
                    style: theme.textTheme.bodyMedium
                        ?.copyWith(color: theme.colorScheme.outline),
                  ),
                  const SizedBox(height: 28),
                  _field(
                    controller: _url,
                    label: '远程仓库地址（Git URL）',
                    hint: 'https://github.com/you/vault.git',
                    keyboardType: TextInputType.url,
                  ),
                  const SizedBox(height: 12),
                  _field(
                    controller: _branch,
                    label: '分支（可选）',
                    hint: '留空 = 用仓库默认分支',
                  ),
                  const SizedBox(height: 12),
                  Row(
                    children: [
                      Expanded(
                        child: _field(
                          controller: _name,
                          label: '提交作者名',
                          validator: _required,
                        ),
                      ),
                      const SizedBox(width: 12),
                      Expanded(
                        child: _field(
                          controller: _email,
                          label: '提交邮箱',
                          keyboardType: TextInputType.emailAddress,
                          validator: _required,
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 20),
                  Text('私有仓库凭据（可选，仅本次会话内存保存）',
                      style: theme.textTheme.labelLarge
                          ?.copyWith(color: theme.colorScheme.outline)),
                  const SizedBox(height: 4),
                  Text(
                    'Gitee / GitHub 的「密码」位置请填私人访问令牌（不是登录密码），'
                    '令牌需勾选 repo 权限。公开仓库两个框都留空即可。',
                    style: theme.textTheme.bodySmall
                        ?.copyWith(color: theme.colorScheme.outline),
                  ),
                  const SizedBox(height: 8),
                  Row(
                    children: [
                      Expanded(
                        child: _field(
                          controller: _username,
                          label: '用户名',
                          hint: 'GitHub 可用 x-access-token',
                        ),
                      ),
                      const SizedBox(width: 12),
                      Expanded(
                        child: _field(
                          controller: _password,
                          label: '密码 / Token',
                          obscure: true,
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 28),
                  FilledButton.icon(
                    onPressed: state.busy ? null : _clone,
                    icon: const Icon(Icons.cloud_download_rounded),
                    label: const Text('克隆现有知识库'),
                    style: FilledButton.styleFrom(
                      minimumSize: const Size.fromHeight(50),
                    ),
                  ),
                  const SizedBox(height: 10),
                  OutlinedButton.icon(
                    onPressed: state.busy ? null : _createEmpty,
                    icon: const Icon(Icons.note_add_rounded),
                    label: const Text('新建空知识库'),
                    style: OutlinedButton.styleFrom(
                      minimumSize: const Size.fromHeight(50),
                    ),
                  ),
                  const SizedBox(height: 24),
                  // Errors stay on screen instead of vanishing with the
                  // SnackBar: a failed clone is exactly when the user needs to
                  // re-read what went wrong before retrying.
                  if (state.error != null)
                    Padding(
                      padding: const EdgeInsets.only(bottom: 12),
                      child: Text(
                        state.error!,
                        textAlign: TextAlign.center,
                        style: theme.textTheme.bodySmall
                            ?.copyWith(color: theme.colorScheme.error),
                      ),
                    ),
                  if (state.message != null)
                    Text(
                      state.message!,
                      textAlign: TextAlign.center,
                      style: theme.textTheme.bodySmall
                          ?.copyWith(color: theme.colorScheme.primary),
                    ),
                  const SizedBox(height: 8),
                  Text(
                    '地址、分支和作者信息会自动记住，下次打开不用重填；'
                    '令牌需要每次重填（不落盘）。',
                    textAlign: TextAlign.center,
                    style: theme.textTheme.bodySmall
                        ?.copyWith(color: theme.colorScheme.outline),
                  ),
                ],
              ),
            ),
            if (state.busy)
              Positioned.fill(
                child: ColoredBox(
                  color: Colors.black26,
                  child: Center(
                    child: Card(
                      margin: const EdgeInsets.symmetric(horizontal: 40),
                      child: Padding(
                        padding: const EdgeInsets.fromLTRB(24, 20, 24, 12),
                        child: Column(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Text(
                              state.message ?? '处理中…',
                              textAlign: TextAlign.center,
                              style: theme.textTheme.bodyMedium,
                            ),
                            if (_waited >= 3) ...[
                              const SizedBox(height: 4),
                              Text(
                                '已等待 $_waited 秒',
                                textAlign: TextAlign.center,
                                style: theme.textTheme.bodySmall?.copyWith(
                                  color: theme.colorScheme.outline,
                                ),
                              ),
                            ],
                            const SizedBox(height: 16),
                            state.progress > 0
                                ? LinearProgressIndicator(
                                    value: state.progress / 100,
                                    minHeight: 6,
                                    borderRadius: BorderRadius.circular(3),
                                  )
                                : const LinearProgressIndicator(minHeight: 6),
                            const SizedBox(height: 8),
                            TextButton(
                              onPressed: () =>
                                  ref.read(vaultProvider.notifier).cancelOperation(),
                              child: const Text('取消'),
                            ),
                          ],
                        ),
                      ),
                    ),
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }

  String? _required(String? value) {
    if (value == null || value.trim().isEmpty) return '必填';
    return null;
  }

  Widget _field({
    required TextEditingController controller,
    required String label,
    String? hint,
    bool obscure = false,
    TextInputType? keyboardType,
    String? Function(String?)? validator,
  }) {
    return TextFormField(
      controller: controller,
      obscureText: obscure,
      keyboardType: keyboardType,
      validator: validator,
      decoration: InputDecoration(
        labelText: label,
        hintText: hint,
        border: const OutlineInputBorder(),
        isDense: true,
      ),
    );
  }
}
