import 'package:flutter/material.dart';

import '../core/event_log.dart';

class LogPanel extends StatelessWidget {
  const LogPanel({super.key, required this.log});

  final EventLog log;

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: log,
      builder: (context, _) {
        return Card(
          child: Padding(
            padding: const EdgeInsets.all(12),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('Event log', style: Theme.of(context).textTheme.titleSmall),
                const SizedBox(height: 8),
                if (log.entries.isEmpty)
                  Text(
                    'No events yet. Press Run.',
                    style: Theme.of(context).textTheme.bodySmall,
                  )
                else
                  ConstrainedBox(
                    constraints: const BoxConstraints(maxHeight: 220),
                    child: ListView.builder(
                      shrinkWrap: true,
                      reverse: true,
                      itemCount: log.entries.length,
                      itemBuilder: (context, i) {
                        final entry = log.entries[log.entries.length - 1 - i];
                        return Padding(
                          padding: const EdgeInsets.symmetric(vertical: 1),
                          child: Text(
                            '${_fmt(entry.time)}  ${entry.text}',
                            style: TextStyle(
                              fontFamily: 'monospace',
                              fontSize: 12,
                              color: _colorFor(context, entry.level),
                            ),
                          ),
                        );
                      },
                    ),
                  ),
              ],
            ),
          ),
        );
      },
    );
  }

  String _fmt(DateTime t) {
    String two(int n) => n.toString().padLeft(2, '0');
    return '${two(t.hour)}:${two(t.minute)}:${two(t.second)}.${two(t.millisecond ~/ 10)}';
  }

  Color _colorFor(BuildContext context, LogLevel level) {
    final scheme = Theme.of(context).colorScheme;
    return switch (level) {
      LogLevel.info => scheme.onSurfaceVariant,
      LogLevel.warn => Colors.orange,
      LogLevel.error => scheme.error,
      LogLevel.success => Colors.green,
    };
  }
}
