/// Immutable view-model для одной node row на главной (или другом screen'е
/// который захочет переиспользовать `NodeRow`).
///
/// Все derived values для рендера — вычисляются в caller'е
/// (`home/widgets/node_list.dart` itemBuilder: ping из `state.lastDelay`,
/// urltest из `state.urltestNowOf` (CommandClient, §122), proto из
/// `state.configModel.protocolOf`, matches из `NodeFilter.passes`) и пакуются
/// сюда. `NodeRow` widget — pure render от этой модели, не делает state lookup
/// внутри.
///
/// Spec: docs/spec/tasks/068-node-view-item-extract.md
class NodeViewItem {
  const NodeViewItem({
    required this.tag,
    required this.active,
    required this.highlighted,
    required this.delay,
    this.delayIsForeign = false,
    required this.pingBusy,
    required this.tunnelUp,
    required this.busy,
    required this.urltestNow,
    required this.hasDetour,
    required this.protocolLabel,
    this.outboundType,
    this.isChannelAuto = false,
    this.autoGroupLabel,
    this.matches = true,
    this.isSickRoot = false,
  });

  /// Tag ноды или group selector (например `vpn-1`, `✨auto`).
  final String tag;

  /// `tag == state.activeInGroup` — выделение selected outbound в группе.
  final bool active;

  /// `tag == state.highlightedNode` — UI highlight (selection without switch).
  final bool highlighted;

  /// Последний ping result в ms. `null` если untested. Negative — ERR.
  final int? delay;

  /// §325 — [delay] измерен в ДРУГОМ канале (в текущем ноду ещё не пинговали).
  /// Замеры ведутся по каналам, потому что ping-URL и таймаут резолвятся
  /// per-group (§040); показываем чужое число как ориентир, но помечаем — оно
  /// получено другим тестом. `NodeRow` рисует такой бейдж приглушённо со
  /// значком `~`.
  final bool delayIsForeign;

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

  /// §322 — `tag` — auto-двойник КАНАЛА (`vpn-N-auto`), а не узел автовыбора
  /// подписки/папки. Ядру оба — `urltest`, различает только тег (его генерит
  /// билдер канала). Двойнику положены подмена имени на «✨ Auto» и пин в
  /// верхнюю секцию; группе §322 — своё имя и обычное место в списке.
  final bool isChannelAuto;

  /// §322 — метка узла автовыбора: `🎯 [3]` / `🔀 [15/7]`. Рисуется в
  /// подзаголовке ПЕРЕД «→ выбранный», вместо протокола: своего протокола у
  /// группы нет. `null` — обычный узел (показывает [protocolLabel]).
  final String? autoGroupLabel;

  /// Compact protocol label (например `'VLESS + TLS'`, `'Hy2 + TLS'`, `'WG'`).
  /// Показывается справа от имени ноды серым. `null` → не показываем.
  final String? protocolLabel;

  /// §125 — outbound-type из сохранённого конфига (`ParsedConfig[tag].type`):
  /// `direct` / `urltest` → служебная нода (подменяется label «Direct»/«Auto»
  /// + иконкой). `null` или иной тип → обычная прокси-нода (показываем tag).
  final String? outboundType;

  /// §048 — результат фильтра: `false` → render с opacity 0.4 (non-matching
  /// под фильтром, юзер видит весь pool но понимает что подходит).
  /// Default `true` — caller'ы без §048 filter поведения получают normal
  /// rendering без изменений.
  final bool matches;

  /// §355 — нода мертва И от неё зависят другие (DNS-серверы/ноды через
  /// detour/каналы): ⚠-метка у имени, тап по ней открывает sheet со списком
  /// пострадавших (caller передаёт onSickTap). Просто мёртвая нода без
  /// зависимых метку не получает — фильтр от шума.
  final bool isSickRoot;
}
