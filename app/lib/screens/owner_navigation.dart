import 'package:flutter/material.dart';

import '../controllers/home_controller.dart';
import '../controllers/subscription_controller.dart';
import '../models/direction.dart';
import '../models/server_list.dart';
import '../models/source_chain.dart';
import '../services/l10n/locale_controller.dart';
import '../services/runtime_chain.dart';
import '../services/settings_storage.dart';
import 'chain_edit/chain_edit_flow.dart';
import 'folder_detail_screen.dart';
import 'home/source_lookup.dart';
import 'node_settings_screen.dart';
import 'routing_screen.dart';
import 'subscription_detail_screen.dart';

/// §258 — общий переход «config-тег → экран владельца». Вынесен из
/// `home_screen._goToCulpritOwner` (§255) и расширен Направлениями §125:
///   Направление (tag/autoTag)  → Routing, таб Directions, подсветка Направления;
///   папка                → FolderDetailScreen + подсветка члена;
///   подписка             → SubscriptionDetailScreen (Settings-таб);
///   одиночный сервер     → NodeSettingsScreen;
///   цепочка (§558)       → редактор цепочки, после правки — пересборка;
///   не найден            → [onOwnerNotFound] (fallback вызывающего:
///                          detour-cycle sheet — список Servers, View-экран
///                          ноды — SnackBar).
///
/// Направление-ветка идёт ПЕРВОЙ: config-тег, равный тегу Направления, и есть Направление
/// (билдер дедуплицирует коллизии `allocateTag`-суффиксом; tradeoff-патологию
/// «нода с именем vpn-N при выключенном Направлении» см. spec 258).
///
/// [directions] — предзагруженный список (View-экран уже держит его для
/// цепочки); null → грузим из storage. [chains] — так же.
Future<void> openTagOwner(
  BuildContext context,
  String tag, {
  required SubscriptionController subController,
  required HomeController homeController,
  List<Direction>? directions,
  List<SourceChain>? chains,
  required VoidCallback onOwnerNotFound,
}) async {
  final chs = directions ?? await SettingsStorage.getDirections();
  if (!context.mounted) return;

  final direction = directionForTag(tag, chs);
  if (direction != null) {
    await Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => RoutingScreen(
          subController: subController,
          homeController: homeController,
          focusDirectionTag: direction.tag,
        ),
      ),
    );
    return;
  }

  // §558 — цепочка не живёт в `entries` (отдельные записи `kind: chain`),
  // а в конфиге выходит outbound'ом ровно с тегом `SourceChain.tag`.
  final allChains = chains ?? await SettingsStorage.getChains();
  if (!context.mounted) return;
  final chain = allChains.where((c) => c.tag == tag).firstOrNull;
  if (chain != null) {
    await _editChainFromOwnerLink(context, chain,
        subController: subController, homeController: homeController);
    return;
  }

  final owner = ownerOfTag(tag, subController.entries);
  if (owner == null) {
    onOwnerNotFound();
    return;
  }
  final entry = subController.entries[owner.entryIndex];
  final list = entry.list;
  await Navigator.push(
    context,
    MaterialPageRoute(
      builder: (_) {
        if (list is FolderServers) {
          return FolderDetailScreen(
            entry: entry,
            controller: subController,
            focusMemberIndex: owner.memberIndex,
          );
        }
        if (list is UserServer) {
          return NodeSettingsScreen(
            entry: entry,
            index: owner.entryIndex,
            subController: subController,
          );
        }
        return SubscriptionDetailScreen(
          entry: entry,
          controller: subController,
        );
      },
    ),
  );
}

/// §558 — правка цепочки вне Servers: записать, сообщить о снятых позициях,
/// пересобрать конфиг (правка маршрута обязана доехать до сборки).
Future<void> _editChainFromOwnerLink(
  BuildContext context,
  SourceChain chain, {
  required SubscriptionController subController,
  required HomeController homeController,
}) async {
  final outcome = await editChainAndPersist(context, chain,
      subController: subController, homeController: homeController);
  if (outcome == null || !context.mounted) return;
  final messenger = ScaffoldMessenger.of(context);
  if (outcome.positionsRemoved > 0) {
    messenger.showSnackBar(SnackBar(
      content: Text(getLocalText.s(
          '%s chain position(s) removed', '${outcome.positionsRemoved}')),
    ));
  }
  await regenerateSourcesConfig(subController, homeController);
}
