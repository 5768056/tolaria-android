import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tolaria_android/providers/agent_provider.dart';
import 'package:tolaria_android/widgets/agent_view.dart';

/// The tool card is the only place the user learns what the model did to their
/// files, and the approval dialog is the last chance to say no. Both are
/// checked here rather than on a device, because "the diff was on screen but
/// scrolled off" is not something a device smoke test would catch.
void main() {
  Widget wrap(Widget child) => MaterialApp(home: Scaffold(body: child));

  testWidgets('a running call shows a spinner and the file it touches',
      (tester) async {
    await tester.pumpWidget(wrap(
      const AgentToolCard(
        item: AgentToolItem(
          name: 'read_note',
          arguments: {'path': '自媒体/选题.md'},
        ),
      ),
    ));

    expect(find.text('读取笔记'), findsOneWidget);
    expect(find.text('自媒体/选题.md'), findsOneWidget);
    expect(find.byType(CircularProgressIndicator), findsOneWidget);
    // Collapsed: no argument JSON or result box yet.
    expect(find.text('参数'), findsNothing);
  });

  testWidgets('a finished call is collapsed but opens on tap', (tester) async {
    await tester.pumpWidget(wrap(
      const AgentToolCard(
        item: AgentToolItem(
          name: 'edit_note',
          arguments: {
            'path': 'a.md',
            'old_string': '正文甲',
            'new_string': '正文丙',
          },
          result: '已修改 `a.md` 第 3 行附近（3 → 3 字符）。',
        ),
      ),
    ));

    expect(find.text('改动'), findsOneWidget);
    expect(find.byType(CircularProgressIndicator), findsNothing);
    expect(find.text('原文'), findsNothing);

    await tester.tap(find.text('修改笔记'));
    await tester.pumpAndSettle();

    expect(find.text('原文'), findsOneWidget);
    expect(find.text('改为'), findsOneWidget);
    expect(find.text('正文甲'), findsOneWidget);
    expect(find.text('正文丙'), findsOneWidget);
    expect(find.textContaining('已修改'), findsOneWidget);
  });

  testWidgets('a failed call opens itself so the reason is visible',
      (tester) async {
    await tester.pumpWidget(wrap(
      const AgentToolCard(
        item: AgentToolItem(
          name: 'edit_note',
          arguments: {'path': 'a.md', 'old_string': '没这段', 'new_string': 'x'},
          result: '在 `a.md` 里没找到这段文字。',
          isError: true,
        ),
      ),
    ));

    expect(find.text('失败原因'), findsOneWidget);
    expect(find.textContaining('没找到'), findsOneWidget);
  });

  testWidgets('the approval dialog shows both sides of the change',
      (tester) async {
    bool? answer;
    await tester.pumpWidget(wrap(Builder(
      builder: (context) => TextButton(
        onPressed: () async {
          answer = await showToolApproval(
            context,
            tool: 'edit_note',
            arguments: {
              'path': 'a.md',
              'old_string': '正文甲',
              'new_string': '正文丙',
            },
          );
        },
        child: const Text('触发'),
      ),
    )));

    await tester.tap(find.text('触发'));
    await tester.pumpAndSettle();

    expect(find.text('修改笔记：a.md'), findsOneWidget);
    expect(find.text('原文（将被替换）'), findsOneWidget);
    expect(find.text('改为'), findsOneWidget);
    expect(find.textContaining('正文甲'), findsWidgets);

    await tester.tap(find.text('允许这次改动'));
    await tester.pumpAndSettle();

    expect(answer, isTrue);
  });

  testWidgets('declining the dialog reports false', (tester) async {
    bool? answer;
    await tester.pumpWidget(wrap(Builder(
      builder: (context) => TextButton(
        onPressed: () async {
          answer = await showToolApproval(
            context,
            tool: 'create_note',
            arguments: {'title': '新想法', 'body': '一句话'},
          );
        },
        child: const Text('触发'),
      ),
    )));

    await tester.tap(find.text('触发'));
    await tester.pumpAndSettle();

    expect(find.text('新建笔记：新想法'), findsOneWidget);
    expect(find.textContaining('一句话'), findsWidgets);

    await tester.tap(find.text('不改'));
    await tester.pumpAndSettle();

    expect(answer, isFalse);
  });
}
