import 'package:flutter/material.dart';

/// Centered empty-state placeholder text used across the per-app trace
/// sub-views (Live / Domains / IPs / Connections).
class EmptyView extends StatelessWidget {
  const EmptyView({super.key, required this.text});
  final String text;
  @override
  Widget build(BuildContext context) => Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Text(text,
              style: TextStyle(
                  color: Theme.of(context).colorScheme.onSurfaceVariant)),
        ),
      );
}
