import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tolaria_android/widgets/note_actions.dart';

/// Regression tests for the undo prompt's lifetime.
///
/// Bug report: "移动分类后的撤销提示不会消失，一直存在". Root cause: the
/// framework persists every SnackBar that carries an action button —
/// `SnackBar.persist` defaults to `action != null` — so the 4-second timeout
/// timer is armed and then does nothing. `undoSnackBar` must pin persist to
/// false, which these tests exercise end-to-end through the real
/// ScaffoldMessenger.
void main() {
  Widget host({required VoidCallback onUndo}) {
    return MaterialApp(
      home: Scaffold(
        body: Builder(
          builder: (context) => Center(
            child: ElevatedButton(
              onPressed: () => ScaffoldMessenger.of(context).showSnackBar(
                undoSnackBar(message: '已移到「周期报告」', onUndo: onUndo),
              ),
              child: const Text('move'),
            ),
          ),
        ),
      ),
    );
  }

  testWidgets('undo prompt auto-dismisses after the default 4 seconds',
      (tester) async {
    await tester.pumpWidget(host(onUndo: () {}));

    await tester.tap(find.text('move'));
    await tester.pump(); // entrance animation starts
    await tester.pump(const Duration(seconds: 1)); // entrance (250ms) done
    await tester.pump(); // rebuild arms the 4s timer
    expect(find.text('已移到「周期报告」'), findsOneWidget);
    expect(find.text('撤销'), findsOneWidget);

    // 4s timeout fires; the 250ms exit animation then needs real frames
    // (each pump advances the ticker by one frame interval).
    await tester.pump(const Duration(seconds: 5));
    await tester.pumpAndSettle();
    expect(find.text('已移到「周期报告」'), findsNothing);
    expect(find.text('撤销'), findsNothing);
  });

  testWidgets('tapping 撤销 still fires the callback while the prompt is up',
      (tester) async {
    var undid = false;
    await tester.pumpWidget(host(onUndo: () => undid = true));

    await tester.tap(find.text('move'));
    await tester.pump();
    await tester.pump(const Duration(seconds: 1));
    await tester.pump();

    await tester.tap(find.text('撤销'));
    await tester.pump();
    expect(undid, isTrue);
  });

  test('undoSnackBar pins persist to false even with an action button', () {
    final prompt = undoSnackBar(message: '已移出分类', onUndo: () {});
    expect(prompt.persist, isFalse);
    expect(prompt.action, isNotNull);
    expect(prompt.duration, const Duration(seconds: 4));

    // No undo to offer (e.g. moved back to the same type) — still transient.
    final plain = undoSnackBar(message: '已移出分类');
    expect(plain.persist, isFalse);
    expect(plain.action, isNull);
  });
}
