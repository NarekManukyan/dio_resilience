import 'package:flutter/material.dart';

/// An integer slider knob with its current value in the label.
class IntKnob extends StatelessWidget {
  const IntKnob({
    super.key,
    required this.label,
    required this.value,
    required this.min,
    required this.max,
    required this.onChanged,
  });

  final String label;
  final int value;
  final int min;
  final int max;
  final ValueChanged<int> onChanged;

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        Expanded(flex: 3, child: Text('$label: $value')),
        Expanded(
          flex: 4,
          child: Slider(
            value: value.toDouble().clamp(min.toDouble(), max.toDouble()),
            min: min.toDouble(),
            max: max.toDouble(),
            divisions: (max - min).clamp(1, 1000),
            label: '$value',
            onChanged: (v) => onChanged(v.round()),
          ),
        ),
      ],
    );
  }
}

/// A switch knob.
class BoolKnob extends StatelessWidget {
  const BoolKnob({
    super.key,
    required this.label,
    required this.value,
    required this.onChanged,
  });

  final String label;
  final bool value;
  final ValueChanged<bool> onChanged;

  @override
  Widget build(BuildContext context) => SwitchListTile(
        contentPadding: EdgeInsets.zero,
        title: Text(label),
        value: value,
        onChanged: onChanged,
      );
}

/// A dropdown knob for a small set of discrete choices.
class ChoiceKnob<T> extends StatelessWidget {
  const ChoiceKnob({
    super.key,
    required this.label,
    required this.value,
    required this.options,
    required this.onChanged,
    required this.labelOf,
  });

  final String label;
  final T value;
  final List<T> options;
  final ValueChanged<T> onChanged;
  final String Function(T) labelOf;

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        Expanded(child: Text(label)),
        DropdownButton<T>(
          value: value,
          items: [
            for (final option in options)
              DropdownMenuItem(value: option, child: Text(labelOf(option))),
          ],
          onChanged: (v) {
            if (v != null) onChanged(v);
          },
        ),
      ],
    );
  }
}
