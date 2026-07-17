import 'package:flutter/material.dart';

import '../../../services/l10n/l10n.dart';

/// Onboarding card (night T5-1): вместо голого "No subscriptions yet"
/// показываем карточку с 3-step start — пользователь сразу видит что
/// делать. ListView+AlwaysScrollable чтобы pull-to-refresh (T3-2)
/// продолжал работать на пустом экране.
class SubscriptionsEmptyState extends StatelessWidget {
  const SubscriptionsEmptyState({
    super.key,
    required this.busy,
    required this.onPickPublicTestServer,
  });

  final bool busy;
  final VoidCallback onPickPublicTestServer;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return ListView(
      physics: const AlwaysScrollableScrollPhysics(),
      padding: const EdgeInsets.all(16),
      children: [
        Card(
          elevation: 0,
          color: cs.surfaceContainerHighest,
          child: Padding(
            padding: const EdgeInsets.all(20),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Icon(Icons.rocket_launch, color: cs.primary),
                    const SizedBox(width: 10),
                    Text(context.l.subEmptyGettingStarted,
                        style: Theme.of(context).textTheme.titleMedium),
                  ],
                ),
                const SizedBox(height: 14),
                Text(context.l.subEmptyStep1),
                const SizedBox(height: 8),
                Text(context.l.subEmptyStep2),
                const SizedBox(height: 8),
                Text(context.l.subEmptyStep3),
                const SizedBox(height: 18),
                Text(
                  context.l.subEmptyNoProvider,
                  style: Theme.of(context).textTheme.titleSmall,
                ),
                const SizedBox(height: 8),
                Text(context.l.subEmptyTryPublic),
                const SizedBox(height: 12),
                FilledButton.icon(
                  onPressed: busy
                      ? null
                      : onPickPublicTestServer,
                  icon: const Icon(Icons.flash_on),
                  label: Text(context.l.subGetPublicTestServers),
                ),
              ],
            ),
          ),
        ),
        const SizedBox(height: 12),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 8),
          child: Text(
            context.l.subEmptyTip,
            style: TextStyle(fontSize: 12, color: cs.onSurfaceVariant),
            textAlign: TextAlign.center,
          ),
        ),
      ],
    );
  }
}
