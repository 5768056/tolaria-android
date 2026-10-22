/// AI assistant domain model.
///
/// ## Why this is not a port of the desktop AI
///
/// Tolaria on the desktop has two AI surfaces:
///
///  1. **Agent mode** — it spawns a local CLI agent (Claude Code, Codex,
///     Copilot, OpenCode, Pi, Antigravity, Kiro, Hermes) as a subprocess and
///     hands it Tolaria's MCP server, so the agent can search and edit the
///     vault with tools.
///  2. **Direct model targets** — it calls an HTTP chat-completions endpoint
///     (OpenAI-compatible or Anthropic Messages) with the active note as
///     context, and does *not* grant shell or tool access. Tolaria calls this
///     "Chat mode".
///
/// The consequence is worth stating plainly: Chat mode can *read* the vault
/// (what this app puts in the prompt) but cannot *act* on it beyond the
/// explicit "save as note" button. Acting on the vault is Agent mode's job —
/// it runs its own loop in Dart (`services/agent/agent_runner.dart`) over nine
/// vault tools, and asks before every write. No shell either way: there is no
/// way to spawn a command from an Android app, so that stays a desktop feature.
library;

/// Wire protocol, not vendor. Several vendors speak the same one.
enum AiProtocol {
  /// `POST {base}/chat/completions`, `Authorization: Bearer`, SSE deltas.
  /// Used by OpenAI, DeepSeek, Moonshot, Zhipu, DashScope, SiliconFlow,
  /// OpenRouter, Ollama and most self-hosted gateways.
  openai,

  /// `POST {base}/v1/messages`, `x-api-key`, `anthropic-version`.
  anthropic,

  /// `POST {base}/models/{model}:streamGenerateContent?alt=sse`.
  gemini,
}

/// Which backend `web_search` talks to.
///
/// Kept separate from the chat [AiProtocol] because the search provider is
/// independent of the model endpoint — you can run DeepSeek for chat and BoCha
/// for search, or any other mix.
enum SearchProvider {
  /// https://tavily.com — structured results, needs a key.
  tavily,

  /// https://bochaai.com — Chinese-native, low latency inside CN, needs a key.
  bocha,
}

/// How much Agent mode may change files without asking.
///
/// The desktop panel can leave this to the CLI agent's own permission system;
/// the phone loop owns the tools, so the policy lives here instead. All three
/// settings still show every write as a tool card in the timeline — the silent
/// part is the dialog, never the audit trail.
enum AgentWritePolicy {
  /// Ask before every write. The default: a model that decides to rewrite three
  /// notes should get three "yes" answers, not one.
  ask,

  /// Ask once per conversation. The first approved write covers the rest of the
  /// thread; clearing the chat (or restarting the app) asks again.
  session,

  /// Never ask. Meant for a vault that is kept in git and reviewed afterwards;
  /// the tool cards still name every file that changed.
  always,
}

/// A ready-made endpoint, so the user only has to paste a key.
class AiPreset {
  const AiPreset({
    required this.id,
    required this.label,
    required this.protocol,
    required this.baseUrl,
    required this.defaultModel,
    this.keyUrl = '',
    this.requiresKey = true,
    this.note = '',
  });

  final String id;
  final String label;
  final AiProtocol protocol;
  final String baseUrl;
  final String defaultModel;

  /// Where to get a key — shown as a hint, never opened automatically.
  final String keyUrl;
  final bool requiresKey;

  /// One line of guidance shown under the preset picker.
  final String note;
}

/// Ordered with China-accessible providers first: that is who will actually
/// use this build.
const List<AiPreset> aiPresets = [
  AiPreset(
    id: 'deepseek',
    label: 'DeepSeek',
    protocol: AiProtocol.openai,
    baseUrl: 'https://api.deepseek.com/v1',
    defaultModel: 'deepseek-chat',
    keyUrl: 'platform.deepseek.com',
    note: '便宜、中文好，deepseek-chat 即可；推理用 deepseek-reasoner。',
  ),
  AiPreset(
    id: 'dashscope',
    label: '通义千问（阿里云百炼）',
    protocol: AiProtocol.openai,
    baseUrl: 'https://dashscope.aliyuncs.com/compatible-mode/v1',
    defaultModel: 'qwen-plus',
    keyUrl: 'bailian.console.aliyun.com',
    note: '百炼控制台的 API Key；兼容模式走 OpenAI 协议。',
  ),
  AiPreset(
    id: 'moonshot',
    label: 'Kimi（月之暗面）',
    protocol: AiProtocol.openai,
    baseUrl: 'https://api.moonshot.cn/v1',
    defaultModel: 'kimi-latest',
    keyUrl: 'platform.moonshot.cn',
    note: '长文本场景合适，kimi-latest 自动指向当前主推模型。',
  ),
  AiPreset(
    id: 'zhipu',
    label: '智谱 GLM',
    protocol: AiProtocol.openai,
    baseUrl: 'https://open.bigmodel.cn/api/paas/v4',
    defaultModel: 'glm-4-plus',
    keyUrl: 'open.bigmodel.cn',
    note: 'GLM 系列，glm-4-flash 有免费额度。',
  ),
  AiPreset(
    id: 'siliconflow',
    label: '硅基流动 SiliconFlow',
    protocol: AiProtocol.openai,
    baseUrl: 'https://api.siliconflow.cn/v1',
    defaultModel: 'deepseek-ai/DeepSeek-V3',
    keyUrl: 'cloud.siliconflow.cn',
    note: '聚合多家开源模型，模型名要带前缀（deepseek-ai/…）。',
  ),
  AiPreset(
    id: 'openai',
    label: 'OpenAI',
    protocol: AiProtocol.openai,
    baseUrl: 'https://api.openai.com/v1',
    defaultModel: 'gpt-4o-mini',
    keyUrl: 'platform.openai.com',
    note: '国内直连通常不通，需要自备代理地址。',
  ),
  AiPreset(
    id: 'anthropic',
    label: 'Anthropic Claude',
    protocol: AiProtocol.anthropic,
    baseUrl: 'https://api.anthropic.com',
    defaultModel: 'claude-sonnet-4-5',
    keyUrl: 'console.anthropic.com',
    note: '走 Messages 协议，和 OpenAI 兼容格式不同。',
  ),
  AiPreset(
    id: 'gemini',
    label: 'Google Gemini',
    protocol: AiProtocol.gemini,
    baseUrl: 'https://generativelanguage.googleapis.com/v1beta',
    defaultModel: 'gemini-2.5-flash',
    keyUrl: 'aistudio.google.com',
    note: '有免费额度，国内需代理。',
  ),
  AiPreset(
    id: 'openrouter',
    label: 'OpenRouter',
    protocol: AiProtocol.openai,
    baseUrl: 'https://openrouter.ai/api/v1',
    defaultModel: 'anthropic/claude-sonnet-4.5',
    keyUrl: 'openrouter.ai',
    note: '一个 Key 调多家模型，模型名形如 vendor/model。',
  ),
  AiPreset(
    id: 'ollama',
    label: '本地 / 局域网（Ollama、LM Studio）',
    protocol: AiProtocol.openai,
    baseUrl: 'http://192.168.1.10:11434/v1',
    defaultModel: 'qwen2.5:7b',
    requiresKey: false,
    note: '填电脑的局域网 IP，手机与电脑需同一网络；可留空 Key。',
  ),
  AiPreset(
    id: 'custom',
    label: '自定义（OpenAI 兼容）',
    protocol: AiProtocol.openai,
    baseUrl: '',
    defaultModel: '',
    note: '任何兼容 /chat/completions 的服务，含公司内网网关。',
  ),
];

AiPreset presetById(String id) {
  for (final preset in aiPresets) {
    if (preset.id == id) return preset;
  }
  return aiPresets.last;
}

/// Everything needed to talk to one endpoint.
class AiConfig {
  const AiConfig({
    this.presetId = 'deepseek',
    this.protocol = AiProtocol.openai,
    this.baseUrl = 'https://api.deepseek.com/v1',
    this.model = 'deepseek-chat',
    this.apiKey = '',
    this.includeNoteContext = true,
    this.outputTemplate = '',
    this.searchApiKey = '',
    this.searchProvider = SearchProvider.tavily,
    this.writePolicy = AgentWritePolicy.ask,
  });

  final String presetId;
  final AiProtocol protocol;
  final String baseUrl;
  final String model;
  final String apiKey;

  /// Whether the active note (and the vault outline) is prepended to the
  /// prompt. Turning this off makes the assistant answer from the question
  /// alone — useful for "translate this" style asks that do not need the note.
  final bool includeNoteContext;

  /// Optional output-format template. When non-empty, it is prepended to the
  /// agent's system prompt so every answer follows the same shape — a Markdown
  /// table, three bullet points with sources, "结论先行" and so on. Empty means
  /// the built-in default ("中文、短句、先给结论") applies.
  final String outputTemplate;

  /// Optional API key for a web-search provider. Which provider that key
  /// belongs to is decided by [searchProvider]; when Tavily is selected and
  /// this is empty, `web_search` falls back to a keyless DuckDuckGo HTML
  /// scrape. Kept separate from [apiKey] because the search provider is
  /// independent of the chat endpoint.
  final String searchApiKey;

  /// Which search backend [searchApiKey] is for. Defaults to [SearchProvider.tavily].
  final SearchProvider searchProvider;

  /// How much Agent mode may write without asking. Defaults to
  /// [AgentWritePolicy.ask] — one "yes" per write, never a blanket grant.
  final AgentWritePolicy writePolicy;

  AiConfig copyWith({
    String? presetId,
    AiProtocol? protocol,
    String? baseUrl,
    String? model,
    String? apiKey,
    bool? includeNoteContext,
    String? outputTemplate,
    String? searchApiKey,
    SearchProvider? searchProvider,
    AgentWritePolicy? writePolicy,
  }) {
    return AiConfig(
      presetId: presetId ?? this.presetId,
      protocol: protocol ?? this.protocol,
      baseUrl: baseUrl ?? this.baseUrl,
      model: model ?? this.model,
      apiKey: apiKey ?? this.apiKey,
      includeNoteContext: includeNoteContext ?? this.includeNoteContext,
      outputTemplate: outputTemplate ?? this.outputTemplate,
      searchApiKey: searchApiKey ?? this.searchApiKey,
      searchProvider: searchProvider ?? this.searchProvider,
      writePolicy: writePolicy ?? this.writePolicy,
    );
  }

  /// A usable config needs an endpoint and a model; the key is optional only
  /// for local servers, which is why it is not part of this check.
  bool get isUsable => baseUrl.trim().isNotEmpty && model.trim().isNotEmpty;

  /// True when the endpoint looks like a local/LAN server, which is the one
  /// case where an empty key is legitimate.
  bool get isLocalEndpoint {
    final url = baseUrl.toLowerCase();
    return url.contains('127.0.0.1') ||
        url.contains('localhost') ||
        url.contains('10.0.2.2') ||
        url.contains('192.168.') ||
        url.contains('172.16.') ||
        url.contains('172.17.') ||
        url.contains('172.18.') ||
        url.contains('.local');
  }

  bool get needsKey => !isLocalEndpoint;

  /// Short label for the app bar, e.g. "DeepSeek · deepseek-chat".
  ///
  /// When the base URL no longer matches the chosen preset, the host is shown
  /// instead of the preset name — otherwise a self-hosted or LAN endpoint would
  /// still be labelled "DeepSeek" and hide where the requests really go.
  String get shortLabel {
    final preset = presetById(presetId);
    final host = Uri.tryParse(baseUrl.trim())?.host ?? '';
    final presetHost = Uri.tryParse(preset.baseUrl.trim())?.host ?? '';
    final isCustom = host.isNotEmpty && host != presetHost;
    final name = isCustom ? host : preset.label.split('（').first;
    final suffix = model.trim().isEmpty ? '' : ' · ${model.trim()}';
    return '$name$suffix';
  }

  Map<String, Object?> toMap() => {
        'presetId': presetId,
        'protocol': protocol.name,
        'baseUrl': baseUrl,
        'model': model,
        'apiKey': apiKey,
        'includeNoteContext': includeNoteContext,
        'outputTemplate': outputTemplate,
        'searchApiKey': searchApiKey,
        'searchProvider': searchProvider.name,
        'writePolicy': writePolicy.name,
      };

  static AiConfig fromMap(Map<String, Object?> map) {
    final presetId = (map['presetId'] as String?) ?? 'deepseek';
    final protocolName = map['protocol'] as String?;
    final providerName = map['searchProvider'] as String?;
    final writePolicyName = map['writePolicy'] as String?;
    return AiConfig(
      presetId: presetId,
      protocol: AiProtocol.values.firstWhere(
        (p) => p.name == protocolName,
        orElse: () => presetById(presetId).protocol,
      ),
      baseUrl: (map['baseUrl'] as String?) ?? '',
      model: (map['model'] as String?) ?? '',
      apiKey: (map['apiKey'] as String?) ?? '',
      includeNoteContext: (map['includeNoteContext'] as bool?) ?? true,
      outputTemplate: (map['outputTemplate'] as String?) ?? '',
      searchApiKey: (map['searchApiKey'] as String?) ?? '',
      searchProvider: SearchProvider.values.firstWhere(
        (p) => p.name == providerName,
        orElse: () => SearchProvider.tavily,
      ),
      writePolicy: AgentWritePolicy.values.firstWhere(
        (p) => p.name == writePolicyName,
        orElse: () => AgentWritePolicy.ask,
      ),
    );
  }
}

/// One turn of the conversation.
class AiMessage {
  const AiMessage({required this.role, required this.content, this.error = false});

  /// `user`, `assistant` or `system`.
  final String role;
  final String content;

  /// Set when this assistant bubble is actually an error report, so the UI can
  /// render it in the error colour instead of as an answer.
  final bool error;

  bool get isUser => role == 'user';

  AiMessage copyWith({String? content, bool? error}) => AiMessage(
        role: role,
        content: content ?? this.content,
        error: error ?? this.error,
      );

  Map<String, Object?> toMap() => {
        'role': role,
        'content': content,
        'error': error,
      };

  static AiMessage fromMap(Map<String, Object?> map) => AiMessage(
        role: (map['role'] as String?) ?? 'user',
        content: (map['content'] as String?) ?? '',
        error: (map['error'] as bool?) ?? false,
      );
}
