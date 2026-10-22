import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

import '../../models/ai_config.dart';
import '../../models/note.dart';
import '../markdown_service.dart';
import '../vault_service.dart';
import 'agent_tool.dart';

/// The tool belt handed to the model — the phone-side equivalent of what the
/// desktop agent gets from its CLI, minus `execute`.
///
/// Names follow the desktop agent's vocabulary (`read`, `grep`, `edit`, …) so a
/// prompt written for the desktop still makes sense here, but each one is
/// implemented against the vault directory: no process, no shell, and only two
/// network tools — [fetchUrl] (read a given page) and `web_search` (look up
/// keywords), both plain HTTP.
List<AgentTool> buildVaultTools(
  VaultService vault, {
  String? searchApiKey,
  SearchProvider? searchProvider,
}) {
  return [
    _listNotes(vault),
    _readNote(vault),
    _searchNotes(vault),
    _noteMeta(vault),
    _createNote(vault),
    _editNote(vault),
    _appendNote(vault),
    _fetchUrl(),
    _webSearch(
      searchApiKey: searchApiKey,
      searchProvider: searchProvider ?? SearchProvider.tavily,
    ),
  ]..sort((a, b) => a.name.compareTo(b.name));
}

// ---------------------------------------------------------------- read side

AgentTool _listNotes(VaultService vault) => AgentTool(
      name: 'list_notes',
      description: '列出知识库里的笔记路径和标题。pattern 是 glob（如 `*.md`、`Skill*`、'
          '`自媒体/**`），省略则列出全部。type 按分类过滤（frontmatter 的 type），'
          '例如 type="Skill" 只列 SOP 类笔记。结果按修改时间倒序，最多 200 条。',
      parameters: {
        'type': 'object',
        'properties': {
          'pattern': {'type': 'string', 'description': '可选的 glob 过滤'},
          'type': {
            'type': 'string',
            'description': '可选，按分类精确过滤（frontmatter 的 type），如 `Skill`',
          },
          'limit': {'type': 'integer', 'description': '返回条数上限，默认 80'},
        },
      },
      run: (raw) async {
        final args = ToolArgs(raw);
        final pattern = args.str('pattern');
        // Compared case-insensitively, but echoed back as typed — the header is
        // read by a model, and "分类 skill" looks like a typo next to "Skill".
        final rawType = args.str('type')?.trim();
        final typeFilter = rawType?.toLowerCase();
        final limit = (args.integer('limit') ?? 80).clamp(1, 200);
        final regex = pattern == null ? null : _globToRegExp(pattern);

        final notes = vault.loadNotes();
        final hits = <String>[];
        for (final note in notes) {
          if (regex != null && !regex.hasMatch(note.relativePath)) continue;
          if (typeFilter != null &&
              (note.noteType ?? '').trim().toLowerCase() != typeFilter) {
            continue;
          }
          hits.add('${note.relativePath}\t${note.title}');
          if (hits.length >= limit) break;
        }
        if (hits.isEmpty) {
          final filter = pattern ??
              (rawType == null ? null : '分类 `$rawType`');
          return AgentToolResult(
            filter == null ? '知识库是空的。' : '没有匹配 $filter 的笔记。',
          );
        }
        final header = '共 ${notes.length} 篇，显示 ${hits.length} 篇'
            '${rawType == null ? '' : '（分类 $rawType）'}：';
        return AgentToolResult('$header\n${hits.join('\n')}');
      },
    );

AgentTool _readNote(VaultService vault) => AgentTool(
      name: 'read_note',
      description: '读取一篇笔记的完整内容（含 frontmatter）。path 用 list_notes '
          '返回的相对路径。长笔记可用 offset/limit 分段读（按行）。',
      parameters: {
        'type': 'object',
        'properties': {
          'path': {'type': 'string', 'description': '相对知识库根的路径，如 `Skill.md`'},
          'offset': {'type': 'integer', 'description': '起始行号，从 1 开始'},
          'limit': {'type': 'integer', 'description': '最多读多少行，默认 400'},
        },
        'required': ['path'],
      },
      run: (raw) async {
        final args = ToolArgs(raw);
        final rel = _safeRelative(vault, args.require('path'));
        final file = File(p.join(vault.rootPath, rel));
        if (!file.existsSync()) {
          throw ToolError(_notFoundMessage(vault, rel));
        }
        final size = file.lengthSync();
        if (size > 2 * 1024 * 1024) {
          throw ToolError('`$rel` 有 ${(size / 1024).round()} KB，太大，不适合整篇读取。');
        }
        final lines = const LineSplitter().convert(file.readAsStringSync());
        final offset = (args.integer('offset') ?? 1).clamp(1, lines.length + 1);
        final limit = (args.integer('limit') ?? 400).clamp(1, 2000);
        final slice = lines.skip(offset - 1).take(limit).toList();
        final more = offset - 1 + slice.length < lines.length
            ? '\n…还有 ${lines.length - offset + 1 - slice.length} 行，'
                '接着读用 offset=${offset + slice.length}'
            : '';
        return AgentToolResult('$rel（共 ${lines.length} 行）\n'
            '${slice.join('\n')}$more');
      },
    );

AgentTool _searchNotes(VaultService vault) => AgentTool(
      name: 'search_notes',
      description: '在全部笔记的正文里搜索。默认按纯文本包含匹配，regex=true 时按正则。'
          '返回 `路径:行号: 内容`，最多 60 条。',
      parameters: {
        'type': 'object',
        'properties': {
          'query': {'type': 'string', 'description': '要搜的文字或正则'},
          'regex': {'type': 'boolean', 'description': '是否按正则解释 query'},
          'max_results': {'type': 'integer', 'description': '默认 60'},
        },
        'required': ['query'],
      },
      run: (raw) async {
        final args = ToolArgs(raw);
        final query = args.require('query');
        final useRegex = args.boolean('regex');
        final max = (args.integer('max_results') ?? 60).clamp(1, 200);

        RegExp matcher;
        if (useRegex) {
          try {
            matcher = RegExp(query);
          } on FormatException catch (e) {
            throw ToolError('正则写错了：${e.message}');
          }
        } else {
          matcher = RegExp(RegExp.escape(query));
        }

        final hits = <String>[];
        for (final note in vault.loadNotes()) {
          if (hits.length >= max) break;
          final lines = const LineSplitter().convert(note.body);
          for (var i = 0; i < lines.length; i++) {
            if (!matcher.hasMatch(lines[i])) continue;
            final text = lines[i].trim();
            hits.add('${note.relativePath}:${i + 1}: '
                '${text.length > 160 ? '${text.substring(0, 160)}…' : text}');
            if (hits.length >= max) break;
          }
        }
        if (hits.isEmpty) return AgentToolResult('没有找到「$query」。');
        final tail = hits.length >= max ? '\n（已截断，可加 max_results 或缩小范围）' : '';
        return AgentToolResult('${hits.length} 条命中：\n${hits.join('\n')}$tail');
      },
    );

AgentTool _noteMeta(VaultService vault) => AgentTool(
      name: 'note_meta',
      description: '读取一篇笔记的 frontmatter（type / tags / status / _archived 等），'
          '返回值已按 Tolaria 的键名归一化。',
      parameters: {
        'type': 'object',
        'properties': {
          'path': {'type': 'string'},
        },
        'required': ['path'],
      },
      run: (raw) async {
        final rel = _safeRelative(vault, ToolArgs(raw).require('path'));
        final note = vault.findNote(rel);
        if (note == null) throw ToolError('找不到 `$rel`。');
        final meta = <String, dynamic>{
          'path': note.relativePath,
          'title': note.title,
          'type': note.noteType,
          'archived': note.isArchived,
          'modified': note.modified?.toIso8601String(),
          'words': note.body.runes.length,
          'frontmatter': note.frontmatter,
        };
        return AgentToolResult(const JsonEncoder.withIndent('  ').convert(meta));
      },
    );

// --------------------------------------------------------------- write side

AgentTool _createNote(VaultService vault) => AgentTool(
      name: 'create_note',
      description: '新建一篇笔记。title 会被转成文件名；body 是 Markdown 正文；'
          'type 会写进 frontmatter。同名文件已存在时自动加 `-2` 后缀，不会覆盖任何东西。',
      parameters: {
        'type': 'object',
        'properties': {
          'title': {'type': 'string'},
          'body': {'type': 'string'},
          'type': {'type': 'string', 'description': '分类，写进 frontmatter 的 type:'},
        },
        'required': ['title'],
      },
      writes: true,
      run: (raw) async {
        final args = ToolArgs(raw);
        final title = args.require('title').trim();
        if (title.isEmpty) throw const ToolError('title 不能为空。');
        final body = args.str('body') ?? '';
        final type = args.str('type');

        final note = vault.createNote(title);
        if (body.isNotEmpty) {
          // `createNote` seeds `# title`; keep the heading and append the body
          // without re-serialising the rest of the file.
          final file = File(p.join(vault.rootPath, note.relativePath));
          final head = MarkdownService.parse(file.readAsStringSync()).frontmatter;
          vault.saveNote(Note(
            relativePath: note.relativePath,
            title: title,
            frontmatter: head,
            body: '# $title\n\n$body',
          ));
        }
        if (type != null) vault.setType(note.relativePath, type);
        return AgentToolResult('已创建 `${note.relativePath}`'
            '${type == null ? '' : '，分类「$type」'}。');
      },
    );

AgentTool _editNote(VaultService vault) => AgentTool(
      name: 'edit_note',
      description: '把笔记里的一段文字替换掉。old_string 必须在文件中**唯一出现**，'
          '否则报错（避免改错地方）。只改命中的那一段，文件其它字节原样保留。',
      parameters: {
        'type': 'object',
        'properties': {
          'path': {'type': 'string'},
          'old_string': {'type': 'string', 'description': '要替换的原文字，需精确匹配'},
          'new_string': {'type': 'string', 'description': '替换成什么'},
        },
        'required': ['path', 'old_string', 'new_string'],
      },
      writes: true,
      run: (raw) async {
        final args = ToolArgs(raw);
        final rel = _safeRelative(vault, args.require('path'));
        final oldText = args.require('old_string');
        final newText = args.str('new_string') ?? '';
        if (oldText.isEmpty) throw const ToolError('old_string 不能为空。');

        final file = File(p.join(vault.rootPath, rel));
        if (!file.existsSync()) throw ToolError('找不到 `$rel`。');
        final raw0 = file.readAsStringSync();

        final count = _countOccurrences(raw0, oldText);
        if (count == 0) {
          throw ToolError('在 `$rel` 里没找到这段文字。先用 read_note 看一下实际内容。');
        }
        if (count > 1) {
          throw ToolError('这段文字在 `$rel` 里出现了 $count 次，改哪一处不确定。'
              '把 old_string 写长一点，带上上下文再试。');
        }

        final updated = raw0.replaceFirst(oldText, newText);
        file.writeAsStringSync(updated);
        final line = raw0.substring(0, raw0.indexOf(oldText)).split('\n').length;
        return AgentToolResult('已修改 `$rel` 第 $line 行附近'
            '（${oldText.length} → ${newText.length} 字符）。');
      },
    );

AgentTool _appendNote(VaultService vault) => AgentTool(
      name: 'append_note',
      description: '在笔记末尾追加内容（不覆盖原有内容）。',
      parameters: {
        'type': 'object',
        'properties': {
          'path': {'type': 'string'},
          'text': {'type': 'string'},
        },
        'required': ['path', 'text'],
      },
      writes: true,
      run: (raw) async {
        final args = ToolArgs(raw);
        final rel = _safeRelative(vault, args.require('path'));
        final text = args.require('text');
        final file = File(p.join(vault.rootPath, rel));
        if (!file.existsSync()) throw ToolError('找不到 `$rel`。');
        final existing = file.readAsStringSync();
        final glue = existing.isEmpty || existing.endsWith('\n') ? '' : '\n';
        file.writeAsStringSync('$existing$glue$text');
        return AgentToolResult('已在 `$rel` 末尾追加 ${text.length} 字符。');
      },
    );

// ------------------------------------------------------------------ network

AgentTool _fetchUrl() => AgentTool(
      name: 'fetch_url',
      description: '抓取一个网页并转成纯文本（去标签）。只支持 http/https，'
          '内容超过 6000 字符会被截断。用来读用户给的链接。',
      parameters: {
        'type': 'object',
        'properties': {
          'url': {'type': 'string'},
        },
        'required': ['url'],
      },
      run: (raw) async {
        final url = ToolArgs(raw).require('url');
        final uri = Uri.tryParse(url);
        if (uri == null || !(uri.isScheme('http') || uri.isScheme('https'))) {
          throw const ToolError('只支持 http/https 链接。');
        }
        final client = HttpClient()..connectionTimeout = const Duration(seconds: 20);
        try {
          final request = await client.getUrl(uri);
          request.headers.set(HttpHeaders.userAgentHeader, 'TolariaAndroid/agent');
          final response = await request.close();
          if (response.statusCode >= 400) {
            throw ToolError('抓取失败：HTTP ${response.statusCode}');
          }
          // 老页面常是 GBK/GB2312 等非 UTF-8 编码。流式 utf8.decoder 遇到非法
          // 字节会直接抛 FormatException 让整个工具失败；先收齐字节再宽松解码，
          // 坏字节降级为替换符（U+FFFD），正文里通常仍可读。
          final bytes = await response.fold<List<int>>(
            <int>[],
            (acc, chunk) => acc..addAll(chunk),
          );
          final body = utf8.decode(bytes, allowMalformed: true);
          final text = _htmlToText(body);
          final clipped =
              text.length > 6000 ? '${text.substring(0, 6000)}\n…（已截断）' : text;
          return AgentToolResult(clipped.isEmpty ? '（页面没有可读正文）' : clipped);
        } finally {
          client.close(force: true);
        }
      },
    );

// ------------------------------------------------------------------ helpers

/// Resolve a model-supplied path against the vault root, refusing anything that
/// escapes it. A model that hallucinates `../../etc/passwd` gets an error, not
/// a file.
String _safeRelative(VaultService vault, String input) {
  var rel = input.trim().replaceAll('\\', '/');
  if (rel.startsWith('/') || RegExp(r'^[A-Za-z]:').hasMatch(rel)) {
    throw const ToolError('请用相对知识库根的路径，例如 `Skill.md`，不要用绝对路径。');
  }
  while (rel.startsWith('./')) {
    rel = rel.substring(2);
  }
  final segments = rel.split('/');
  if (segments.any((s) => s == '..')) {
    throw const ToolError('路径不能包含 `..`。');
  }
  if (segments.first == '.git' || rel.contains('/.git/')) {
    throw const ToolError('不能访问 `.git` 目录。');
  }
  final joined = p.normalize(p.join(vault.rootPath, rel));
  final root = p.normalize(vault.rootPath);
  if (!p.isWithin(root, joined) && joined != root) {
    throw const ToolError('路径超出知识库范围。');
  }
  if (!joined.toLowerCase().endsWith('.md')) {
    throw const ToolError('只能读写 `.md` 笔记。');
  }
  return p.relative(joined, from: root).replaceAll('\\', '/');
}

int _countOccurrences(String haystack, String needle) {
  var count = 0;
  var index = haystack.indexOf(needle);
  while (index != -1) {
    count++;
    index = haystack.indexOf(needle, index + needle.length);
  }
  return count;
}

/// Answer for a path that does not exist, with the real ones attached.
///
/// The most common tool mistake is inventing a folder prefix — the vault is
/// flat, but a model that just called `list_notes(type: "Skill")` happily asks
/// for `Skill1/短视频带货脚本 SOP.md`. Plain "not found" makes it retry the same
/// wrong string; naming the closest real paths turns a dead end into one more
/// step.
String _notFoundMessage(VaultService vault, String rel) {
  final wanted = p.basename(rel).toLowerCase().trim();
  final bare = wanted.endsWith('.md')
      ? wanted.substring(0, wanted.length - 3).trim()
      : wanted;

  final exact = <String>[];
  final loose = <String>[];
  for (final note in vault.loadNotes()) {
    final file = note.fileName.toLowerCase().trim();
    final title = note.title.toLowerCase().trim();
    if (file == wanted || title == wanted || (bare.isNotEmpty && title == bare)) {
      exact.add(note.relativePath);
    } else if (bare.length >= 4 && (file.contains(bare) || title.contains(bare))) {
      // Short fragments ("脚本") match half the vault and would only add noise.
      loose.add(note.relativePath);
    }
  }

  final picks = [...exact, ...loose].take(3).toList();
  if (picks.isEmpty) {
    return '找不到 `$rel`。路径必须用 list_notes 或 search_notes 返回的原样相对路径，'
        '不要自己加目录前缀。';
  }
  return '找不到 `$rel`。路径必须用 list_notes / search_notes 返回的原样相对路径。'
      '可能你想读的是：${picks.map((path) => '`$path`').join('、')}';
}

/// Minimal glob → regexp: `**` crosses directories, `*` and `?` do not.
RegExp _globToRegExp(String glob) {
  final buffer = StringBuffer('^');
  for (var i = 0; i < glob.length; i++) {
    final char = glob[i];
    if (char == '*') {
      if (i + 1 < glob.length && glob[i + 1] == '*') {
        buffer.write('.*');
        i++;
      } else {
        buffer.write('[^/]*');
      }
    } else if (char == '?') {
      buffer.write('[^/]');
    } else {
      buffer.write(RegExp.escape(char));
    }
  }
  buffer.write(r'$');
  return RegExp(buffer.toString());
}

/// Crude HTML → text: drop script/style bodies, then tags, then squeeze space.
/// Good enough for "read this page and summarise it"; not a renderer.
String _htmlToText(String html) {
  var text = html
      .replaceAll(RegExp(r'<script[\s\S]*?</script>', caseSensitive: false), ' ')
      .replaceAll(RegExp(r'<style[\s\S]*?</style>', caseSensitive: false), ' ')
      .replaceAll(RegExp(r'<br\s*/?>', caseSensitive: false), '\n')
      .replaceAll(RegExp(r'</(p|div|li|h[1-6])>', caseSensitive: false), '\n')
      .replaceAll(RegExp(r'<[^>]+>'), ' ')
      .replaceAll('&nbsp;', ' ')
      .replaceAll('&amp;', '&')
      .replaceAll('&lt;', '<')
      .replaceAll('&gt;', '>')
      .replaceAll('&quot;', '"')
      .replaceAll('&#39;', "'");
  text = text
      .split('\n')
      .map((line) => line.replaceAll(RegExp(r'[ \t]+'), ' ').trim())
      .where((line) => line.isNotEmpty)
      .join('\n');
  return text.trim();
}

/// Sanity check used by tests and the settings screen: the tool names the
/// prompt advertises must match what actually exists.
const agentToolNames = <String>[
  'append_note',
  'create_note',
  'edit_note',
  'fetch_url',
  'list_notes',
  'note_meta',
  'read_note',
  'search_notes',
  'web_search',
];

/// Frontmatter-aware summary used when the model asks "what is this vault".
String describeVault(VaultService vault) {
  final notes = vault.loadNotes();
  final types = <String, int>{};
  var archived = 0;
  for (final note in notes) {
    if (note.isArchived) archived++;
    final type = note.noteType;
    if (type == null) continue;
    types[type] = (types[type] ?? 0) + 1;
  }
  final topTypes = types.entries.toList()
    ..sort((a, b) => b.value.compareTo(a.value));
  final summary = topTypes.take(8).map((e) => '${e.key} ${e.value} 篇').join('、');
  return '知识库共 ${notes.length} 篇笔记（$archived 篇已归档）。'
      '${summary.isEmpty ? '' : '分类：$summary。'}';
}

// -------------------------------------------------------------- web search

/// Active web search: the model supplies keywords and gets back a list of
/// results (title + url + snippet), which it can cite in an answer. The
/// backend is chosen by [searchProvider]: Tavily (with a key; falls back to a
/// keyless DuckDuckGo scrape when no key is set) or BoCha (Chinese-native,
/// needs a key).
AgentTool _webSearch({
  String? searchApiKey,
  SearchProvider searchProvider = SearchProvider.tavily,
}) =>
    AgentTool(
      name: 'web_search',
      description: '在互联网上搜索关键词，返回相关网页的标题、链接和摘要，'
          '用来补充知识库里没有的外部信息。'
          '适合「查一下 XX 的最新资料」「网上怎么讲 X」「XX 的官方定义」这类需求。'
          'query 是搜索词；max_results 控制返回条数（默认 5，最多 10）。',
      parameters: {
        'type': 'object',
        'properties': {
          'query': {'type': 'string', 'description': '要搜索的关键词'},
          'max_results': {
            'type': 'integer',
            'description': '返回条数，默认 5，最多 10',
          },
        },
        'required': ['query'],
      },
      run: (raw) async {
        final args = ToolArgs(raw);
        final query = args.require('query');
        final max = (args.integer('max_results') ?? 5).clamp(1, 10);
        final key = searchApiKey?.trim() ?? '';
        if (searchProvider == SearchProvider.bocha) {
          if (key.isEmpty) {
            return const AgentToolResult.error('搜索失败：未配置博查（BoCha）API Key。'
                '请在 AI 设置里选择博查并填一个博查 Key。');
          }
          return _bochaSearch(query, max, key);
        }
        // Tavily (default): key → Tavily API; no key → keyless DuckDuckGo.
        if (key.isNotEmpty) {
          return _tavilySearch(query, max, key);
        }
        return _duckSearch(query, max);
      },
    );

Future<AgentToolResult> _tavilySearch(
  String query,
  int max,
  String key,
) async {
  final client = HttpClient()..connectionTimeout = const Duration(seconds: 20);
  try {
    final request = await client.postUrl(Uri.parse('https://api.tavily.com/search'));
    request.headers.set(HttpHeaders.contentTypeHeader, 'application/json');
    request.headers.set(HttpHeaders.acceptHeader, 'application/json');
    final body = utf8.encode(jsonEncode({
      'api_key': key,
      'query': query,
      'max_results': max,
      'search_depth': 'basic',
    }));
    request.contentLength = body.length;
    request.add(body);
    final response = await request.close();
    final raw = await response.transform(utf8.decoder).join();
    if (response.statusCode >= 400) {
      return AgentToolResult.error('搜索失败：HTTP ${response.statusCode}');
    }
    final decoded = jsonDecode(raw) as Map<String, dynamic>;
    final results = (decoded['results'] as List?) ?? const [];
    if (results.isEmpty) {
      return AgentToolResult('没有找到关于「$query」的结果。');
    }
    final lines = <String>[];
    for (final r in results.take(max)) {
      final m = r as Map<String, dynamic>;
      final title = (m['title'] ?? '').toString();
      final url = (m['url'] ?? '').toString();
      final content =
          (m['content'] ?? '').toString().replaceAll(RegExp(r'\s+'), ' ');
      final clipped =
          content.length > 300 ? '${content.substring(0, 300)}…' : content;
      lines.add('• $title\n  $url\n  $clipped');
    }
    return AgentToolResult('${results.length} 条搜索结果：\n\n${lines.join('\n\n')}');
  } finally {
    client.close(force: true);
  }
}

/// BoCha web search (https://bochaai.com): Chinese-native, low latency inside
/// CN. Returns structured JSON; parsing is factored out into [_parseBocha] so it
/// can be unit-tested without a network call.
Future<AgentToolResult> _bochaSearch(String query, int max, String key) async {
  final client = HttpClient()..connectionTimeout = const Duration(seconds: 20);
  try {
    final request =
        await client.postUrl(Uri.parse('https://api.bochaai.com/v1/web-search'));
    request.headers.set(HttpHeaders.contentTypeHeader, 'application/json');
    request.headers.set(HttpHeaders.acceptHeader, 'application/json');
    request.headers.set(HttpHeaders.authorizationHeader, 'Bearer $key');
    final body = utf8.encode(jsonEncode({
      'query': query,
      'freshness': 'noLimit',
      'summary': false,
      'count': max,
    }));
    request.contentLength = body.length;
    request.add(body);
    final response = await request.close();
    final raw = await response.transform(utf8.decoder).join();
    if (response.statusCode >= 400) {
      return AgentToolResult.error('搜索失败：HTTP ${response.statusCode}');
    }
    return parseBocha(raw, max);
  } finally {
    client.close(force: true);
  }
}

/// Parses a BoCha JSON response into a tool result. Tolerant of both the
/// documented field names (`name`/`url`/`snippet`) and common alternates
/// (`title`/`link`/`description`) in case the API evolves.
AgentToolResult parseBocha(String raw, int max) {
  final decoded = jsonDecode(raw) as Map<String, dynamic>;
  final data = decoded['data'] as Map<String, dynamic>? ?? const {};
  final webPages = data['webPages'] as Map<String, dynamic>? ?? const {};
  final value = webPages['value'] as List? ?? const [];
  if (value.isEmpty) {
    final msg = decoded['msg'] ?? decoded['message'];
    final tail = msg is String && msg.isNotEmpty ? '（$msg）' : '';
    return AgentToolResult('没有找到关于该关键词的结果。$tail');
  }
  final lines = <String>[];
  for (final r in value.take(max)) {
    final m = r as Map<String, dynamic>;
    final title = (_pick(m, ['name', 'title', 'pageTitle']) ?? '').trim();
    final url = (_pick(m, ['url', 'link', 'href']) ?? '').trim();
    if (title.isEmpty && url.isEmpty) continue;
    final snippet = (_pick(m, ['snippet', 'description', 'summary']) ?? '')
        .replaceAll(RegExp(r'\s+'), ' ')
        .trim();
    final clipped =
        snippet.length > 300 ? '${snippet.substring(0, 300)}…' : snippet;
    final snipLine = clipped.isEmpty ? '' : '\n  $clipped';
    lines.add('• $title\n  $url$snipLine');
  }
  if (lines.isEmpty) {
    return const AgentToolResult('没有找到可用的搜索结果。');
  }
  final shown = lines.length;
  final total = value.length;
  final prefix = shown == total
      ? '$shown 条搜索结果'
      : '$shown 条搜索结果（共找到 $total 条，已截断）';
  return AgentToolResult('$prefix：\n\n${lines.join('\n\n')}');
}

/// First non-empty string among [keys], or null. Lets one field name mean
/// several things across provider response shapes.
String? _pick(Map<String, dynamic> map, List<String> keys) {
  for (final key in keys) {
    final value = map[key];
    if (value is String && value.trim().isNotEmpty) return value.trim();
  }
  return null;
}

Future<AgentToolResult> _duckSearch(String query, int max) async {
  final client = HttpClient()..connectionTimeout = const Duration(seconds: 20);
  try {
    final request = await client.getUrl(
      Uri.https('html.duckduckgo.com', '/html/', {'q': query}),
    );
    request.headers.set(
      HttpHeaders.userAgentHeader,
      'Mozilla/5.0 (Linux; Android 13) AppleWebKit/537.36 '
      '(KHTML, like Gecko) Chrome/120.0 Safari/537.36',
    );
    request.headers.set('Accept-Language', 'zh-CN,zh;q=0.9,en;q=0.8');
    final response = await request.close();
    if (response.statusCode >= 400) {
      return AgentToolResult.error('搜索失败：HTTP ${response.statusCode}');
    }
    final body = await response.transform(utf8.decoder).join();
    final results = _parseDuck(body, max);
    if (results.isEmpty) {
      return AgentToolResult(
        '没搜到关于「$query」的结果。DuckDuckGo 可能拦截了来自 App 的请求；'
        '可在 AI 设置里填一个 Tavily 的 Key 来获得稳定的联网搜索。',
      );
    }
    return AgentToolResult(
      '${results.length} 条搜索结果：\n\n${results.join('\n\n')}',
    );
  } finally {
    client.close(force: true);
  }
}

/// DuckDuckGo wraps each organic result in an `<a class="result__a">` title
/// link followed by a sibling `<a class="result__snippet">`. Splitting on the
/// title anchors keeps each snippet paired with the right result.
List<String> _parseDuck(String html, int max) {
  final anchor = RegExp(
    r'<a[^>]*class="result__a"[^>]*href="([^"]*)"[^>]*>([\s\S]*?)</a>'
    r'([\s\S]*?)(?=<a[^>]*class="result__a"|$)',
    caseSensitive: false,
  );
  final out = <String>[];
  for (final m in anchor.allMatches(html)) {
    if (out.length >= max) break;
    final href = m.group(1) ?? '';
    final title = _stripTags(m.group(2) ?? '').trim();
    final block = m.group(3) ?? '';
    final snipM = RegExp(
      r'class="result__snippet"[^>]*>([\s\S]*?)</a>',
      caseSensitive: false,
    ).firstMatch(block);
    final snippet = snipM != null
        ? _stripTags(snipM.group(1) ?? '').replaceAll(RegExp(r'\s+'), ' ').trim()
        : '';
    if (title.isEmpty) continue;
    final url = _decodeDuckUrl(href);
    final snipLine = snippet.isEmpty ? '' : '\n  $snippet';
    out.add('• $title\n  $url$snipLine');
  }
  return out;
}

/// DDG funnels clicks through `/l/?uddg=<encoded url>`; recover the real one.
String _decodeDuckUrl(String href) {
  if (href.contains('uddg=')) {
    final m = RegExp(r'uddg=([^&]+)').firstMatch(href);
    if (m != null) return Uri.decodeComponent(m.group(1)!);
  }
  if (href.startsWith('/')) {
    return 'https://html.duckduckgo.com$href';
  }
  return href;
}

String _stripTags(String html) {
  return html
      .replaceAll(RegExp(r'<[^>]+>'), '')
      .replaceAll('&amp;', '&')
      .replaceAll('&lt;', '<')
      .replaceAll('&gt;', '>')
      .replaceAll('&quot;', '"')
      .replaceAll('&#39;', "'")
      .replaceAll('&nbsp;', ' ')
      .trim();
}

/// Convenience for tests: parse a note's frontmatter without loading the vault.
Map<String, dynamic> peekFrontmatter(String raw) =>
    MarkdownService.parse(raw).frontmatter;
