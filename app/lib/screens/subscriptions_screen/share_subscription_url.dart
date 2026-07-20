import 'package:flutter/material.dart';
import 'package:share_plus/share_plus.dart';

import '../../controllers/subscription_controller.dart';
import '../../services/url_mask.dart';
import '../../services/l10n/locale_controller.dart';

/// Share URL подписки (night T6-2). По умолчанию предлагаем masked
/// вариант (`scheme://host/***`) — безопасно расшарить в чат / саппорт.
/// Full URL с токеном — отдельная кнопка с предупреждением.
/// Поведение 1:1 с прежним `_shareSubscriptionUrl`.
Future<void> shareSubscriptionUrl(
    BuildContext context, SubscriptionEntry entry) async {
  final full = entry.url;
  if (full.isEmpty) return;
  final masked = maskSubscriptionUrl(full);
  final choice = await showDialog<String>(
    context: context,
    builder: (dCtx) => AlertDialog(
      title: Text(getLocalText.s("Share subscription URL")),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(getLocalText.s("Masked URL is safe to share — it has no token:")),
          const SizedBox(height: 6),
          SelectableText(masked,
              style: const TextStyle(fontFamily: 'monospace')),
          const SizedBox(height: 16),
          Text(getLocalText.s("Full URL contains your provider token — share only with people who have access to your subscription.")),
        ],
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(dCtx, null),
          child: Text(getLocalText.s("Cancel")),
        ),
        TextButton(
          onPressed: () => Navigator.pop(dCtx, 'masked'),
          child: Text(getLocalText.s("Share masked")),
        ),
        FilledButton.tonal(
          onPressed: () => Navigator.pop(dCtx, 'full'),
          child: Text(getLocalText.s("Share full")),
        ),
      ],
    ),
  );
  if (choice == null) return;
  final text = choice == 'full' ? full : masked;
  await Share.share(text, subject: 'LxBox subscription');
}
