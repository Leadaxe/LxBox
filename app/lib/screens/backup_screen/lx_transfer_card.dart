import 'package:flutter/material.dart';

import '../../services/l10n/locale_controller.dart';

/// §103 фаза 4 — карточка переноса настроек между телефоном и десктопным
/// лаунчером (LX Backup).
///
/// Отдельно от обычного бэкапа намеренно: тот делает полный снимок ДЛЯ ЭТОЙ ЖЕ
/// установки (включая настройки приложения и отладку), а этот переносит общую
/// часть на другое приложение. Сложить их в одну карточку значило бы предложить
/// пользователю выбор, смысла которого он не видит.
class LxTransferCard extends StatelessWidget {
  const LxTransferCard({
    super.key,
    required this.busy,
    required this.onExport,
    required this.onImport,
  });

  final bool busy;
  final VoidCallback onExport;
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
                const Icon(Icons.swap_horiz),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    getLocalText.s("Transfer to desktop"),
                    style: theme.textTheme.titleMedium,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 4),
            Text(
              getLocalText.s(
                "Move subscriptions, servers, rules and settings between this app "
                "and the desktop launcher. Anything the other side has no place "
                "for travels along untouched and comes back intact.",
              ),
              style: theme.textTheme.bodySmall,
            ),
            const SizedBox(height: 12),
            Wrap(
              alignment: WrapAlignment.end,
              spacing: 8,
              runSpacing: 8,
              children: [
                OutlinedButton.icon(
                  onPressed: busy ? null : onImport,
                  icon: const Icon(Icons.folder_open),
                  label: Text(getLocalText.s("Import")),
                ),
                FilledButton.icon(
                  onPressed: busy ? null : onExport,
                  icon: const Icon(Icons.ios_share),
                  label: Text(getLocalText.s("Export")),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}
