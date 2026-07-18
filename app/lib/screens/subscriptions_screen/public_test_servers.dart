import 'dart:async';

import 'package:flutter/material.dart';

import '../../services/community_servers_loader.dart';
import '../../services/url_launcher.dart';
import '../../services/l10n/locale_controller.dart';

/// Загрузка community-манифеста + dialog выбора public test-server list.
/// Поведение 1:1 с прежним `_pickPublicTestServer`: при ошибке/пустом
/// списке — snackbar; при выборе записи — `onSelectSource(list.source)`.
Future<void> pickPublicTestServer(
  BuildContext context, {
  required void Function(String source) onSelectSource,
}) async {
  CommunityManifest manifest;
  try {
    manifest = await CommunityServersLoader.load();
  } catch (_) {
    if (!context.mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(getLocalText.s("Test servers list unavailable"))),
    );
    return;
  }
  if (!context.mounted) return;
  if (manifest.lists.isEmpty) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(getLocalText.s("Test servers list unavailable"))),
    );
    return;
  }

  showDialog<void>(
    context: context,
    builder: (ctx) => AlertDialog(
      title: Text(getLocalText.s("Get Public Test Servers")),
      contentPadding: const EdgeInsets.fromLTRB(16, 16, 16, 0),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (manifest.attribution != null) ...[
            Row(
              children: [
                Icon(
                  Icons.volunteer_activism,
                  size: 18,
                  color: Theme.of(ctx).colorScheme.primary,
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    manifest.attribution!.text,
                    style: const TextStyle(fontSize: 13),
                  ),
                ),
                if (manifest.attribution!.link.isNotEmpty)
                  IconButton(
                    icon: const Icon(Icons.open_in_new, size: 18),
                    tooltip: getLocalText.s("View on GitHub"),
                    padding: EdgeInsets.zero,
                    constraints: const BoxConstraints(),
                    onPressed: () =>
                        unawaited(UrlLauncher.open(manifest.attribution!.link)),
                  ),
              ],
            ),
            const SizedBox(height: 8),
          ],
          ...List.generate(manifest.lists.length, (i) {
            final list = manifest.lists[i];
            return ListTile(
              leading: const Icon(Icons.list_alt),
              title: Text(getLocalText.s("List %d", i + 1)),
              dense: true,
              contentPadding: EdgeInsets.zero,
              onTap: () {
                Navigator.pop(ctx);
                onSelectSource(list.source);
              },
            );
          }),
        ],
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(ctx),
          child: Text(getLocalText.s("Cancel")),
        ),
      ],
    ),
  );
}
