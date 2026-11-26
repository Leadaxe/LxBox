part of '../cc_channel.dart';

/// §761 — тип внутреннего хопа цепочки (ядро v1.14.4-lx.37-rc.2, SPEC 165
/// форка, `constant.TypeChainHop`). Перезапись цепочки вставляет хопы
/// `<цепочка>#<i>` в общий список исходящих; пользователю они не нужны —
/// UI скрывает их по типу. По тегу не судим: `#` бывает в тегах подписок.
const String kChainHopOutboundType = 'chain-hop';

/// Хоп ли это цепочки — по типу из ядра, без учёта регистра.
bool isChainHopType(String type) =>
    type.toLowerCase() == kChainHopOutboundType;

/// Список узлов без хопов цепочек.
List<CcOutbound> withoutChainHops(List<CcOutbound> list) =>
    list.any((o) => isChainHopType(o.type))
        ? [for (final o in list) if (!isChainHopType(o.type)) o]
        : list;

/// Группы без хопов: снимаются и члены-хопы, и сами хопы, если ядро
/// отдаст их группой.
List<CcGroup> groupsWithoutChainHops(List<CcGroup> groups) => [
      for (final g in groups)
        if (!isChainHopType(g.type))
          g.items.any((o) => isChainHopType(o.type))
              ? CcGroup(
                  tag: g.tag,
                  type: g.type,
                  selectable: g.selectable,
                  selected: g.selected,
                  isExpand: g.isExpand,
                  items: withoutChainHops(g.items),
                )
              : g,
    ];

/// Теги хопов из снимка узлов — для соединений, у которых тегов типа нет.
Set<String> chainHopTagsOf(List<CcOutbound> list) => {
      for (final o in list)
        if (isChainHopType(o.type)) o.tag,
    };

/// Сырая запись соединения без тегов хопов в `chains` / `detours`.
Map<String, dynamic> connectionMapWithoutChainHops(
    Map<String, dynamic> m, Set<String> hopTags) {
  if (hopTags.isEmpty) return m;
  List<dynamic>? strip(Object? v) => v is List
      ? [for (final t in v) if (!hopTags.contains('$t')) t]
      : null;
  final chains = strip(m['chains']);
  final detours = strip(m['detours']);
  if (chains == null && detours == null) return m;
  return {
    ...m,
    'chains': ?chains,
    'detours': ?detours,
  };
}
