/// Управление поведением VPN-tunnel'а в фоне (когда экран выключен / Doze).
/// Меняется через App Settings → Battery, native sing-box интерпретирует
/// при следующем подключении.
///
/// Wire-protocol с native — string-литералы `never|lazy|always`. Парсинг и
/// сериализация инкапсулированы тут.
enum BackgroundMode {
  /// Туннель **всегда активен** — никаких pause/wake. Default. Максимум
  /// надёжности (соединения не разрываются), минус батарея в ночном простое.
  never,

  /// Pause **при deep Doze** (через ~30 минут полной неактивности экрана).
  /// Экономия батареи в ночном режиме; при первом же касании экрана —
  /// `wake()` мгновенно. Компромисс «батарея/keep-alive».
  lazy,

  /// Pause **сразу при выключении экрана**. Максимальная экономия батареи,
  /// но keep-alive соединения (Telegram MTProto, APNs) могут разрываться.
  /// Полезно если VPN нужен только для ручного browsing'а.
  always;

  /// Wire-protocol с native — string в виде имени enum-варианта.
  /// Симметричен `fromNative`.
  String get wireValue => name;

  /// §293 — валиден ли wire-литерал (для write-путей, которые ДОЛЖНЫ отвергать
  /// мусор, а не молча fallback'иться в `never` как [fromNative]).
  static bool isValid(String raw) =>
      raw == 'never' || raw == 'lazy' || raw == 'always';

  /// Парсинг ответа native. Unknown / null fallback'ится в `never` (default
  /// поведение, безопасно — туннель остаётся активным).
  static BackgroundMode fromNative(String? raw) {
    return switch (raw) {
      'lazy' => lazy,
      'always' => always,
      _ => never,
    };
  }
}
