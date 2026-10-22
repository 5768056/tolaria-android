import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

/// App-level route observer. Registered once in [MaterialApp.navigatorObservers]
/// so screens can react to routes pushed above them.
final RouteObserver<PageRoute<dynamic>> routeObserver =
    RouteObserver<PageRoute<dynamic>>();

/// Hides the current SnackBar as soon as another route is pushed on top.
///
/// Undo prompts ("已移出分类 / 撤销") are shown on the app-level
/// ScaffoldMessenger, so they survive navigation: move a note's category, then
/// open the AI assistant, and the prompt sits there above the keyboard looking
/// like it will never leave. The prompt's job is done the moment the user
/// leaves the screen that produced it — this mixin enforces exactly that.
mixin SnackbarDismissOnNavigate<T extends ConsumerStatefulWidget>
    on ConsumerState<T>
    implements RouteAware {
  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final route = ModalRoute.of(context);
    if (route is PageRoute) routeObserver.subscribe(this, route);
  }

  @override
  void dispose() {
    routeObserver.unsubscribe(this);
    super.dispose();
  }

  @override
  void didPush() {}

  @override
  void didPushNext() {
    ScaffoldMessenger.of(context).hideCurrentSnackBar();
  }

  @override
  void didPop() {}

  @override
  void didPopNext() {}
}
