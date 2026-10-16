import 'package:flutter/material.dart';

import '../../services/l10n/locale_controller.dart';

/// §622 — карточка передачи настроек телефон → TV (фича 031).
///
/// На TV — приём (первой карточкой экрана), на телефоне с камерой — отправка
/// тех категорий, что отмечены в карточке Export. Где что показывать, решает
/// `transferEntriesFor`.
class DeviceTransferCard extends StatelessWidget {
  const DeviceTransferCard.receive({
    super.key,
    required this.busy,
    required VoidCallback onReceive,
  })  : _receive = true,
        onPressed = onReceive;

  const DeviceTransferCard.send({
    super.key,
    required this.busy,
    required VoidCallback onSend,
  })  : _receive = false,
        onPressed = onSend;

  final bool _receive;
  final bool busy;
  final VoidCallback onPressed;

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
                const Icon(Icons.tv),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    _receive
                        ? getLocalText.s("Receive from phone")
                        : getLocalText.s("Send to TV"),
                    style: theme.textTheme.titleMedium,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 4),
            Text(
              _receive
                  ? getLocalText.s(
                      "Show a code on this TV and scan it with LxBox on your "
                      "phone. The phone sends its settings over the local "
                      "network; you confirm them here before they apply.")
                  : getLocalText.s(
                      "Scan the code shown by LxBox on your TV to send the "
                      "categories selected under Export over the local "
                      "network. Both devices must be on the same network."),
              style: theme.textTheme.bodySmall,
            ),
            const SizedBox(height: 12),
            Align(
              alignment: Alignment.centerRight,
              child: FilledButton.icon(
                onPressed: busy ? null : onPressed,
                icon: Icon(_receive ? Icons.qr_code_2 : Icons.qr_code_scanner),
                label: Text(_receive
                    ? getLocalText.s("Show code")
                    : getLocalText.s("Scan code")),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
