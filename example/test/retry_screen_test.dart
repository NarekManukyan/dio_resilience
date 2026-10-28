import 'package:dio_resilience_example/main.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('retry screen: a POST is not retried and surfaces the raw error', (
    tester,
  ) async {
    await tester.pumpWidget(const DioResilienceDemoApp());
    await tester.pumpAndSettle();

    await tester.tap(find.text('Retry & backoff'));
    await tester.pumpAndSettle();

    final runPostButton = find.text('Run: POST (not retried)');
    await tester.scrollUntilVisible(runPostButton, 200);
    await tester.tap(runPostButton);
    await tester.pumpAndSettle();

    final outcomeButton = find.textContaining('DioException');
    await tester.scrollUntilVisible(outcomeButton, 200);
    expect(outcomeButton, findsOneWidget);
  });

  testWidgets('overview screen lists every scenario', (tester) async {
    await tester.pumpWidget(const DioResilienceDemoApp());
    await tester.pumpAndSettle();

    for (final title in [
      'Retry & backoff',
      'Auth & token refresh',
      'Timeout',
      'Circuit breaker',
      'Rate limiter',
      'Hedging',
      'Challenge',
      'Fallback',
      'Per-request overrides',
      'Cancellation',
    ]) {
      final finder = find.text(title);
      await tester.scrollUntilVisible(finder, 200);
      expect(finder, findsOneWidget);
    }
  });
}
