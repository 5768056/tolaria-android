/// Tool plumbing for the on-device agent.
///
/// The desktop app drives a local CLI agent (Claude Code / Codex / OpenCode)
/// and lets it use `read` / `grep` / `edit` / `execute`. Android has no shell
/// and no Node, so the agent loop lives in Dart instead and its tools are
/// implemented against the vault directory directly. Everything here is
/// "Vault Safe" by construction: file, search and edit only — there is no
/// tool that can spawn a process.
library;

/// One tool the model may call.
class AgentTool {
  const AgentTool({
    required this.name,
    required this.description,
    required this.parameters,
    required this.run,
    this.writes = false,
  });

  final String name;
  final String description;

  /// JSON Schema for the arguments object.
  final Map<String, dynamic> parameters;

  /// True when the call changes files on disk, so the UI can ask first.
  final bool writes;

  final Future<AgentToolResult> Function(Map<String, dynamic> args) run;

  /// OpenAI-style function schema.
  Map<String, dynamic> toSchema() => {
        'type': 'function',
        'function': {
          'name': name,
          'description': description,
          'parameters': parameters,
        },
      };
}

/// What a tool hands back to the model.
class AgentToolResult {
  const AgentToolResult(this.content, {this.isError = false});

  const AgentToolResult.error(String message) : this(message, isError: true);

  final String content;
  final bool isError;

  @override
  String toString() => content;
}

/// Helpers shared by the tool implementations.
class ToolArgs {
  const ToolArgs(this._raw);

  final Map<String, dynamic> _raw;

  String? str(String key) {
    final value = _raw[key];
    if (value == null) return null;
    final text = value.toString();
    return text.isEmpty ? null : text;
  }

  String require(String key) {
    final value = str(key);
    if (value == null) throw _MissingArg(key);
    return value;
  }

  int? integer(String key) {
    final value = _raw[key];
    if (value is int) return value;
    if (value is num) return value.toInt();
    if (value is String) return int.tryParse(value);
    return null;
  }

  bool boolean(String key, {bool fallback = false}) {
    final value = _raw[key];
    if (value is bool) return value;
    if (value is String) return value.toLowerCase() == 'true';
    return fallback;
  }
}

class _MissingArg implements Exception {
  const _MissingArg(this.key);
  final String key;

  @override
  String toString() => '缺少参数 `$key`';
}

/// Run a tool with argument parsing errors turned into model-visible errors
/// instead of thrown exceptions, so one bad call cannot break the loop.
Future<AgentToolResult> guardToolCall(
  AgentTool tool,
  Map<String, dynamic> args,
) async {
  try {
    return await tool.run(args);
  } on _MissingArg catch (e) {
    return AgentToolResult.error('$e');
  } on ToolError catch (e) {
    return AgentToolResult.error(e.message);
  } catch (e) {
    return AgentToolResult.error('工具执行失败：$e');
  }
}

/// A failure the model should read and recover from (bad path, oversized file).
class ToolError implements Exception {
  const ToolError(this.message);
  final String message;
}
