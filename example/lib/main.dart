import 'package:flutter/material.dart';

import 'autoplay.dart';
import 'scenarios/auth_screen.dart';
import 'scenarios/cancellation_screen.dart';
import 'scenarios/challenge_screen.dart';
import 'scenarios/circuit_breaker_screen.dart';
import 'scenarios/fallback_screen.dart';
import 'scenarios/hedging_screen.dart';
import 'scenarios/overrides_screen.dart';
import 'scenarios/overview_screen.dart';
import 'scenarios/rate_limiter_screen.dart';
import 'scenarios/retry_screen.dart';
import 'scenarios/timeout_screen.dart';

void main() => runApp(const DioResilienceDemoApp());

/// Showcases every dio_resilience 0.3.0 strategy against a scriptable fake
/// backend, offline and deterministic. See example/README.md.
class DioResilienceDemoApp extends StatefulWidget {
  const DioResilienceDemoApp({super.key});

  @override
  State<DioResilienceDemoApp> createState() => _DioResilienceDemoAppState();
}

class _DioResilienceDemoAppState extends State<DioResilienceDemoApp> {
  final _navigatorKey = GlobalKey<NavigatorState>();

  @override
  void initState() {
    super.initState();
    if (kDemoAutoplay) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        AutoplayRunner(_navigatorKey).run();
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      navigatorKey: _navigatorKey,
      debugShowCheckedModeBanner: false,
      title: 'dio_resilience demo',
      theme: ThemeData(
        useMaterial3: true,
        colorScheme: ColorScheme.fromSeed(seedColor: Colors.indigo),
      ),
      darkTheme: ThemeData(
        useMaterial3: true,
        colorScheme: ColorScheme.fromSeed(
          seedColor: Colors.indigo,
          brightness: Brightness.dark,
        ),
      ),
      themeMode: ThemeMode.system,
      home: const OverviewScreen(),
      routes: {
        '/retry': (_) => const RetryScreen(),
        '/auth': (_) => const AuthScreen(),
        '/timeout': (_) => const TimeoutScreen(),
        '/circuit': (_) => const CircuitBreakerScreen(),
        '/rate-limit': (_) => const RateLimiterScreen(),
        '/hedging': (_) => const HedgingScreen(),
        '/challenge': (_) => const ChallengeScreen(),
        '/fallback': (_) => const FallbackScreen(),
        '/overrides': (_) => const OverridesScreen(),
        '/cancellation': (_) => const CancellationScreen(),
      },
    );
  }
}
