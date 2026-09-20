/// Фича 478 — плашка «выключено N серверов» и вопрос после предела кругов.
///
/// Тексты согласованы с владельцем 18.09.2026 и меняться не вправе. Словарь:
/// rejected / turned off / disabled / checking, «server», не «node»; слово
/// «scanning» не используется — оно занято сканером WARP-endpoint'ов.
library;

import 'package:flutter/material.dart';

import '../../controllers/subscription_controller.dart';
import '../../controllers/subscription_controller/core_reject_ops.dart';
import '../../models/node_spec.dart';
import '../../models/server_list.dart';
import '../../services/core_reject/core_reject_guard.dart';
import '../../services/l10n/locale_controller.dart';
import '../../services/node_hash.dart';
import '../../widgets/app_bottom_sheet.dart';
import '../node_settings_screen.dart';
import '../subscription_detail_screen/node_inspect_screen.dart';

/// Имён в тексте плашки — до трёх, остальные уходят в хвост «+%d more».
const _kNamesInBanner = 3;

/// Заголовок плашки и листа: «1 server disabled» / «%d servers disabled».
String coreRejectBannerTitle(int n) =>
    n == 1
        ? getLocalText.s('1 server disabled')
        : getLocalText.plural('%d servers disabled', n);

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

/// §498/§501/§503 — экран деталей узла на вкладке Diagnostics. Узел ищется по
/// идентичности вердикта в хранилище, не по карте текущей сборки.
Future<void> openCoreRejectNodeDetails(
  BuildContext context, {
  required SubscriptionController subController,
  required DisabledNode disabled,
}) async {
  final target = subController.resolveCoreRejectNavigation(disabled);
  if (target == null) return;

  final entry = subController.entries[target.entryIndex];
  final list = target.list;
  final source = target.source;
  _stampStoredForInspect(list, source);

  await Navigator.of(context).push<void>(
    MaterialPageRoute<void>(
      builder: (_) {
        if (list is FolderServers || list is UserServer) {
          return NodeSettingsScreen(
            entry: entry,
            index: target.entryIndex,
            subController: subController,
            memberIndex: target.memberIndex,
            initialTab: NodeSettingsScreen.diagnosticsTabIndex,
          );
        }
        return NodeInspectScreen(
          node: source,
          tagPrefix: list.tagPrefix,
          initialTab: NodeInspectTab.diagnostics,
        );
      },
    ),
  );
}

/// Секция Notifications во вкладке Diagnostics читает `NodeSpec.warnings`;
/// вердикт страховки живёт в хранилище — дописываем его, как
/// [stampStoredVerdicts] на разборе.
void _stampStoredForInspect(ServerList list, NodeSpec source) {
  switch (list) {
    case SubscriptionServers():
      final id = sourceNodeIdentities(list.nodes)[source];
      if (id == null) return;
      stampNodeWarnings(source, list.nodeWarnings[id] ?? const []);
    case FolderServers():
      for (final m in list.members) {
        if (identical(m.node, source)) {
          stampNodeWarnings(source, m.warnings);
          return;
        }
      }
    case UserServer():
      if (list.nodes.any((n) => identical(n, source))) {
        stampNodeWarnings(source, list.warnings);
      }
  }
}

/// Кнопка Show: список выключенных этим прогоном; тап по строке — детали
/// узла на вкладке Diagnostics (§498/§501). Удалённый узел — строка неактивна.
Future<void> showCoreRejectList(
  BuildContext context,
  List<DisabledNode> nodes, {
  required SubscriptionController subController,
}) =>
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
              Builder(
                builder: (tileCtx) {
                  final canOpen =
                      subController.resolveCoreRejectNavigation(d) != null;
                  return ListTile(
                    contentPadding: EdgeInsets.zero,
                    enabled: canOpen,
                    title: Text(d.tag),
                    subtitle: Text(d.reason,
                        maxLines: 3, overflow: TextOverflow.ellipsis),
                    trailing: canOpen
                        ? Text(
                            '›',
                            style: Theme.of(tileCtx)
                                .textTheme
                                .titleMedium
                                ?.copyWith(
                                  color: Theme.of(tileCtx)
                                      .colorScheme
                                      .onSurfaceVariant,
                                ),
                          )
                        : null,
                    onTap: canOpen
                        ? () async {
                            Navigator.pop(sheetCtx);
                            await openCoreRejectNodeDetails(
                              context,
                              subController: subController,
                              disabled: d,
                            );
                          }
                        : null,
                  );
                },
              ),
          ],
        ),
      ),
    );
