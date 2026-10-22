import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../models/ai_config.dart';
import '../providers/ai_provider.dart';
import '../services/ai_service.dart';

/// Endpoint configuration for the assistant.
///
/// Mirrors Tolaria's "direct model target" settings (provider + base URL +
/// model + key). The desktop app can additionally point at a local CLI agent;
/// that path does not exist on Android, so it is not offered here.
class AiSettingsScreen extends ConsumerStatefulWidget {
  const AiSettingsScreen({super.key});

  @override
  ConsumerState<AiSettingsScreen> createState() => _AiSettingsScreenState();
}

class _AiSettingsScreenState extends ConsumerState<AiSettingsScreen> {
  late final TextEditingController _baseUrl;
  late final TextEditingController _model;
  late final TextEditingController _apiKey;
  late final TextEditingController _outputTemplate;
  late final TextEditingController _searchKey;
  late String _presetId;
  late AiProtocol _protocol;
  late bool _includeContext;
  late SearchProvider _searchProvider;

  bool _showKey = false;
  bool _testing = false;

  @override
  void initState() {
    super.initState();
    final config = ref.read(aiChatProvider).config;
    _presetId = config.presetId;
    _protocol = config.protocol;
    _baseUrl = TextEditingController(text: config.baseUrl);
    _model = TextEditingController(text: config.model);
    _apiKey = TextEditingController(text: config.apiKey);
    _outputTemplate = TextEditingController(text: config.outputTemplate);
    _searchKey = TextEditingController(text: config.searchApiKey);
    _includeContext = config.includeNoteContext;
    _searchProvider = config.searchProvider;
  }

  @override
  void dispose() {
    _baseUrl.dispose();
    _model.dispose();
    _apiKey.dispose();
    _outputTemplate.dispose();
    _searchKey.dispose();
    super.dispose();
  }

  AiConfig _currentConfig() => AiConfig(
        presetId: _presetId,
        protocol: _protocol,
        baseUrl: _baseUrl.text.trim(),
        model: _model.text.trim(),
        apiKey: _apiKey.text.trim(),
        includeNoteContext: _includeContext,
        outputTemplate: _outputTemplate.text.trim(),
        searchApiKey: _searchKey.text.trim(),
        searchProvider: _searchProvider,
      );

  void _applyPreset(String? id) {
    if (id == null) return;
    final preset = presetById(id);
    setState(() {
      _presetId = id;
      _protocol = preset.protocol;
      _baseUrl.text = preset.baseUrl;
      _model.text = preset.defaultModel;
    });
  }

  Future<void> _save() async {
    final config = _currentConfig();
    if (!config.isUsable) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('接口地址和模型名都要填')),
      );
      return;
    }
    await ref.read(aiChatProvider.notifier).saveConfig(config);
    if (!mounted) return;
    ScaffoldMessenger.of(context)
        .showSnackBar(const SnackBar(content: Text('AI 设置已保存')));
    Navigator.of(context).pop();
  }

  /// GET the model list — free, and it validates key + URL before the user
  /// spends any tokens.
  Future<void> _testConnection() async {
    final config = _currentConfig();
    if (config.baseUrl.trim().isEmpty) {
      ScaffoldMessenger.of(context)
          .showSnackBar(const SnackBar(content: Text('先填接口地址')));
      return;
    }
    setState(() => _testing = true);
    try {
      final models = await AiService(config).listModels();
      if (!mounted) return;
      if (models.isEmpty) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('连接成功，但接口没返回模型列表，手填模型名即可')),
        );
        return;
      }
      await _pickModel(models);
    } catch (error) {
      if (!mounted) return;
      await _showError(error);
    } finally {
      if (mounted) setState(() => _testing = false);
    }
  }

  Future<void> _pickModel(List<String> models) async {
    final chosen = await showDialog<String>(
      context: context,
      builder: (ctx) => SimpleDialog(
        title: Text('可用模型（${models.length}）'),
        children: [
          SizedBox(
            width: double.maxFinite,
            height: 420,
            child: ListView.builder(
              shrinkWrap: true,
              itemCount: models.length,
              itemBuilder: (context, index) {
                final id = models[index];
                final isCurrent = id == _model.text.trim();
                return ListTile(
                  dense: true,
                  title: Text(id),
                  trailing: isCurrent ? const Icon(Icons.check, size: 18) : null,
                  onTap: () => Navigator.pop(ctx, id),
                );
              },
            ),
          ),
        ],
      ),
    );
    if (chosen != null && mounted) {
      setState(() => _model.text = chosen);
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('已选择 $chosen，记得保存')),
      );
    }
  }

  Future<void> _showError(Object error) async {
    final message = error is AiException ? error.expanded : error.toString();
    await showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('连接失败'),
        content: SingleChildScrollView(
          child: SelectableText(message),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('知道了'),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final preset = presetById(_presetId);

    return Scaffold(
      appBar: AppBar(
        title: const Text('AI 助手设置'),
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
          Text(
            '两种用法共用这里的配置：「Agent」模式让模型读、搜、改你的笔记'
            '（改动前会先问你，跑不了命令）；「问答」模式只把笔记内容发过去，'
            '拿回答，不碰文件。'
            '桌面版调用本机 Claude Code / Codex 那条路要靠命令行工具，安卓上做不到——'
            '这里是在 Dart 里重写的一份，工具一样，边界更窄。',
            style: theme.textTheme.bodySmall
                ?.copyWith(color: theme.colorScheme.outline),
          ),
          const SizedBox(height: 20),
          _label('服务商'),
          DropdownButtonFormField<String>(
            initialValue: _presetId,
            isExpanded: true,
            decoration: const InputDecoration(border: OutlineInputBorder()),
            items: [
              for (final item in aiPresets)
                DropdownMenuItem(value: item.id, child: Text(item.label)),
            ],
            onChanged: _applyPreset,
          ),
          if (preset.note.isNotEmpty) ...[
            const SizedBox(height: 6),
            Text(
              preset.note,
              style: theme.textTheme.bodySmall
                  ?.copyWith(color: theme.colorScheme.outline),
            ),
          ],
          if (preset.keyUrl.isNotEmpty) ...[
            const SizedBox(height: 4),
            Text(
              'Key 申请：${preset.keyUrl}',
              style: theme.textTheme.bodySmall
                  ?.copyWith(color: theme.colorScheme.primary),
            ),
          ],
          const SizedBox(height: 20),
          _label('接口地址（Base URL）'),
          TextField(
            controller: _baseUrl,
            keyboardType: TextInputType.url,
            autocorrect: false,
            decoration: const InputDecoration(
              hintText: 'https://api.deepseek.com/v1',
              border: OutlineInputBorder(),
            ),
          ),
          const SizedBox(height: 20),
          _label('模型'),
          Row(
            children: [
              Expanded(
                child: TextField(
                  controller: _model,
                  autocorrect: false,
                  decoration: const InputDecoration(
                    hintText: 'deepseek-chat',
                    border: OutlineInputBorder(),
                  ),
                ),
              ),
              const SizedBox(width: 8),
              SizedBox(
                height: 56,
                child: OutlinedButton(
                  onPressed: _testing ? null : _testConnection,
                  child: _testing
                      ? const SizedBox(
                          width: 16,
                          height: 16,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : const Text('检测连接'),
                ),
              ),
            ],
          ),
          const SizedBox(height: 20),
          _label('API Key'),
          TextField(
            controller: _apiKey,
            obscureText: !_showKey,
            autocorrect: false,
            enableSuggestions: false,
            decoration: InputDecoration(
              hintText: '粘贴服务商的 Key',
              border: const OutlineInputBorder(),
              suffixIcon: IconButton(
                icon: Icon(
                  _showKey ? Icons.visibility_off_outlined : Icons.visibility_outlined,
                ),
                onPressed: () => setState(() => _showKey = !_showKey),
              ),
            ),
          ),
          const SizedBox(height: 6),
          Text(
            'Key 保存在本应用的私有存储里（其他应用读不到），不会写进笔记、也不会提交到 git。'
            '如果手机借给别人，建议用完清空。',
            style: theme.textTheme.bodySmall
                ?.copyWith(color: theme.colorScheme.outline),
          ),
          const SizedBox(height: 20),
          SwitchListTile(
            contentPadding: EdgeInsets.zero,
            value: _includeContext,
            onChanged: (value) => setState(() => _includeContext = value),
            title: const Text('带上笔记内容'),
            subtitle: const Text(
              '开着：把当前笔记正文 + 知识库目录一起发给模型，回答能引用原文。'
              '关掉：只发你的提问，更省 token。',
            ),
          ),
          const SizedBox(height: 20),
          _label('输出格式模板'),
          TextField(
            controller: _outputTemplate,
            keyboardType: TextInputType.multiline,
            maxLines: 4,
            textInputAction: TextInputAction.newline,
            decoration: const InputDecoration(
              hintText: '例如：用 Markdown 表格输出，分三点，每条带来源链接',
              border: OutlineInputBorder(),
            ),
          ),
          const SizedBox(height: 6),
          Text(
            '留空则用默认风格（中文、短句、先给结论）。填了之后，Agent 每次回答都会'
            '尽量按这个格式来。',
            style: theme.textTheme.bodySmall
                ?.copyWith(color: theme.colorScheme.outline),
          ),
          const SizedBox(height: 20),
          _label('联网搜索（可选）'),
          _label('搜索服务商'),
          DropdownButtonFormField<SearchProvider>(
            initialValue: _searchProvider,
            isExpanded: true,
            decoration: const InputDecoration(border: OutlineInputBorder()),
            items: const [
              DropdownMenuItem(
                value: SearchProvider.tavily,
                child: Text('Tavily（海外，免 Key 兜底走 DuckDuckGo）'),
              ),
              DropdownMenuItem(
                value: SearchProvider.bocha,
                child: Text('博查 BoCha（国产，低延迟）'),
              ),
            ],
            onChanged: (value) {
              if (value != null) setState(() => _searchProvider = value);
            },
          ),
          const SizedBox(height: 20),
          TextField(
            controller: _searchKey,
            autocorrect: false,
            enableSuggestions: false,
            decoration: InputDecoration(
              hintText: _searchProvider == SearchProvider.bocha
                  ? '博查 BoCha API Key（可留空）'
                  : 'Tavily API Key（可留空）',
              border: const OutlineInputBorder(),
            ),
          ),
          const SizedBox(height: 6),
          Text(
            _searchProvider == SearchProvider.bocha
                ? '博查是国产搜索 API，国内直连、延迟低，需要 Key 才能用（bochaai.com '
                    '注册后在开发者中心获取）。填好后 Agent 模式的 web_search 走博查。'
                : '不填也能搜索：默认走免 Key 的 DuckDuckGo，但来自 App 的请求可能被拦截。'
                    '填了 Tavily 的 Key 后搜索更稳定、返回更规整。'
                    'Key 只存在本应用私有存储，不会写进笔记或 git。',
            style: theme.textTheme.bodySmall
                ?.copyWith(color: theme.colorScheme.outline),
          ),
          const SizedBox(height: 24),
          FilledButton(
            onPressed: _save,
            style: FilledButton.styleFrom(minimumSize: const Size.fromHeight(48)),
            child: const Text('保存'),
          ),
        ],
      ),
    );
  }

  Widget _label(String text) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Text(
        text,
        style: Theme.of(context)
            .textTheme
            .labelLarge
            ?.copyWith(color: Theme.of(context).colorScheme.primary),
      ),
    );
  }
}
