import 'package:flutter/material.dart';

class ImportCard extends StatelessWidget {
  const ImportCard({super.key, required this.busy, required this.onImport});
  final bool busy;
  final VoidCallback onImport;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Card(
      margin: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 16, 16, 16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                const Icon(Icons.download_outlined),
                const SizedBox(width: 8),
                Text('Import', style: theme.textTheme.titleMedium),
              ],
            ),
            const SizedBox(height: 4),
            Text(
              'Restore from a backup JSON file. Preview shown before applying.',
              style: theme.textTheme.bodySmall,
            ),
            const SizedBox(height: 12),
            Align(
              alignment: Alignment.centerRight,
              child: OutlinedButton.icon(
                onPressed: busy ? null : onImport,
                icon: const Icon(Icons.folder_open),
                label: const Text('Pick file...'),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
