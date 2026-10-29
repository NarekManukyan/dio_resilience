import 'package:flutter/material.dart';

import '../core/demo_stats.dart';

class StatsPanel extends StatelessWidget {
  const StatsPanel({super.key, required this.stats});

  final DemoStats stats;

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: stats,
      builder: (context, _) {
        final p50 = stats.p50;
        final p95 = stats.p95;
        return Card(
          child: Padding(
            padding: const EdgeInsets.all(12),
            child: Wrap(
              spacing: 20,
              runSpacing: 10,
              children: [
                _Stat('Logical calls', '${stats.logicalCalls}'),
                _Stat('Wire requests', '${stats.wireRequests}'),
                _Stat('Retries', '${stats.retries}'),
                _Stat('Refreshes', '${stats.refreshes}'),
                _Stat('Fallbacks used', '${stats.fallbacksUsed}'),
                _Stat('p50 latency', p50 == null ? '–' : '${p50.inMilliseconds}ms'),
                _Stat('p95 latency', p95 == null ? '–' : '${p95.inMilliseconds}ms'),
                if (stats.failuresByType.isNotEmpty)
                  _Stat(
                    'Failures',
                    stats.failuresByType.entries
                        .map((e) => '${e.key}×${e.value}')
                        .join(', '),
                  ),
              ],
            ),
          ),
        );
      },
    );
  }
}

class _Stat extends StatelessWidget {
  const _Stat(this.label, this.value);

  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(
          label,
          style: Theme.of(context)
              .textTheme
              .labelSmall
              ?.copyWith(color: Theme.of(context).colorScheme.onSurfaceVariant),
        ),
        Text(value, style: const TextStyle(fontWeight: FontWeight.bold)),
      ],
    );
  }
}
