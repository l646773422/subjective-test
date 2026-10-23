import 'package:flutter/material.dart';

/// Keep labels in normal layout so Chinese glyphs never straddle a clipped edge.
class LabeledControl extends StatelessWidget {
  final String label;
  final Widget child;
  const LabeledControl({super.key, required this.label, required this.child});
  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    mainAxisSize: MainAxisSize.min,
    children: [
      Text(
        label,
        style: Theme.of(context).textTheme.bodyMedium?.copyWith(height: 1.5),
      ),
      const SizedBox(height: 6),
      child,
    ],
  );
}
