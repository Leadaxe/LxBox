/// §083 — immutable снимок match-фильтров одного канала (selector group).
///
/// Pure data: `home_screen` делает capture (поля → snapshot) при уходе с
/// канала и restore (snapshot → поля) при возврате. Хранится в
/// `Map<String /*channel*/, ChannelFilters>` в памяти (per-session, без
/// записи на диск — см. spec §083).
///
/// Содержит **только match-фильтры** (regex/protocol/variants §103/
/// subscription +их §096 invert, ping). Detour tri-state
/// (`_detourEnabled`/`_detourInvert`) и `_showNonMatching` остаются
/// глобальными (про отображение, не про поиск).
class ChannelFilters {
  const ChannelFilters({
    this.regexPattern = '',
    this.regexInvert = false,
    this.protocols = const <String>{},
    this.protocolsInvert = false,
    this.variants = const <String>{},
    this.variantsInvert = false,
    this.subscriptions = const <String>{},
    this.subscriptionsInvert = false,
    this.pingText = '',
    this.pingEnabled = false,
  });

  /// Raw regex pattern (как введён юзером; компиляция — на restore).
  final String regexPattern;

  /// Invert/NOT toggle (§096 — `!`-negate, занявший слот бывшего enable).
  final bool regexInvert;

  /// Выбранные protocol chips. `empty` = no filter.
  final Set<String> protocols;

  /// §096 — invert protocol-фильтра (NOT).
  final bool protocolsInvert;

  /// §103 — выбранные transport/security chips (`tcp`/`xhttp`/`TLS`/`awg2`/…).
  /// `empty` = no filter.
  final Set<String> variants;

  /// §103 — invert variant-фильтра (NOT).
  final bool variantsInvert;

  /// Выбранные subscription chips (id / 'custom'). `empty` = no filter.
  final Set<String> subscriptions;

  /// §096 — invert subscription-фильтра (NOT).
  final bool subscriptionsInvert;

  /// Raw ping value (как введён; parse — на restore).
  final String pingText;

  /// Ping checkbox on/off.
  final bool pingEnabled;

  /// Дефолтный пустой набор — для канала, у которого ещё нет сохранённых
  /// фильтров.
  static const empty = ChannelFilters();

  /// True если все фильтры в дефолте (ничего не настроено). Используется
  /// чтобы не плодить orphan-записи в map за пустые каналы.
  bool get isEmpty =>
      regexPattern.isEmpty &&
      !regexInvert &&
      protocols.isEmpty &&
      !protocolsInvert &&
      variants.isEmpty &&
      !variantsInvert &&
      subscriptions.isEmpty &&
      !subscriptionsInvert &&
      pingText.isEmpty &&
      !pingEnabled;
}
