/// §083 — immutable снимок match-фильтров одного канала (selector group).
///
/// Pure data: `home_screen` делает capture (поля → snapshot) при уходе с
/// канала и restore (snapshot → поля) при возврате. Хранится в
/// `Map<String /*channel*/, ChannelFilters>` в памяти (per-session, без
/// записи на диск — см. spec §083).
///
/// Содержит **только match-фильтры**. `_showDetourNodes` / `_showNonMatching`
/// остаются глобальными (они про отображение, не про поиск).
class ChannelFilters {
  const ChannelFilters({
    this.regexPattern = '',
    this.regexEnabled = false,
    this.regexInvert = false,
    this.protocols = const <String>{},
    this.subscriptions = const <String>{},
    this.pingText = '',
    this.pingEnabled = false,
  });

  /// Raw regex pattern (как введён юзером; компиляция — на restore).
  final String regexPattern;

  /// Regex checkbox on/off (позволяет выключить не теряя pattern).
  final bool regexEnabled;

  /// Invert/NOT toggle.
  final bool regexInvert;

  /// Выбранные protocol chips. `empty` = no filter.
  final Set<String> protocols;

  /// Выбранные subscription chips (id / 'custom'). `empty` = no filter.
  final Set<String> subscriptions;

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
      !regexEnabled &&
      !regexInvert &&
      protocols.isEmpty &&
      subscriptions.isEmpty &&
      pingText.isEmpty &&
      !pingEnabled;
}
