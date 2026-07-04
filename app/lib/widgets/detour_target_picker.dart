import 'package:flutter/material.dart';

import '../controllers/subscription_controller.dart';
import '../models/node_spec.dart';
import '../models/server_list.dart';
import '../services/tag_resolver.dart';

/// §239 — выбранная цель detour-пикера.
class DetourTarget {
  const DetourTarget({required this.storeValue, required this.display});

  /// Что сохранять: для свободного сервера — display-form тег (§080);
  /// для члена ТЕКУЩЕЙ папки — ГОЛЫЙ тег члена (resolve при сборке,
  /// переживает смену префикса папки).
  final String storeValue;

  /// Человекочитаемая подпись (для сообщений/подсветки).
  final String display;

  /// Сентинел «без detour».
  static const none = DetourTarget(storeValue: '', display: '');
}

/// §239 — единый пикер цели detour. Дисциплина владения:
///  - «свободные» одиночные серверы (enabled UserServer) — всегда;
///  - члены [currentFolder] — только если она задана (member/override
///    самой папки); секция сворачиваемая (ExpansionTile);
///  - ЧУЖИЕ папки — никогда (их члены живут под чужой политикой).
///
/// [selfBareTag] — исключить сам настраиваемый узел (по голому тегу для
/// членов текущей папки и по display-form для свободных, см. вызовы).
/// [excludeWireguard] — §130: AWG-узел не может detour-ить в wireguard.
///
/// Возвращает null при отмене, [DetourTarget.none] при «None».
Future<DetourTarget?> showDetourTargetPicker(
  BuildContext context, {
  required SubscriptionController controller,
  FolderServers? currentFolder,
  String selfBareTag = '',
  String selfDisplayTag = '',
  bool excludeWireguard = false,
}) {
  // Свободные одиночки (display-form, §080).
  final free = <(String display, NodeSpec node)>[];
  for (final e in controller.entries) {
    final list = e.list;
    if (list is! UserServer) continue;
    if (!list.enabled) continue; // disabled не эмитит outbounds (§080)
    for (final n in list.nodes) {
      if (n.tag.isEmpty) continue;
      if (excludeWireguard && n is WireguardSpec) continue;
      final display = TagResolver.displayTag(list.tagPrefix, n.tag);
      if (selfDisplayTag.isNotEmpty && display == selfDisplayTag) continue;
      free.add((display, n));
    }
  }

  // Члены текущей папки (голые теги; битые и self исключены).
  final members = <(String bare, NodeSpec node)>[];
  final folder = currentFolder;
  if (folder != null) {
    for (final m in folder.members) {
      final n = m.node;
      if (n == null || n.tag.isEmpty) continue;
      if (excludeWireguard && n is WireguardSpec) continue;
      if (selfBareTag.isNotEmpty && n.tag == selfBareTag) continue;
      members.add((n.tag, n));
    }
  }

  return showModalBottomSheet<DetourTarget>(
    context: context,
    isScrollControlled: true,
    builder: (ctx) {
      final theme = Theme.of(ctx);
      final muted = theme.colorScheme.onSurfaceVariant;
      return SafeArea(
        child: ConstrainedBox(
          constraints: BoxConstraints(
            maxHeight: MediaQuery.of(ctx).size.height * 0.7,
          ),
          child: ListView(
            shrinkWrap: true,
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
                child: Text('Detour server',
                    style: theme.textTheme.titleMedium),
              ),
              ListTile(
                leading: const Icon(Icons.block_flipped, size: 20),
                title: const Text('None (direct)'),
                onTap: () => Navigator.pop(ctx, DetourTarget.none),
              ),
              if (folder != null)
                ExpansionTile(
                  leading: const Icon(Icons.folder_outlined, size: 20),
                  title: Text('This folder (${members.length})'),
                  subtitle: Text(
                    'Chains inside the folder get the folder detour appended',
                    style: TextStyle(fontSize: 12, color: muted),
                  ),
                  children: members.isEmpty
                      ? [
                          Padding(
                            padding: const EdgeInsets.all(12),
                            child: Text('No other servers in this folder',
                                style: TextStyle(color: muted)),
                          ),
                        ]
                      : [
                          for (final (bare, n) in members)
                            ListTile(
                              contentPadding:
                                  const EdgeInsets.only(left: 32, right: 16),
                              title: Text(bare,
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis),
                              subtitle: Text(
                                '${n.protocol.toUpperCase()} · ${n.server}:${n.port}',
                                style:
                                    TextStyle(fontSize: 12, color: muted),
                              ),
                              onTap: () => Navigator.pop(
                                  ctx,
                                  DetourTarget(
                                      storeValue: bare, display: bare)),
                            ),
                        ],
                ),
              if (free.isNotEmpty) ...[
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
                  child: Text('Standalone servers',
                      style: theme.textTheme.titleSmall
                          ?.copyWith(color: theme.colorScheme.primary)),
                ),
                for (final (display, n) in free)
                  ListTile(
                    title: Text(display,
                        maxLines: 1, overflow: TextOverflow.ellipsis),
                    subtitle: Text(
                      '${n.protocol.toUpperCase()} · ${n.server}:${n.port}',
                      style: TextStyle(fontSize: 12, color: muted),
                    ),
                    onTap: () => Navigator.pop(ctx,
                        DetourTarget(storeValue: display, display: display)),
                  ),
              ] else
                Padding(
                  padding: const EdgeInsets.all(16),
                  child: Text('No standalone servers available',
                      style: TextStyle(color: muted)),
                ),
              const SizedBox(height: 8),
            ],
          ),
        ),
      );
    },
  );
}
