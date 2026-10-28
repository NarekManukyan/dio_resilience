import 'dart:async';

import 'package:flutter/material.dart';

/// Set at build time with `--dart-define=DEMO_AUTOPLAY=true`. When true, the
/// app walks every scenario screen on its own and runs its demo, so a screen
/// recording needs no taps.
const bool kDemoAutoplay = bool.fromEnvironment('DEMO_AUTOPLAY');

/// The screen currently on-screen registers the action autoplay should
/// trigger ("press every Run button for me"); [AutoplayRunner] awaits it
/// after navigating to each route.
abstract final class AutoplayHook {
  static Future<void> Function()? action;
}

/// Walks every scenario route in turn, running its scenario and pausing so a
/// screen recording captures the whole tour unattended.
class AutoplayRunner {
  AutoplayRunner(this.navigatorKey);

  final GlobalKey<NavigatorState> navigatorKey;

  static const _routes = [
    '/retry',
    '/auth',
    '/timeout',
    '/circuit',
    '/rate-limit',
    '/hedging',
    '/challenge',
    '/fallback',
    '/overrides',
    '/cancellation',
  ];

  Future<void> run() async {
    await Future<void>.delayed(const Duration(seconds: 2));
    for (final route in _routes) {
      final nav = navigatorKey.currentState;
      if (nav == null) return;
      AutoplayHook.action = null;
      // pushNamed's future only completes when the route is popped, so it
      // must not be awaited here — awaiting it would block until the `pop()`
      // below, which never runs.
      unawaited(nav.pushNamed(route));
      await Future<void>.delayed(const Duration(milliseconds: 700));
      final action = AutoplayHook.action;
      if (action != null) await action();
      await Future<void>.delayed(const Duration(seconds: 2));
      nav.pop();
      await Future<void>.delayed(const Duration(milliseconds: 400));
    }
  }
}
