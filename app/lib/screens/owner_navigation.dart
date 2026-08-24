import 'package:flutter/material.dart';

import '../controllers/home_controller.dart';
import '../controllers/subscription_controller.dart';
import '../models/direction.dart';
import '../models/server_list.dart';
import '../services/runtime_chain.dart';
import '../services/settings_storage.dart';
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
///   не найден            → [onOwnerNotFound] (fallback вызывающего:
///                          detour-cycle sheet — список Servers, View-экран
///                          ноды — SnackBar).
///
/// Направление-ветка идёт ПЕРВОЙ: config-тег, равный тегу Направления, и есть Направление
/// (билдер дедуплицирует коллизии `allocateTag`-суффиксом; tradeoff-патологию
/// «нода с именем vpn-N при выключенном Направлении» см. spec 258).
///
/// [directions] — предзагруженный список (View-экран уже держит его для
/// цепочки); null → грузим из storage.
Future<void> openTagOwner(
  BuildContext context,
  String tag, {
  required SubscriptionController subController,
  required HomeController homeController,
  List<Direction>? directions,
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
