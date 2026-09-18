/// Фича 478 — плашка «выключено N серверов» и вопрос после предела кругов.
///
/// Тексты согласованы с владельцем 18.09.2026 и меняться не вправе. Словарь:
/// rejected / turned off / disabled / checking, «server», не «node»; слово
/// «scanning» не используется — оно занято сканером WARP-endpoint'ов.
library;

import 'package:flutter/material.dart';

import '../../models/core_reject_verdict.dart';
import '../../services/core_reject/core_reject_guard.dart';
import '../../services/l10n/locale_controller.dart';
import '../../widgets/app_bottom_sheet.dart';
import '../subscription_detail_screen/widgets/node_notifications_view.dart';

/// Имён в тексте плашки — до трёх, остальные уходят в хвост «+%d more».
const _kNamesInBanner = 3;

/// Заголовок плашки: число выключенных — первым словом.
String coreRejectBannerTitle(int n) =>
    getLocalText.plural("%d servers disabled", n);

/// Текст плашки: перечень имён с хвостом.
String coreRejectBannerText(List<DisabledNode> nodes) {
  final names = nodes.take(_kNamesInBanner).map((d) => d.tag).join(', ');
  final rest = nodes.length - _kNamesInBanner;
  final list =
      rest > 0 ? '$names ${getLocalText.plural("+%d more", rest)}' : names;
  return nodes.length == 1
      ? getLocalText.s(
          "The core rejected it, so it was turned off to let the VPN start: %s",
          list)
      : getLocalText.s(
          "The core rejected them, so they were turned off to let the VPN start: %s",
          list);
}

/// Подпись кнопки плашки.
String coreRejectShowLabel() => getLocalText.s("Show");

/// Вопрос после предела кругов. `null` (диалог закрыт мимо кнопок) читается
/// как Stop: VPN не поднимается, и молчание не должно означать согласие на
/// долгую проверку.
Future<CoreRejectPrompt> showCoreRejectPrompt(
    BuildContext context, int limit) async {
  final answer = await showDialog<CoreRejectPrompt>(
    context: context,
    builder: (dCtx) => AlertDialog(
      title: Text(getLocalText
          .plural("%d servers disabled — there may be more", limit)),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(getLocalText.plural(
              "The core has rejected %d servers so far, and each was turned off. Keep checking the rest? On a large subscription this can take a while.",
              limit)),
          const SizedBox(height: 12),
          Text(getLocalText.s(
              "If you stop, the VPN will not start. The servers already turned off will stay off.")),
        ],
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(dCtx).pop(CoreRejectPrompt.stop),
          // Ключ отличается от кнопки VPN «Stop»: у той в русском словаре
          // намеренно оставлено английское слово, а диалогу владелец задал
          // «Остановить». Один ключ — один перевод, поэтому ключи разные.
          child: Text(getLocalText.s("Stop checking")),
        ),
        FilledButton(
          onPressed: () =>
              Navigator.of(dCtx).pop(CoreRejectPrompt.keepChecking),
          child: Text(getLocalText.s("Keep checking")),
        ),
      ],
    ),
  );
  return answer ?? CoreRejectPrompt.stop;
}

/// Кнопка Show: список выключенных этим прогоном, по каждому — шторка
/// Warnings с текстом ядра (§479, существующий рендер уведомлений узла).
Future<void> showCoreRejectList(
  BuildContext context,
  List<DisabledNode> nodes,
) =>
    showAppBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (sheetCtx) => SafeArea(
        child: ListView(
          shrinkWrap: true,
          padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
          children: [
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 12),
              child: Text(
                coreRejectBannerTitle(nodes.length),
                style: Theme.of(sheetCtx).textTheme.titleMedium,
              ),
            ),
            for (final d in nodes)
              ListTile(
                contentPadding: EdgeInsets.zero,
                title: Text(d.tag),
                subtitle: Text(d.reason,
                    maxLines: 3, overflow: TextOverflow.ellipsis),
                trailing: const Icon(Icons.chevron_right),
                onTap: () => showCoreRejectNodeWarnings(sheetCtx, d),
              ),
          ],
        ),
      ),
    );

/// Шторка Warnings одного узла: рендер — существующий [NodeNotificationsView],
/// новых экранов фича не заводит.
Future<void> showCoreRejectNodeWarnings(
  BuildContext context,
  DisabledNode node,
) =>
    showAppBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (sheetCtx) => SafeArea(
        child: SingleChildScrollView(
          padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 12),
                child: Text(node.tag,
                    style: Theme.of(sheetCtx).textTheme.titleMedium),
              ),
              NodeNotificationsView(
                  [coreRejectedWarningOf(node.reason)]),
            ],
          ),
        ),
      ),
    );
