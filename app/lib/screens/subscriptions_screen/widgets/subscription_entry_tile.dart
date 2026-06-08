import 'package:flutter/material.dart';

import '../../../controllers/subscription_controller.dart';
import 'subscription_entry_subtitle.dart';

/// Одна строка списка подписок/серверов. Поведение 1:1 с прежним
/// inline `ListTile` в `_buildList`.
class SubscriptionEntryTile extends StatelessWidget {
  const SubscriptionEntryTile({
    super.key,
    required this.entry,
    required this.onToggle,
    required this.onLaunchUrl,
    required this.onLongPress,
    required this.onTap,
  });

  final SubscriptionEntry entry;
  final VoidCallback onToggle;
  final void Function(String url) onLaunchUrl;
  final void Function(BuildContext context) onLongPress;
  final void Function(BuildContext context) onTap;

  @override
  Widget build(BuildContext context) {
    final enabled = entry.enabled;
    return ListTile(
      contentPadding: EdgeInsets.zero,
      leading: SizedBox(
        width: 40,
        child: Switch(
          value: enabled,
          onChanged: (_) {
            onToggle();
                    },
        ),
      ),
      title: Row(
        children: [
          Flexible(
            child: Text(
              entry.displayName,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                fontSize: 13,
                fontWeight: FontWeight.w500,
                color: enabled ? null : Theme.of(context).colorScheme.onSurfaceVariant,
              ),
            ),
          ),
          if (entry.supportUrl.isNotEmpty)
            Padding(
              padding: const EdgeInsets.only(left: 4),
              child: GestureDetector(
                onTap: () => onLaunchUrl(entry.supportUrl),
                child: Icon(
                  entry.supportUrl.contains('t.me') ? Icons.telegram : Icons.open_in_new,
                  size: 16,
                  color: entry.supportUrl.contains('t.me')
                      ? const Color(0xFF2AABEE)
                      : Theme.of(context).colorScheme.onSurfaceVariant,
                ),
              ),
            ),
        ],
      ),
      subtitle: buildSubscriptionEntrySubtitle(context, entry),
      trailing: entry.url.isEmpty && entry.connections.isNotEmpty
          ? Icon(Icons.dns, size: 20, color: Theme.of(context).colorScheme.onSurfaceVariant)
          : null,
      onLongPress: () => onLongPress(context),
      onTap: () => onTap(context),
    );
  }
}
