/// §694 — выбор типа сети в секции NETWORK редактора правила.
///
/// Сегменты `Any / Wi-Fi / Cellular / Ethernet`; [custom] — значение
/// `network_type`, которое выбор не выражает (`other`, несколько типов из
/// сырого JSON): ни один сегмент не выделен, значение живёт как было.
enum NetworkChoice { any, wifi, cellular, ethernet, custom }

/// Загрузка: `network_type` правила (+ есть ли SSID/BSSID) → сегмент.
/// Пусто при непустом списке SSID — Wi-Fi: SSID и так означает Wi-Fi.
NetworkChoice networkChoiceFor(List<String> types, {required bool hasWifi}) {
  if (types.isEmpty) return hasWifi ? NetworkChoice.wifi : NetworkChoice.any;
  if (types.length != 1) return NetworkChoice.custom;
  return switch (types.first) {
    'wifi' => NetworkChoice.wifi,
    'cellular' => NetworkChoice.cellular,
    'ethernet' => NetworkChoice.ethernet,
    _ => NetworkChoice.custom,
  };
}

/// Сохранение: сегмент → (`network_type`, оставить ли SSID/BSSID).
///
/// [loaded] — `network_type`, с которым правило открылось. Wi-Fi со списком
/// SSID пишет `network_type` как был загружен (пусто или `[wifi]` — байт в
/// байт для старых правил), без списка — `[wifi]`. Any, Cellular и Ethernet
/// SSID снимают: при них список противоречит выбору.
({List<String> types, bool keepWifi}) networkTypesFor(
  NetworkChoice choice, {
  required List<String> loaded,
  required bool hasWifi,
}) =>
    switch (choice) {
      NetworkChoice.any => (types: const <String>[], keepWifi: false),
      NetworkChoice.wifi => (
          types: hasWifi && loaded.isEmpty ? const <String>[] : const ['wifi'],
          keepWifi: true,
        ),
      NetworkChoice.cellular => (types: const ['cellular'], keepWifi: false),
      NetworkChoice.ethernet => (types: const ['ethernet'], keepWifi: false),
      NetworkChoice.custom => (types: List<String>.of(loaded), keepWifi: true),
    };
