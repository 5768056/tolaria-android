import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:tolaria_android/screens/ai_chat_screen.dart';

/// Smoke test for the screen shell: which engine it opens with, and whether the
/// switch actually swaps the surface. The agent loop itself is covered by
/// `agent_provider_test.dart` with a scripted endpoint, so nothing here talks to
/// the network.
void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues({});
  });

  Future<void> open(WidgetTester tester) async {
    await tester.pumpWidget(const ProviderScope(
      child: MaterialApp(home: AiChatScreen()),
    ));
    await tester.pumpAndSettle();
  }

  testWidgets('opens in Agent mode and explains what it may do', (tester) async {
    await open(tester);

    // The chip states the current engine.
    expect(find.text('Agent'), findsOneWidget);
    expect(find.text('让 AI 直接动你的笔记'), findsOneWidget);
    expect(find.textContaining('每次改动前都会先问你'), findsOneWidget);
    // Agent-specific prompts, not the generic "总结这篇笔记" ones.
    expect(find.textContaining('哪些还没归档'), findsOneWidget);
    expect(find.text('问点什么…'), findsNothing);
    expect(find.text('让它读、找、改你的笔记…'), findsOneWidget);
  });

  testWidgets('switching to 问答 swaps the empty state', (tester) async {
    await open(tester);

    await tester.tap(find.text('Agent'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('问答'));
    await tester.pumpAndSettle();

    expect(find.text('问问你的知识库'), findsOneWidget);
    expect(find.text('Agent'), findsNothing);
    expect(find.text('让它读、找、改你的笔记…'), findsNothing);
  });

  testWidgets('composer is text-only — no attachment button', (tester) async {
    await open(tester);

    // The models this app talks to are text-only, and the user's flow is
    // "type a request and send it". The composer must not grow an attachment
    // affordance back.
    expect(find.byIcon(Icons.add_circle_outline_rounded), findsNothing);
    expect(find.byTooltip('添加附件'), findsNothing);
    expect(find.byType(TextField), findsOneWidget);

    // And an empty box sends nothing, rather than opening an empty turn.
    await tester.tap(find.byTooltip('发送'));
    await tester.pumpAndSettle();
    expect(find.text('让 AI 直接动你的笔记'), findsOneWidget);
  });
}
