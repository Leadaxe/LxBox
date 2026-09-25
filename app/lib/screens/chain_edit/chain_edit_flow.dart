import 'dart:async';

import 'package:flutter/material.dart';

import '../../controllers/home_controller.dart';
import '../../controllers/subscription_controller.dart';
import '../../models/source_chain.dart';
import '../../services/builder/node_link_pool.dart';
import '../../services/settings_storage.dart';
import '../chain_edit_screen.dart';

/// Итог правки цепочки, уже записанный в storage.
class ChainEditOutcome {
  const ChainEditOutcome({required this.deleted, this.positionsRemoved = 0});

  final bool deleted;

  /// §393 D2 — сколько позиций этой цепочки снято у остальных при удалении.
  final int positionsRemoved;
}

/// §558 — общий поток «открыть редактор цепочки и записать результат». Им
/// пользуются Servers (`_editChain`) и переход к владельцу тега
/// (`openTagOwner`, View-экран узла, detour-cycle sheet). Экранная часть
/// (SnackBar'ы, перечитать список, пересборка) — у вызывающего.
///
/// null — пользователь ушёл без изменений.
Future<ChainEditOutcome?> editChainAndPersist(
  BuildContext context,
  SourceChain chain, {
  required SubscriptionController subController,
  required HomeController homeController,
}) async {
  final directions = await SettingsStorage.getDirections();
  final chains = await SettingsStorage.getChains();
  if (!context.mounted) return null;
  final lists = [for (final e in subController.entries) e.list];
  final result = await openChainEditor(
    context,
    initial: chain,
    // Последний собранный конфиг — источник ОКОНЧАТЕЛЬНЫХ тегов позиций
    // (префикс подписки приклеен, дубли уникализированы аллокатором).
    config: homeController.state.configModel,
    directions: directions,
    chains: chains,
    // §439 — пул ссылок: финальный тег позиции ↔ ссылка на узел.
    pool: computeNodeLinkPool(lists, directions: directions),
    lists: lists,
  );
  if (result == null) return null;
  if (result.wasDeleted) {
    // §393 D2 — каскад через цепочки-позиции: удаление этой цепочки снимает
    // её ПОЗИЦИЮ у остальных, но их самих не трогает.
    final healed = await SettingsStorage.deleteChain(chain.tag);
    return ChainEditOutcome(deleted: true, positionsRemoved: healed.positions);
  }
  if (result.saved == null) return null;
  await SettingsStorage.updateChain(result.saved!);
  return const ChainEditOutcome(deleted: false);
}

/// §558 — пересобрать конфиг после правки источника и применить на лету.
/// null — конфиг не собран; иначе true, если ушёл in-place reload.
///
/// Директива оператора 24.08 («поменял цепочку — конфиг не перестроился
/// сам»): правка источников при живом туннеле применяется сама через
/// in-place reload (§367-механика, туннель не рвётся), а не баннером
/// «перезапустите VPN». Гейт canReload даёт connected + cooldown 3s —
/// серия быстрых правок не устроит шторм перезагрузок: применится
/// последняя по баннеру, как раньше.
Future<bool?> regenerateSourcesConfig(
  SubscriptionController subController,
  HomeController homeController,
) async {
  final config = await subController.generateConfig();
  if (config == null) return null;
  await homeController.saveParsedConfig(config);
  final applied = homeController.canReload;
  if (applied) unawaited(homeController.reloadVpn());
  return applied;
}
