import 'package:flutter/material.dart';
import 'package:share_plus/share_plus.dart';

import '../../controllers/subscription_controller.dart';
import '../../services/l10n/l10n.dart';
import '../../services/url_mask.dart';

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
      title: Text(dCtx.l.subShareUrlTitle),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(dCtx.l.subShareMaskedSafe),
          const SizedBox(height: 6),
          SelectableText(masked,
              style: const TextStyle(fontFamily: 'monospace')),
          const SizedBox(height: 16),
          Text(dCtx.l.subShareFullWarning),
        ],
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(dCtx, null),
          child: Text(dCtx.l.commonCancel),
        ),
        TextButton(
          onPressed: () => Navigator.pop(dCtx, 'masked'),
          child: Text(dCtx.l.subShareMasked),
        ),
        FilledButton.tonal(
          onPressed: () => Navigator.pop(dCtx, 'full'),
          child: Text(dCtx.l.subShareFull),
        ),
      ],
    ),
  );
  if (choice == null) return;
  final text = choice == 'full' ? full : masked;
  await Share.share(text, subject: 'LxBox subscription');
}
