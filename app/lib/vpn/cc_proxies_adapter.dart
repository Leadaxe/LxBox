import 'cc_channel.dart';

/// §122 Фаза 1a — мост между libbox `CommandClient` groups-данными
/// (`CcChannel.groups`, `List<CcGroup>`) и Clash-форматом `proxiesJson`,
/// который потребляет весь главный экран (node_list / node_list_presenter /
/// home_controller `reloadProxies`/`applyGroup`).
///
/// **Зачем мост, а не переписывание потребителей.** `state.proxiesJson`
/// (`Map<String,dynamic>` Clash-формата) — фактический источник истины для
/// групп/нод/active-выбора. Все хелперы (`ClashApiClient.selectorGroupTags` /
/// `urltestNow` / `proxyEntry`, `node_list_presenter.isControlTag`) читают
/// именно эту форму. Синтезируя её из `CcGroup`-стрима, мы переключаем источник
/// данных (HTTP Clash API → нативный CommandClient) **не трогая** downstream
/// UI: один файл-адаптер вместо правок в десятке.
///
/// **Форма Clash-`proxiesJson`** (минимум, который реально читается):
/// ```
/// { "proxies": {
///     "<groupTag>": { "type": "Selector"|"URLTest", "now": "<sel>", "all": [...] },
///     "<nodeTag>":  { "type": "<proto>" },
///     ...
/// } }
/// ```
/// `history` НЕ синтезируем — per-node delay в UI берётся из `state.lastDelay`
/// (см. `node_row.dart`), не из `proxiesJson`.
class CcProxiesAdapter {
  const CcProxiesAdapter._();

  /// Собрать Clash-`proxiesJson` из снапшота групп CommandClient'а.
  ///
  /// - Группы → `proxies[group.tag] = {type: <Clash-стиль>, now: selected, all: [item tags]}`.
  ///   Регистр `type` нормализуется к Clash-конвенции (`Selector`/`URLTest`),
  ///   потому что `selectorGroupTags` сверяет `type == 'Selector'` дословно,
  ///   а нативный `OutboundGroup.getType()` отдаёт sing-box-тип (`selector`/
  ///   `urltest`, lowercase). Без нормализации группы не появились бы в
  ///   dropdown'е.
  /// - Узлы внутри групп (`group.items`) → плоские записи
  ///   `proxies[item.tag] = {type: item.type}` (для `isControlTag` / protocol
  ///   detection). Тип узла оставляем как есть (payload-протоколы
  ///   `vless`/`trojan`/… не сверяются на регистр).
  static Map<String, dynamic> fromGroups(List<CcGroup> groups) {
    final proxies = <String, dynamic>{};

    for (final g in groups) {
      proxies[g.tag] = <String, dynamic>{
        'type': _clashGroupType(g.type),
        'now': g.selected,
        'all': g.items.map((e) => e.tag).toList(),
      };
      // Члены группы — плоскими записями. Один узел может входить в несколько
      // групп; перезапись идемпотентна (tag/type стабильны). Группа-член
      // (selector внутри selector'а) перетрётся своей собственной записью на
      // верхнем уровне итерации — порядок не важен, поля совпадают.
      for (final item in g.items) {
        proxies.putIfAbsent(
          item.tag,
          () => <String, dynamic>{'type': item.type},
        );
      }
    }

    return <String, dynamic>{'proxies': proxies};
  }

  /// Нормализация типа группы к Clash-конвенции. `selectorGroupTags` требует
  /// дословное `'Selector'`; `urltestNow` сверяет `toLowerCase().contains('urltest')`
  /// (регистро-устойчив, но нормализуем для единообразия и читаемого JSON-view).
  static String _clashGroupType(String nativeType) {
    final t = nativeType.toLowerCase();
    if (t.contains('urltest')) return 'URLTest';
    if (t.contains('selector')) return 'Selector';
    // Прочие control-типы (direct/block/dns) и неизвестное — как есть.
    return nativeType;
  }
}
