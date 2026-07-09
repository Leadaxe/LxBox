import 'package:flutter/material.dart';

import '../controllers/home_controller.dart';
import '../controllers/subscription_controller.dart';
import '../models/channel.dart';
import '../models/server_list.dart';
import '../services/runtime_chain.dart';
import '../services/settings_storage.dart';
import 'folder_detail_screen.dart';
import 'home/source_lookup.dart';
import 'node_settings_screen.dart';
import 'routing_screen.dart';
import 'subscription_detail_screen.dart';

/// §258 — общий переход «config-тег → экран владельца». Вынесен из
/// `home_screen._goToCulpritOwner` (§255) и расширен каналами §125:
///   канал (tag/autoTag)  → Routing, таб Channels, подсветка канала;
///   папка                → FolderDetailScreen + подсветка члена;
///   подписка             → SubscriptionDetailScreen (Settings-таб);
///   одиночный сервер     → NodeSettingsScreen;
///   не найден            → [onOwnerNotFound] (fallback вызывающего:
///                          detour-cycle sheet — список Servers, View-экран
///                          ноды — SnackBar).
///
/// Канальная ветка идёт ПЕРВОЙ: config-тег, равный тегу канала, и есть канал
/// (билдер дедуплицирует коллизии `allocateTag`-суффиксом; tradeoff-патологию
/// «нода с именем vpn-N при выключенном канале» см. spec 258).
///
/// [channels] — предзагруженный список (View-экран уже держит его для
/// цепочки); null → грузим из storage.
Future<void> openTagOwner(
  BuildContext context,
  String tag, {
  required SubscriptionController subController,
  required HomeController homeController,
  List<Channel>? channels,
  required VoidCallback onOwnerNotFound,
}) async {
  final chs = channels ?? await SettingsStorage.getChannels();
  if (!context.mounted) return;

  final channel = channelForTag(tag, chs);
  if (channel != null) {
    await Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => RoutingScreen(
          subController: subController,
          homeController: homeController,
          focusChannelTag: channel.tag,
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
