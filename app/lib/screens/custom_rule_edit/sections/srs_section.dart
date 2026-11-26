import 'package:flutter/material.dart';

import '../validators.dart' as v;
import '../widgets/section_header.dart';
import '../../../models/custom_rule.dart'
    show kDefaultSrsTtlHours, kSrsTtlChoicesHours;
import '../../../services/l10n/locale_controller.dart';

/// §053 Stage 2 — состояние ☁ кнопки рядом с SRS URL.
/// Public (раньше был private `_SrsDownloadState`).
enum SrsDownloadState { none, loading, cached, error }

/// §053 Stage 2 / §757 — наборы правила: ☁ скачивания (тап → fetch,
/// long-press → menu Refresh / Clear cache), период проверки, «Updated …».
/// Ссылки наборов вписываются в условие Destination (любого под-правила);
/// здесь — все ссылки дерева.
class SrsSection extends StatelessWidget {
  const SrsSection({
    super.key,
    required this.urls,
    required this.state,
    required this.onDownload,
    required this.onShowCloudMenu,
    required this.ttlHours,
    required this.onTtlChanged,
    this.lastUpdatedText,
  });

  /// §757 — все ссылки наборов дерева правила.
  final List<String> urls;
  final SrsDownloadState state;
  final VoidCallback onDownload;

  /// §366 — TTL кэша в часах (значение из [kSrsTtlChoicesHours]).
  final int ttlHours;
  final ValueChanged<int> onTtlChanged;

  /// §366 — «Updated 3d ago» / текст ошибки. Null — файла ещё нет.
  final String? lastUpdatedText;

  /// Long-press на ☁ — показать context menu (Refresh / Clear). Параметр —
  /// глобальная позиция тапа (Offset из onLongPressStart.globalPosition).
  final void Function(Offset globalPos) onShowCloudMenu;

  /// §366 — подпись варианта TTL. Набор вшит ([kSrsTtlChoicesHours]),
  /// поэтому обходимся switch'ем без арифметики над часами.
  String _ttlLabel(int hours) => switch (hours) {
        0 => getLocalText.s("Never"),
        24 => getLocalText.s("Every day"),
        168 => getLocalText.s("Every week"),
        336 => getLocalText.s("Every 2 weeks"),
        720 => getLocalText.s("Every month"),
        4320 => getLocalText.s("Every 6 months"),
        8760 => getLocalText.s("Every year"),
        _ => getLocalText.s("Every %d h", hours),
      };

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    // ## 12 — несколько наборов, по одному URL на строку; ☁ активна, когда
    // валидны все.
    final urlValid = urls.isNotEmpty && urls.every(v.isValidUrl);

    Widget cloud;
    if (state == SrsDownloadState.loading) {
      cloud = const SizedBox(
        width: 48,
        height: 48,
        child: Center(
          child: SizedBox(
            width: 14,
            height: 14,
            child: CircularProgressIndicator(strokeWidth: 1.5),
          ),
        ),
      );
    } else {
      final (IconData icon, Color color) = switch (state) {
        SrsDownloadState.cached =>
          (Icons.cloud_done_outlined, Colors.green),
        SrsDownloadState.error =>
          (Icons.cloud_off_outlined, t.colorScheme.error),
        SrsDownloadState.none || SrsDownloadState.loading => (
            Icons.cloud_download_outlined,
            t.colorScheme.onSurfaceVariant
          ),
      };
      cloud = GestureDetector(
        onTap: urlValid ? onDownload : null,
        onLongPressStart: (d) => onShowCloudMenu(d.globalPosition),
        behavior: HitTestBehavior.opaque,
        child: Container(
          width: 48,
          height: 48,
          alignment: Alignment.center,
          child: Icon(icon, color: color, size: 20),
        ),
      );
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SectionHeader(
          title: getLocalText.s("Rule sets"),
          hint: getLocalText.s(
              "Manual download only. Tap ☁ to fetch the rule-set files."),
        ),
        Row(
          children: [
            Expanded(
              child: Text(
                getLocalText.s("Rule sets in this rule: %d", urls.length),
                style: const TextStyle(fontSize: 13),
              ),
            ),
            cloud,
          ],
        ),
        const SizedBox(height: 4),
        // §366 — как часто перепроверять источник. Проверка идёт при запуске
        // приложения и при подъёме VPN, не по фоновому таймеру.
        Row(
          children: [
            Icon(Icons.update, size: 16, color: t.colorScheme.onSurfaceVariant),
            const SizedBox(width: 8),
            Text(getLocalText.s("Check for updates"),
                style: const TextStyle(fontSize: 13)),
            const SizedBox(width: 12),
            Expanded(
              child: DropdownButton<int>(
                value: kSrsTtlChoicesHours.contains(ttlHours)
                    ? ttlHours
                    // Значение вне вшитого набора (правка бэкапа руками) —
                    // не роняем dropdown, показываем ближайший смысл.
                    : kDefaultSrsTtlHours,
                isExpanded: true,
                isDense: true,
                style: TextStyle(fontSize: 13, color: t.colorScheme.onSurface),
                items: [
                  for (final h in kSrsTtlChoicesHours)
                    DropdownMenuItem(value: h, child: Text(_ttlLabel(h))),
                ],
                onChanged: (v) {
                  if (v != null) onTtlChanged(v);
                },
              ),
            ),
          ],
        ),
        if (lastUpdatedText != null)
          Padding(
            padding: const EdgeInsets.only(top: 2, bottom: 2),
            child: Row(
              children: [
                Expanded(
                  child: Text(
                    lastUpdatedText!,
                    style: TextStyle(
                        fontSize: 11, color: t.colorScheme.onSurfaceVariant),
                  ),
                ),
                // §366 — ручное обновление уже скачанного файла. Качает
                // безусловно: юзер нажал «обновить», совпадение ETag его
                // останавливать не должно.
                TextButton.icon(
                  icon: const Icon(Icons.update, size: 14),
                  label: Text(getLocalText.s("Update now"),
                      style: const TextStyle(fontSize: 12)),
                  onPressed: state == SrsDownloadState.loading
                      ? null
                      : onDownload,
                  style: TextButton.styleFrom(
                    minimumSize: const Size(0, 28),
                    padding: const EdgeInsets.symmetric(horizontal: 8),
                  ),
                ),
              ],
            ),
          ),
      ],
    );
  }
}
