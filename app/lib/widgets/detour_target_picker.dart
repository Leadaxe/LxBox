import 'package:flutter/material.dart';

import '../controllers/subscription_controller.dart';
import '../models/direction.dart';
import '../models/node_link.dart';
import '../models/node_spec.dart';
import '../models/server_list.dart';
import '../services/node_link_address.dart';
import '../services/selector_info.dart';
import '../services/tag_resolver.dart';
import '../services/l10n/locale_controller.dart';
import 'app_bottom_sheet.dart';

/// §239 — выбранная цель detour-пикера.
class DetourTarget {
  const DetourTarget({required this.link, required this.display});

  /// Что сохранять (D-112): свободный сервер и Направление — корневая
  /// `{tag}` (финальный тег сервера, тег Направления); член ТЕКУЩЕЙ папки —
  /// пара `{id папки, сырой тег}` (финальный тег считает сборка, ссылка
  /// переживает смену префикса папки).
  final NodeLink link;

  /// Человекочитаемая подпись (для сообщений/подсветки).
  final String display;

  /// Сентинел «без detour».
  static const none = DetourTarget(link: NodeLink.none, display: '');
}

/// Сабстрока узла в пикере: `TYPE · server:port`; у безадресных (§435 —
/// группа §322, Tailscale) адреса нет — только тип, без `:0`.
String detourNodeSubline(NodeSpec n) {
  final type = n.protocol.toUpperCase();
  return n.isAddressless ? type : '$type · ${n.server}:${n.port}';
}

/// §248 — подпись сохранённого detour-значения: тег detour-Направления (или его
/// auto-двойника) → `⚙ <label>`; Направление не найден → значение как хранится
/// (сырой тег). Интра-приоритет омонимов (bare-тег члена СВОЕЙ папки
/// побеждает Направление-тёзку, зеркало `FolderDetourPlan`) — забота вызывающего:
/// он знает контекст папки, здесь только lookup по Направлениям.
/// §251 — текущий выбор Направления дописывается в скобках (`⚙ <label> (<node>)`),
/// когда известен (туннель up); видно, куда сейчас поедет трафик.
String detourDirectionDisplay(String stored, List<Direction> directions) {
  if (stored.isEmpty) return stored;
  for (final c in directions) {
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

/// §439 — подпись сохранённой detour-ссылки [link]: корневая — через
/// [detourDirectionDisplay] (Направление → `⚙ <label>`, прочее — тег); член
/// папки [folder] (контекст экрана) — его сырой тег; узел другого контейнера
/// — финальная форма тега по источнику из [controller] (префикс + сырой тег),
/// без контроллера — сырой тег.
String detourLinkDisplay(
  NodeLink link, {
  required List<Direction> directions,
  SubscriptionController? controller,
  FolderServers? folder,
}) {
  if (link.isEmpty) return '';
  if (link.isRoot) return detourDirectionDisplay(link.tag, directions);
  if (folder != null && folder.id == link.folderId) return link.tag;
  for (final e in controller?.entries ?? const <SubscriptionEntry>[]) {
    if (e.list.id == link.folderId) {
      return containerFinalForm(e.list, link.tag);
    }
  }
  return link.tag;
}

/// §252 — разворот сохранённой detour-ссылки в цепочку хопов «как пакет
/// пойдёт», В ПОРЯДКЕ ПАКЕТА: самый глубокий транспорт (вплотную к телефону)
/// первым, прямой detour ноды — последним (§245: detour — входной; сама
/// экспансия идёт «цель → её detour → …», результат разворачивается).
/// Хоп-виды:
///  - член папки (пара, D-112) → дальше по его личному `member.detour` в
///    контексте его папки;
///  - detour-Направление (tag/autoTag) → терминальный хоп `⚙ label (выбор)` —
///    за Направлением выбор динамический;
///  - свободная одиночка (корневая ссылка финальным тегом) → дальше по её
///    `overrideDetour`;
///  - узел подписки и неизвестная цель — терминальный хоп.
/// Storage может содержать цикл до сборки (сборка роняет его участников) —
/// гейт visited + потолок 6 хопов. Превью best-effort: сложные политики
/// (append/replace, register) не разворачиваем — это про ЛИЧНУЮ ось цели.
List<String> detourPathHops(
  NodeLink stored, {
  required SubscriptionController controller,
  required List<Direction> directions,
  FolderServers? folder,
}) {
  final hops = <String>[];
  final visited = <NodeLink>{};
  var current = stored;
  var folderCtx = folder;
  while (current.isNotEmpty && hops.length < 6 && visited.add(current)) {
    // 1) Член папки: пара с `id` папки.
    if (!current.isRoot) {
      FolderServers? owner =
          folderCtx != null && folderCtx.id == current.folderId ? folderCtx : null;
      if (owner == null) {
        for (final e in controller.entries) {
          final l = e.list;
          if (l is FolderServers && l.id == current.folderId) {
            owner = l;
            break;
          }
        }
      }
      FolderMember? member;
      if (owner != null) {
        for (var k = 0; k < owner.members.length; k++) {
          if (folderMemberAddress(owner, k) == current) {
            member = owner.members[k];
            break;
          }
        }
      }
      hops.add(detourLinkDisplay(current,
          directions: directions, controller: controller, folder: folder));
      if (member == null) break; // узел подписки / неизвестная цель
      current = member.detour; // цепочка продолжается в папке члена
      folderCtx = owner;
      continue;
    }
    // 2) Detour-Направление — терминальный (его выбор показываем в скобках).
    final directionText = detourDirectionDisplay(current.tag, directions);
    if (directionText != current.tag) {
      hops.add(directionText);
      break;
    }
    // 3) Свободная одиночка по финальному тегу → её личный detour.
    UserServer? owner;
    for (final e in controller.entries) {
      final l = e.list;
      if (l is! UserServer || !l.enabled) continue;
      for (final n in l.nodes) {
        if (TagResolver.displayTag(l.tagPrefix, n.tag) == current.tag) {
          owner = l;
          break;
        }
      }
      if (owner != null) break;
    }
    hops.add(current.tag);
    if (owner == null) break; // неизвестная цель — дальше не разворачиваем
    current = owner.detourPolicy.overrideDetour;
    folderCtx = null;
  }
  // Экспансия шла «цель → её detour → …» (вглубь); физически пакет идёт
  // из глубины наружу — разворачиваем в порядок пакета.
  return hops.reversed.toList();
}

/// §251 — заголовок Направления в секции Directions пикера: `⚙ <label>` + текущий
/// выбор селектора в скобках, когда известен.
String _directionTitle(Direction c) {
  final selected = SelectorInfo.I.selectedOf(c.tag);
  final pick =
      (selected != null && selected.isNotEmpty) ? ' ($selected)' : '';
  return '${c.displayLabel}$pick'; // §274 — ⚙ централизован в displayLabel
}

/// §248 — Направления для секции Directions пикера: enabled && isDetour. Омонимия:
/// Направление, чей tag совпадает с bare-тегом распарсенного члена [currentFolder],
/// скрыт — такое значение резолвится в члена (интра побеждает, приоритет
/// bareIndex в FolderDetourPlan), однозначно закодировать выбор Направления
/// нельзя. Члены без enabled-фильтра: у выключенного тёзки достаточно
/// включиться, чтобы ссылка молча сменила смысл — коллизию не создаём вовсе.
List<Direction> visibleDetourDirections(
    List<Direction> directions, FolderServers? currentFolder) {
  final memberBareTags = <String>{
    if (currentFolder != null)
      for (final m in currentFolder.members)
        if (m.node != null) m.node!.tag,
  };
  return [
    for (final c in directions)
      if (c.enabled && c.isDetour && !memberBareTags.contains(c.tag)) c,
  ];
}

/// §239 — единый пикер цели detour. Дисциплина владения:
///  - «свободные» одиночные серверы (enabled UserServer) — всегда;
///  - члены [currentFolder] — только если она задана (member/override
///    самой папки); секция сворачиваемая (ExpansionTile);
///  - ЧУЖИЕ папки — никогда (их члены живут под чужой политикой);
///  - §248 — detour-Направления ([directions] с enabled && isDetour) — секцией
///    Directions выше Standalone; вызывающий грузит SettingsStorage.getDirections
///    перед показом.
///
/// [selfBareTag] — исключить сам настраиваемый узел (по голому тегу для
/// членов текущей папки и по display-form для свободных, см. вызовы).
///
/// Возвращает null при отмене, [DetourTarget.none] при «None».
Future<DetourTarget?> showDetourTargetPicker(
  BuildContext context, {
  required SubscriptionController controller,
  List<Direction> directions = const [],
  FolderServers? currentFolder,
  String selfBareTag = '',
  String selfDisplayTag = '',
}) {
  // Свободные одиночки (display-form, §080).
  final free = <(String display, NodeSpec node)>[];
  for (final e in controller.entries) {
    final list = e.list;
    if (list is! UserServer) continue;
    if (!list.enabled) continue; // disabled не эмитит outbounds (§080)
    for (final n in list.nodes) {
      if (n.tag.isEmpty) continue;
      // §322 — узел автовыбора целью detour быть не может: цепочка через
      // ротирующийся пул непредсказуема (какой хоп сработает — решает ядро).
      if (n.isGroup) continue;
      final display = TagResolver.displayTag(list.tagPrefix, n.tag);
      if (selfDisplayTag.isNotEmpty && display == selfDisplayTag) continue;
      free.add((display, n));
    }
  }

  // Члены текущей папки (голые теги для показа, адрес-пара для записи;
  // битые и self исключены).
  final members = <(String bare, NodeLink link, NodeSpec node)>[];
  final folder = currentFolder;
  if (folder != null) {
    final raw = containerRawTags(folder);
    for (final m in folder.members) {
      final n = m.node;
      if (n == null || n.tag.isEmpty) continue;
      if (n.isGroup) continue; // §322 — см. выше
      if (selfBareTag.isNotEmpty && n.tag == selfBareTag) continue;
      final rawTag = raw[n];
      if (rawTag == null) continue;
      members.add((n.tag, NodeLink(folderId: folder.id, tag: rawTag), n));
    }
  }

  // §248 — detour-Направления (фильтрация — см. [visibleDetourDirections]).
  final detourDirections = visibleDetourDirections(directions, folder);

  return showAppBottomSheet<DetourTarget>(
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
                child: Text(getLocalText.s("Detour server"),
                    style: theme.textTheme.titleMedium),
              ),
              ListTile(
                leading: const Icon(Icons.block_flipped, size: 20),
                title: Text(getLocalText.s("None (direct)")),
                onTap: () => Navigator.pop(ctx, DetourTarget.none),
              ),
              if (folder != null)
                ExpansionTile(
                  leading: const Icon(Icons.folder_outlined, size: 20),
                  title: Text(getLocalText.s("This folder (%d)", members.length)),
                  subtitle: Text(
                    getLocalText.s("Chains inside the folder get the folder detour appended"),
                    style: TextStyle(fontSize: 12, color: muted),
                  ),
                  children: members.isEmpty
                      ? [
                          Padding(
                            padding: const EdgeInsets.all(12),
                            child: Text(getLocalText.s("No other servers in this folder"),
                                style: TextStyle(color: muted)),
                          ),
                        ]
                      : [
                          for (final (bare, link, n) in members)
                            ListTile(
                              contentPadding:
                                  const EdgeInsets.only(left: 32, right: 16),
                              title: Text(bare,
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis),
                              subtitle: Text(
                                detourNodeSubline(n),
                                style:
                                    TextStyle(fontSize: 12, color: muted),
                              ),
                              onTap: () => Navigator.pop(
                                  ctx,
                                  DetourTarget(link: link, display: bare)),
                            ),
                        ],
                ),
              // §248 — переключаемые прослойки; секция выше Standalone,
              // пустая (нет подходящих Направлений) — не показывается.
              if (detourDirections.isNotEmpty) ...[
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
                  child: Text(getLocalText.s("Directions"),
                      style: theme.textTheme.titleSmall
                          ?.copyWith(color: theme.colorScheme.primary)),
                ),
                for (final c in detourDirections)
                  ListTile(
                    // §251 — текущий выбор Направления в скобках (когда туннель up
                    // и группы известны): видно, куда СЕЙЧАС поедет трафик.
                    title: Text(_directionTitle(c),
                        maxLines: 1, overflow: TextOverflow.ellipsis),
                    subtitle: Text(
                      getLocalText.s("Switchable detour direction"),
                      style: TextStyle(fontSize: 12, color: muted),
                    ),
                    onTap: () => Navigator.pop(
                        ctx,
                        DetourTarget(
                            link: NodeLink(tag: c.tag),
                            display: c.displayLabel)),
                  ),
              ],
              if (free.isNotEmpty) ...[
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
                  child: Text(getLocalText.s("Standalone servers"),
                      style: theme.textTheme.titleSmall
                          ?.copyWith(color: theme.colorScheme.primary)),
                ),
                for (final (display, n) in free)
                  ListTile(
                    title: Text(display,
                        maxLines: 1, overflow: TextOverflow.ellipsis),
                    subtitle: Text(
                      detourNodeSubline(n),
                      style: TextStyle(fontSize: 12, color: muted),
                    ),
                    onTap: () => Navigator.pop(ctx,
                        DetourTarget(
                            link: NodeLink(tag: display), display: display)),
                  ),
              ] else
                Padding(
                  padding: const EdgeInsets.all(16),
                  child: Text(getLocalText.s("No standalone servers available"),
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
