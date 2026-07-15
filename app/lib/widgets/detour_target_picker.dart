import 'package:flutter/material.dart';

import '../controllers/subscription_controller.dart';
import '../models/channel.dart';
import '../models/node_spec.dart';
import '../models/server_list.dart';
import '../services/selector_info.dart';
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

/// §248 — подпись сохранённого detour-значения: тег detour-канала (или его
/// auto-двойника) → `⚙ <label>`; канал не найден → значение как хранится
/// (сырой тег). Интра-приоритет омонимов (bare-тег члена СВОЕЙ папки
/// побеждает канал-тёзку, зеркало `FolderDetourPlan`) — забота вызывающего:
/// он знает контекст папки, здесь только lookup по каналам.
/// §251 — текущий выбор канала дописывается в скобках (`⚙ <label> (<node>)`),
/// когда известен (туннель up); видно, куда сейчас поедет трафик.
String detourChannelDisplay(String stored, List<Channel> channels) {
  if (stored.isEmpty) return stored;
  for (final c in channels) {
    if (stored == c.tag || stored == c.autoTag) {
      final selected = SelectorInfo.I.selectedOf(stored);
      final pick = (selected != null && selected.isNotEmpty)
          ? ' ($selected)'
          : '';
      return '${c.displayLabel}$pick'; // §274 — ⚙ централизован в displayLabel
    }
  }
  return stored;
}

/// §252 — разворот сохранённого detour-значения в цепочку хопов «как пакет
/// пойдёт», В ПОРЯДКЕ ПАКЕТА: самый глубокий транспорт (вплотную к телефону)
/// первым, прямой detour ноды — последним (§245: detour — входной; сама
/// экспансия идёт «цель → её detour → …», результат разворачивается).
/// Хоп-виды:
///  - интра-член [folder] (bare-тег, приоритет FolderDetourPlan) → дальше по
///    его личному `member.detour` (интра-контекст той же папки);
///  - detour-канал (tag/autoTag) → терминальный хоп `⚙ label (выбор)` —
///    за каналом выбор динамический;
///  - свободная одиночка (display-form) → дальше по её `overrideDetour`.
/// Storage может содержать цикл до сборки (§254 — цикл ловит validateConfig
/// как fatal) — гейт visited + потолок 6 хопов. Превью best-effort: сложные политики
/// (append/replace, register) не разворачиваем — это про ЛИЧНУЮ ось цели.
List<String> detourPathHops(
  String stored, {
  required SubscriptionController controller,
  required List<Channel> channels,
  FolderServers? folder,
}) {
  final hops = <String>[];
  final visited = <String>{};
  var current = stored;
  var folderCtx = folder;
  while (current.isNotEmpty && hops.length < 6 && visited.add(current)) {
    // 1) Интра-член текущей папки: bare-тег побеждает канал-тёзку (§248).
    FolderMember? member;
    if (folderCtx != null) {
      for (final m in folderCtx.members) {
        if (m.node?.tag == current) {
          member = m;
          break;
        }
      }
    }
    if (member != null) {
      hops.add(current);
      current = member.detour; // интра-цепочка продолжается в той же папке
      continue;
    }
    // 2) Detour-канал — терминальный (его выбор показываем в скобках).
    final channelText = detourChannelDisplay(current, channels);
    if (channelText != current) {
      hops.add(channelText);
      break;
    }
    // 3) Свободная одиночка по display-form тегу → её личный detour.
    UserServer? owner;
    for (final e in controller.entries) {
      final l = e.list;
      if (l is! UserServer || !l.enabled) continue;
      for (final n in l.nodes) {
        if (TagResolver.displayTag(l.tagPrefix, n.tag) == current) {
          owner = l;
          break;
        }
      }
      if (owner != null) break;
    }
    hops.add(current);
    if (owner == null) break; // неизвестная цель — дальше не разворачиваем
    current = owner.detourPolicy.overrideDetour;
    folderCtx = null; // внешняя ссылка — интра-контекст исходной папки кончился
  }
  // Экспансия шла «цель → её detour → …» (вглубь); физически пакет идёт
  // из глубины наружу — разворачиваем в порядок пакета.
  return hops.reversed.toList();
}

/// §251 — заголовок канала в секции Channels пикера: `⚙ <label>` + текущий
/// выбор селектора в скобках, когда известен.
String _channelTitle(Channel c) {
  final selected = SelectorInfo.I.selectedOf(c.tag);
  final pick =
      (selected != null && selected.isNotEmpty) ? ' ($selected)' : '';
  return '${c.displayLabel}$pick'; // §274 — ⚙ централизован в displayLabel
}

/// §248 — каналы для секции Channels пикера: enabled && isDetour. Омонимия:
/// канал, чей tag совпадает с bare-тегом распарсенного члена [currentFolder],
/// скрыт — такое значение резолвится в члена (интра побеждает, приоритет
/// bareIndex в FolderDetourPlan), однозначно закодировать выбор канала
/// нельзя. Члены без enabled-фильтра: у выключенного тёзки достаточно
/// включиться, чтобы ссылка молча сменила смысл — коллизию не создаём вовсе.
List<Channel> visibleDetourChannels(
    List<Channel> channels, FolderServers? currentFolder) {
  final memberBareTags = <String>{
    if (currentFolder != null)
      for (final m in currentFolder.members)
        if (m.node != null) m.node!.tag,
  };
  return [
    for (final c in channels)
      if (c.enabled && c.isDetour && !memberBareTags.contains(c.tag)) c,
  ];
}

/// §239 — единый пикер цели detour. Дисциплина владения:
///  - «свободные» одиночные серверы (enabled UserServer) — всегда;
///  - члены [currentFolder] — только если она задана (member/override
///    самой папки); секция сворачиваемая (ExpansionTile);
///  - ЧУЖИЕ папки — никогда (их члены живут под чужой политикой);
///  - §248 — detour-каналы ([channels] с enabled && isDetour) — секцией
///    Channels выше Standalone; вызывающий грузит SettingsStorage.getChannels
///    перед показом.
///
/// [selfBareTag] — исключить сам настраиваемый узел (по голому тегу для
/// членов текущей папки и по display-form для свободных, см. вызовы).
/// [excludeWireguard] — §130: AWG-узел не может detour-ить в wireguard.
/// Каналы под этот гейт НЕ попадают: состав канала не ограничен (§248 Q2),
/// AWG→WG-риск через канал прикрыт advisory-warning'ом билдера.
///
/// Возвращает null при отмене, [DetourTarget.none] при «None».
Future<DetourTarget?> showDetourTargetPicker(
  BuildContext context, {
  required SubscriptionController controller,
  List<Channel> channels = const [],
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

  // §248 — detour-каналы (фильтрация — см. [visibleDetourChannels]).
  final detourChannels = visibleDetourChannels(channels, folder);

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
              // §248 — переключаемые прослойки; секция выше Standalone,
              // пустая (нет подходящих каналов) — не показывается.
              if (detourChannels.isNotEmpty) ...[
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
                  child: Text('Channels',
                      style: theme.textTheme.titleSmall
                          ?.copyWith(color: theme.colorScheme.primary)),
                ),
                for (final c in detourChannels)
                  ListTile(
                    // §251 — текущий выбор канала в скобках (когда туннель up
                    // и группы известны): видно, куда СЕЙЧАС поедет трафик.
                    title: Text(_channelTitle(c),
                        maxLines: 1, overflow: TextOverflow.ellipsis),
                    subtitle: Text(
                      'Switchable detour channel',
                      style: TextStyle(fontSize: 12, color: muted),
                    ),
                    onTap: () => Navigator.pop(
                        ctx,
                        DetourTarget(
                            storeValue: c.tag, display: c.displayLabel)),
                  ),
              ],
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
