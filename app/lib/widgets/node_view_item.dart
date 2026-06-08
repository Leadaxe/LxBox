/// Immutable view-model для одной node row на главной (или другом screen'е
/// который захочет переиспользовать `NodeRow`).
///
/// Все derived values для рендера — вычисляются в caller'е
/// (`home/widgets/node_list.dart` itemBuilder: ping из `state.lastDelay`,
/// urltest из `ClashApiClient`, proto из `state.configModel.protocolOf`,
/// matches из `NodeFilter.passes`) и пакуются сюда. `NodeRow` widget — pure
/// render от этой модели, не делает state lookup внутри.
///
/// Spec: docs/spec/tasks/068-node-view-item-extract.md
class NodeViewItem {
  const NodeViewItem({
    required this.tag,
    required this.active,
    required this.highlighted,
    required this.delay,
    required this.pingBusy,
    required this.tunnelUp,
    required this.busy,
    required this.urltestNow,
    required this.hasDetour,
    required this.protocolLabel,
    this.matches = true,
  });

  /// Tag ноды или group selector (например `vpn-1`, `✨auto`).
  final String tag;

  /// `tag == state.activeInGroup` — выделение selected outbound в группе.
  final bool active;

  /// `tag == state.highlightedNode` — UI highlight (selection without switch).
  final bool highlighted;

  /// Последний ping result в ms. `null` если untested. Negative — ERR.
  final int? delay;

  /// True если ping in-flight для этой ноды (`state.pingBusy[tag] == '…'`).
  final bool pingBusy;

  /// Tunnel up — определяет enabled state кнопок ping/activate.
  final bool tunnelUp;

  /// Global busy flag (tunnel switching, config rebuild) — disable interactions.
  final bool busy;

  /// Для urltest-group selectors — текущий выбранный member tag (показывается
  /// строкой `→ <tag>` ниже имени группы). `null` если это не group или
  /// urltest не выбрал ничего.
  final String? urltestNow;

  /// True если у ноды есть chained detour outbound. Влияет на context menu
  /// (показываем «Copy detour» / «Copy server + detour»).
  final bool hasDetour;

  /// Compact protocol label (например `'VLESS + TLS'`, `'Hy2 + TLS'`, `'WG'`).
  /// Показывается справа от имени ноды серым. `null` → не показываем.
  final String? protocolLabel;

  /// §048 — результат фильтра: `false` → render с opacity 0.4 (non-matching
  /// под фильтром, юзер видит весь pool но понимает что подходит).
  /// Default `true` — caller'ы без §048 filter поведения получают normal
  /// rendering без изменений.
  final bool matches;
}
