import 'package:flutter/material.dart';

import '../../../services/l10n/locale_controller.dart';
import '../../../widgets/safe_bottom.dart';

/// Onboarding card (night T5-1): вместо голого "No subscriptions yet"
/// показываем карточку с 3-step start — пользователь сразу видит что
/// делать. ListView+AlwaysScrollable чтобы pull-to-refresh (T3-2)
/// продолжал работать на пустом экране.
class SubscriptionsEmptyState extends StatelessWidget {
  const SubscriptionsEmptyState({super.key});

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return ListView(
      physics: const AlwaysScrollableScrollPhysics(),
      padding: const EdgeInsets.all(16).withSafeBottom(context),
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
                    Text(getLocalText.s("Getting started"),
                        style: Theme.of(context).textTheme.titleMedium),
                  ],
                ),
                const SizedBox(height: 14),
                Text(getLocalText.s("1. Get a subscription URL from your VPN provider, or a direct proxy link (vless://, trojan://, vmess://, ss://…).")),
                const SizedBox(height: 8),
                Text(getLocalText.s("2. Paste it into the field above, or tap ⋮ → «Paste from clipboard», «Scan QR code».")),
                const SizedBox(height: 8),
                Text(getLocalText.s("3. Hit «+». L×Box will fetch, parse and configure — and you can connect from the Home tab.")),
              ],
            ),
          ),
        ),
        const SizedBox(height: 12),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 8),
          child: Text(
            getLocalText.s("Tip: pull down to refresh, or tap ⟳ in the top bar after adding."),
            style: TextStyle(fontSize: 12, color: cs.onSurfaceVariant),
            textAlign: TextAlign.center,
          ),
        ),
      ],
    );
  }
}
