import 'package:flutter/material.dart';

class _ScenarioItem {
  const _ScenarioItem(this.route, this.title, this.subtitle);

  final String route;
  final String title;
  final String subtitle;
}

const _items = [
  _ScenarioItem(
    '/retry',
    'Retry & backoff',
    'Exponential backoff, Retry-After, exhausted retries, POST not retried.',
  ),
  _ScenarioItem(
    '/auth',
    'Auth & token refresh',
    'Single-flight refresh, refresh failure, no-refresh mode, multi-account.',
  ),
  _ScenarioItem(
    '/timeout',
    'Timeout',
    'Total budget deadline and per-attempt caps.',
  ),
  _ScenarioItem(
    '/circuit',
    'Circuit breaker',
    'Closed / open / half-open with a live state indicator.',
  ),
  _ScenarioItem(
    '/rate-limit',
    'Rate limiter',
    'Token bucket vs sliding window, wait vs fail mode.',
  ),
  _ScenarioItem(
    '/hedging',
    'Hedging',
    'Race a slow primary against a hedge branch; the loser is cancelled.',
  ),
  _ScenarioItem(
    '/challenge',
    'Challenge',
    'A mock CAPTCHA the pipeline solves and replays.',
  ),
  _ScenarioItem(
    '/fallback',
    'Fallback',
    'Canned response, alternate endpoint, open circuit.',
  ),
  _ScenarioItem(
    '/overrides',
    'Per-request overrides',
    "Options().noRetry(), .withTimeout(), ResilienceExtras.",
  ),
  _ScenarioItem(
    '/cancellation',
    'Cancellation',
    'Cancel a caller mid-backoff.',
  ),
];

class OverviewScreen extends StatelessWidget {
  const OverviewScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('dio_resilience')),
      body: ListView.separated(
        padding: const EdgeInsets.all(16),
        itemCount: _items.length,
        separatorBuilder: (context, index) => const SizedBox(height: 8),
        itemBuilder: (context, index) {
          final item = _items[index];
          return Card(
            child: ListTile(
              title: Text(item.title),
              subtitle: Text(item.subtitle),
              trailing: const Icon(Icons.chevron_right),
              onTap: () => Navigator.of(context).pushNamed(item.route),
            ),
          );
        },
      ),
    );
  }
}
