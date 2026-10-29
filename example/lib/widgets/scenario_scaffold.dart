import 'package:flutter/material.dart';

import '../core/demo_stats.dart';
import '../core/event_log.dart';
import 'log_panel.dart';
import 'stats_panel.dart';

/// Common page shape for every scenario screen: a plain-language
/// explanation, adjustable knobs, run buttons, the outcome, a stats panel
/// and the event log.
class ScenarioScaffold extends StatelessWidget {
  const ScenarioScaffold({
    super.key,
    required this.title,
    required this.explanation,
    required this.controls,
    required this.actions,
    required this.outcome,
    required this.log,
    required this.stats,
  });

  final String title;
  final String explanation;
  final List<Widget> controls;
  final List<Widget> actions;
  final Widget outcome;
  final EventLog log;
  final DemoStats stats;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: Text(title)),
      body: SafeArea(
        child: ListView(
          padding: const EdgeInsets.all(16),
          children: [
            Text(explanation, style: Theme.of(context).textTheme.bodyMedium),
            const SizedBox(height: 16),
            if (controls.isNotEmpty) ...[
              Card(
                child: Padding(
                  padding: const EdgeInsets.all(12),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: controls,
                  ),
                ),
              ),
              const SizedBox(height: 16),
            ],
            Wrap(spacing: 8, runSpacing: 8, children: actions),
            const SizedBox(height: 16),
            outcome,
            const SizedBox(height: 16),
            StatsPanel(stats: stats),
            const SizedBox(height: 16),
            LogPanel(log: log),
          ],
        ),
      ),
    );
  }
}
