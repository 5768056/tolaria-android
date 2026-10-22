import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../providers/ai_provider.dart';
import '../providers/vault_provider.dart';
import '../services/credentials_store.dart';
import '../services/git_service.dart';
import 'ai_settings_screen.dart';

class SettingsScreen extends ConsumerStatefulWidget {
  const SettingsScreen({super.key});

  @override
  ConsumerState<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends ConsumerState<SettingsScreen> {
  late final TextEditingController _url;
  late final TextEditingController _branch;
  late final TextEditingController _name;
  late final TextEditingController _email;
  late final TextEditingController _username;
  late final TextEditingController _password;

  /// The remote-config block starts collapsed once a remote is configured —
  /// re-typing the URL to change a branch is not something anyone does twice.
  late final bool _remoteExpanded;

  @override
  void initState() {
    super.initState();
    final config = ref.read(vaultProvider).config;
    final creds = ref.read(vaultProvider.notifier).credentials;
    _url = TextEditingController(text: config?.remoteUrl ?? '');
    _branch = TextEditingController(text: config?.branch ?? 'main');
    _name = TextEditingController(text: config?.authorName ?? 'Tolaria User');
    _email =
        TextEditingController(text: config?.authorEmail ?? 'tolaria@localhost');
    _username = TextEditingController(text: creds?.username ?? '');
    _password = TextEditingController(text: creds?.password ?? '');
    _remoteExpanded = (config?.remoteUrl ?? '').isEmpty;
    _loadStoredCredentials();
  }

  /// Fills the credential boxes from the keystore. Without this the fields are
  /// empty on every cold start even though the token was saved — the user
  /// asked for "don't make me type it again", and a blank box reads as lost.
  Future<void> _loadStoredCredentials() async {
    final stored = await CredentialsStore().load();
    if (!mounted || stored == null) return;
    setState(() {
      if (_username.text.isEmpty && (stored.username?.isNotEmpty ?? false)) {
        _username.text = stored.username!;
      }
      if (_password.text.isEmpty && (stored.password?.isNotEmpty ?? false)) {
        _password.text = stored.password!;
      }
    });
    // Also hand them to the provider so a sync works without pressing save.
    ref.read(vaultProvider.notifier).setCredentials(stored);
  }

  @override
  void dispose() {
    _url.dispose();
    _branch.dispose();
    _name.dispose();
    _email.dispose();
    _username.dispose();
    _password.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    final config = ref.read(vaultProvider).config;
    if (config == null) return;

    final updated = config.copyWith(
      remoteUrl: _url.text.trim(),
      branch: _branch.text.trim().isEmpty ? 'main' : _branch.text.trim(),
      authorName: _name.text.trim().isEmpty ? 'Tolaria User' : _name.text.trim(),
      authorEmail:
          _email.text.trim().isEmpty ? 'tolaria@localhost' : _email.text.trim(),
    );

    await ref.read(vaultProvider.notifier).updateConfig(updated);
    final credentials = GitCredentials(
      username: _username.text.trim().isEmpty ? null : _username.text.trim(),
      password: _password.text.isEmpty ? null : _password.text,
    );
    ref.read(vaultProvider.notifier).setCredentials(credentials);
    // Persist through the keystore — clearing both boxes clears the store.
    try {
      await CredentialsStore().save(credentials);
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('凭据保存失败（加密存储不可用）：$e')),
      );
      return;
    }

    // Keep the on-disk remote in sync with the configured URL.
    if (updated.remoteUrl.isNotEmpty) {
      try {
        await GitService.create(updated.vaultPath)
            .configureRemote(updated.remoteUrl);
      } catch (_) {
        // Non-fatal: the URL is still saved for later push/pull attempts.
      }
    }

    if (!mounted) return;
    ScaffoldMessenger.of(context)
        .showSnackBar(const SnackBar(content: Text('设置已保存')));
  }

  Future<void> _resetVault() async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('更换 / 退出知识库'),
        content: const Text(
          '将从本应用移除当前知识库配置（不会删除远程仓库）。'
          '本机副本会保留在应用私有目录，可通过重新克隆/新建覆盖。',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('确认'),
          ),
        ],
      ),
    );
    if (ok != true) return;
    await ref.read(vaultProvider.notifier).resetVault();
    if (!mounted) return;
    Navigator.of(context).popUntil((route) => route.isFirst);
  }

  @override
  Widget build(BuildContext context) {
    final state = ref.watch(vaultProvider);
    final ai = ref.watch(aiChatProvider);
    final theme = Theme.of(context);

    final remote = state.config?.remoteUrl ?? '';
    final remoteSubtitle = remote.isEmpty ? '未配置远程仓库' : remote;

    return Scaffold(
      appBar: AppBar(
        title: const Text('设置'),
        actions: [
          IconButton(
            tooltip: '保存',
            icon: const Icon(Icons.check_rounded),
            onPressed: _save,
          ),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          _section('知识库'),
          if (state.config != null)
            ListTile(
              contentPadding: EdgeInsets.zero,
              leading: const Icon(Icons.folder_outlined),
              title: const Text('本地路径'),
              subtitle: Text(state.config!.vaultPath),
            ),
          const SizedBox(height: 8),
          // The remote block is the longest stretch of form on this screen and
          // is configured once. It starts open while the remote is missing and
          // collapsed afterwards — tap the header to change it.
          Card(
            margin: EdgeInsets.zero,
            child: ExpansionTile(
              initiallyExpanded: _remoteExpanded,
              title: const Text('远程仓库配置'),
              subtitle: Text(
                remoteSubtitle,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
              childrenPadding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
              children: [
                _section('远程与分支'),
                TextField(
                  controller: _url,
                  keyboardType: TextInputType.url,
                  decoration: const InputDecoration(
                    labelText: '远程仓库地址',
                    hintText: 'https://github.com/you/vault.git',
                    border: OutlineInputBorder(),
                  ),
                ),
                const SizedBox(height: 12),
                TextField(
                  controller: _branch,
                  decoration: const InputDecoration(
                    labelText: '分支',
                    border: OutlineInputBorder(),
                  ),
                ),
                const SizedBox(height: 16),
                _section('提交身份'),
                Row(
                  children: [
                    Expanded(
                      child: TextField(
                        controller: _name,
                        decoration: const InputDecoration(
                          labelText: '作者名',
                          border: OutlineInputBorder(),
                        ),
                      ),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: TextField(
                        controller: _email,
                        decoration: const InputDecoration(
                          labelText: '邮箱',
                          border: OutlineInputBorder(),
                        ),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 16),
                _section('凭据（加密保存在本机）'),
                Row(
                  children: [
                    Expanded(
                      child: TextField(
                        controller: _username,
                        decoration: const InputDecoration(
                          labelText: '用户名',
                          hintText: 'GitHub 可用 x-access-token',
                          border: OutlineInputBorder(),
                        ),
                      ),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: TextField(
                        controller: _password,
                        obscureText: true,
                        decoration: const InputDecoration(
                          labelText: '密码 / Token',
                          border: OutlineInputBorder(),
                        ),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 6),
                Text(
                  '通过系统加密存储（Keystore）保存，重启后仍然可用；两项都清空即删除。',
                  style: theme.textTheme.bodySmall
                      ?.copyWith(color: theme.colorScheme.outline),
                ),
              ],
            ),
          ),
          const SizedBox(height: 20),
          _section('AI 助手'),
          ListTile(
            contentPadding: EdgeInsets.zero,
            leading: const Icon(Icons.auto_awesome_outlined),
            title: const Text('模型与 API Key'),
            subtitle: Text(
              // Local servers legitimately have no key, so "configured" is
              // decided by having an endpoint and a model — not by the key.
              ai.config.isUsable
                  ? ai.config.shortLabel
                  : '未配置（点这里填服务商和 Key）',
            ),
            trailing: const Icon(Icons.chevron_right),
            onTap: () => Navigator.of(context).push(
              MaterialPageRoute(builder: (_) => const AiSettingsScreen()),
            ),
          ),
          const SizedBox(height: 8),
          OutlinedButton.icon(
            onPressed: _resetVault,
            icon: const Icon(Icons.swap_horiz_rounded),
            label: const Text('更换 / 退出知识库'),
            style: OutlinedButton.styleFrom(
              foregroundColor: theme.colorScheme.error,
              minimumSize: const Size.fromHeight(48),
            ),
          ),
          const SizedBox(height: 12),
          Text(
            '说明：本应用与 Tolaria 桌面端共用同一套 Markdown + Git 文件格式，'
            '不包含任何私有数据格式。修改会在下次「提交并推送」时同步到远程。',
            style: theme.textTheme.bodySmall
                ?.copyWith(color: theme.colorScheme.outline),
          ),
        ],
      ),
    );
  }

  Widget _section(String title) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Text(
        title,
        style: Theme.of(context)
            .textTheme
            .labelLarge
            ?.copyWith(color: Theme.of(context).colorScheme.primary),
      ),
    );
  }
}
