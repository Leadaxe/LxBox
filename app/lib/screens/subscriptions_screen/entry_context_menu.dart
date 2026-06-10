import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../controllers/subscription_controller.dart';
import '../../services/subscription/auto_updater.dart';

/// Long-press bottom-sheet для записи подписки/сервера. Поведение 1:1 с
/// прежним `_showContextMenu` — копировать URL, share, update,
/// reset fail-count, delete-with-confirm.
void showEntryContextMenu(
  BuildContext context,
  int index,
  SubscriptionEntry entry, {
  required SubscriptionController subController,
  required AutoUpdater autoUpdater,
  required Future<void> Function(SubscriptionEntry entry) onShareUrl,
}) {
  showModalBottomSheet(
    context: context,
    builder: (ctx) => SafeArea(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          ListTile(
            leading: const Icon(Icons.copy),
            title: const Text('Copy URL'),
            onTap: () {
              final url = entry.url.isNotEmpty
                  ? entry.url
                  : entry.connections.isNotEmpty
                      ? entry.connections.first
                      : '';
              if (url.isNotEmpty) {
                Clipboard.setData(ClipboardData(text: url));
                ScaffoldMessenger.of(context).showSnackBar(
                  const SnackBar(content: Text('URL copied')),
                );
              }
              Navigator.pop(ctx);
            },
          ),
          // Share (night T6-2): for SubscriptionServers с URL даём masked-
          // share по умолчанию. Юзер может включить "Share with token"
          // через confirm-dialog (с предупреждением).
          if (entry.url.isNotEmpty)
            ListTile(
              leading: const Icon(Icons.ios_share),
              title: const Text('Share URL…'),
              onTap: () async {
                Navigator.pop(ctx);
                await onShareUrl(entry);
              },
            ),
          ListTile(
            leading: const Icon(Icons.refresh),
            title: const Text('Update'),
            onTap: () {
              Navigator.pop(ctx);
              unawaited(subController.updateAt(index));
            },
          ),
          // Reset fail-count (night T8-1). Если провайдер вернулся в строй
          // после фриза (5 фейлов подряд → заморожено до app-restart),
          // юзер может руками разморозить без перезапуска.
          if (entry.url.isNotEmpty)
            ListTile(
              leading: const Icon(Icons.restart_alt),
              title: const Text('Reset fail count & retry'),
              onTap: () async {
                Navigator.pop(ctx);
                autoUpdater.resetFailCount(entry.url);
                await subController.updateAt(index);
                if (!context.mounted) return;
                ScaffoldMessenger.of(context).showSnackBar(
                  const SnackBar(content: Text('Fail count reset, retrying…')),
                );
              },
            ),
          ListTile(
            leading: Icon(Icons.delete_outline, color: Theme.of(context).colorScheme.error),
            title: Text('Delete', style: TextStyle(color: Theme.of(context).colorScheme.error)),
            onTap: () async {
              Navigator.pop(ctx);
              final confirmed = await showDialog<bool>(
                context: context,
                builder: (dCtx) => AlertDialog(
                  title: const Text('Delete subscription?'),
                  content: Text('Remove "${entry.displayName}"?'),
                  actions: [
                    TextButton(onPressed: () => Navigator.pop(dCtx, false), child: const Text('Cancel')),
                    TextButton(
                      onPressed: () => Navigator.pop(dCtx, true),
                      style: TextButton.styleFrom(foregroundColor: Theme.of(context).colorScheme.error),
                      child: const Text('Delete'),
                    ),
                  ],
                ),
              );
              if (confirmed == true) {
                await subController.removeAt(index);
                          }
            },
          ),
        ],
      ),
    ),
  );
}
