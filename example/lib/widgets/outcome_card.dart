import 'package:flutter/material.dart';

import '../core/scenario_runner.dart';

class OutcomeCard extends StatelessWidget {
  const OutcomeCard({super.key, required this.outcome});

  final ScenarioOutcome? outcome;

  @override
  Widget build(BuildContext context) {
    final outcome = this.outcome;
    final scheme = Theme.of(context).colorScheme;
    if (outcome == null) {
      return const Card(
        child: Padding(
          padding: EdgeInsets.all(12),
          child: Text('Press Run to try this scenario.'),
        ),
      );
    }
    final (color, icon, text) = switch (outcome) {
      ScenarioSuccess(:final response) => (
          Colors.green,
          Icons.check_circle,
          'HTTP ${response.statusCode} — ${response.data}',
        ),
      ScenarioFailure(:final error) => (
          scheme.error,
          Icons.error,
          '${error.runtimeType}: $error',
        ),
    };
    return Card(
      color: color.withValues(alpha: 0.08),
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Icon(icon, color: color),
            const SizedBox(width: 8),
            Expanded(child: Text(text)),
          ],
        ),
      ),
    );
  }
}
