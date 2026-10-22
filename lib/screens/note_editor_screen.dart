import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../models/note.dart';
import '../providers/vault_provider.dart';
import '../widgets/note_markdown.dart';

class NoteEditorScreen extends ConsumerStatefulWidget {
  final Note note;

  const NoteEditorScreen({super.key, required this.note});

  @override
  ConsumerState<NoteEditorScreen> createState() => _NoteEditorScreenState();
}

class _NoteEditorScreenState extends ConsumerState<NoteEditorScreen> {
  late final TextEditingController _title;
  late final TextEditingController _body;
  bool _dirty = false;
  bool _preview = false;

  @override
  void initState() {
    super.initState();
    _title = TextEditingController(
      text: widget.note.frontmatter['title']?.toString() ?? widget.note.title,
    );
    _body = TextEditingController(text: widget.note.body);
    _title.addListener(_markDirty);
    _body.addListener(_markDirty);
  }

  void _markDirty() {
    if (!_dirty) setState(() => _dirty = true);
  }

  @override
  void dispose() {
    _title.dispose();
    _body.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    final frontmatter = Map<String, dynamic>.from(widget.note.frontmatter);
    final title = _title.text.trim();
    if (title.isNotEmpty) {
      frontmatter['title'] = title;
    } else {
      frontmatter.remove('title');
    }

    final note = Note(
      relativePath: widget.note.relativePath,
      title: title.isEmpty ? widget.note.title : title,
      frontmatter: frontmatter,
      body: _body.text,
      modified: DateTime.now(),
    );

    await ref.read(vaultProvider.notifier).saveNote(note);
    if (!mounted) return;
    setState(() => _dirty = false);
    Navigator.of(context).pop();
  }

  Future<bool> _confirmDiscard() async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('放弃修改？'),
        content: const Text('当前笔记有未保存的修改，确定放弃吗？'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('继续编辑'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('放弃'),
          ),
        ],
      ),
    );
    return ok ?? false;
  }

  @override
  Widget build(BuildContext context) {
    return PopScope(
      canPop: !_dirty,
      onPopInvokedWithResult: (didPop, result) async {
        if (didPop) return;
        final leave = await _confirmDiscard();
        if (leave && context.mounted) Navigator.of(context).pop();
      },
      child: Scaffold(
        appBar: AppBar(
          title: const Text('编辑笔记'),
          actions: [
            IconButton(
              tooltip: _preview ? '返回编辑' : '预览',
              icon: Icon(_preview ? Icons.edit_outlined : Icons.visibility_outlined),
              onPressed: () => setState(() => _preview = !_preview),
            ),
            IconButton(
              tooltip: '保存',
              icon: const Icon(Icons.check_rounded),
              onPressed: _save,
            ),
          ],
        ),
        body: Padding(
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 16),
          child: _preview
              ? SingleChildScrollView(
                  child: NoteMarkdown(
                    body: _body.text,
                    onWikilinkTap: (target) {
                      ScaffoldMessenger.of(context).showSnackBar(
                        SnackBar(content: Text('预览模式：[[$target]]')),
                      );
                    },
                  ),
                )
              : Column(
                  children: [
                    TextField(
                      controller: _title,
                      style: const TextStyle(
                        fontSize: 20,
                        fontWeight: FontWeight.w700,
                      ),
                      decoration: const InputDecoration(
                        hintText: '标题',
                        border: InputBorder.none,
                      ),
                    ),
                    const Divider(height: 1),
                    Expanded(
                      child: TextField(
                        controller: _body,
                        maxLines: null,
                        expands: true,
                        textAlignVertical: TextAlignVertical.top,
                        keyboardType: TextInputType.multiline,
                        style: const TextStyle(fontFamily: 'monospace', height: 1.5),
                        decoration: const InputDecoration(
                          hintText: '开始用 Markdown 写作…（支持 [[双向链接]]）',
                          border: InputBorder.none,
                        ),
                      ),
                    ),
                  ],
                ),
        ),
      ),
    );
  }
}
