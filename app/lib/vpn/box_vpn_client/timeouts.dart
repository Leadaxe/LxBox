part of '../box_vpn_client.dart';

// -----------------------------------------------------------------------------
// Timeout-константы для MethodChannel-вызовов. Подбирались с учётом:
//   - максимально допустимого времени native'а на ответ
//   - critical path'а (init blocking risk → короче)
//   - запаса на медленные devices (Android 8/9 на бюджетных чипах)
//
// Вынесено `part`'ом — та же библиотека, тот же приватный доступ из
// [BoxVpnClient]. Значения timeout'ов идентичны исходнику.
// -----------------------------------------------------------------------------

class _Timeouts {
  const _Timeouts._();

  /// `getVpnStatus` — на init HomeController блокирует UI. Native handler
  /// дёшев (читает поле). 3s — щедро.
  static const status = Duration(seconds: 3);

  /// `startVPN` — libbox.setup + Libbox.newService на старте могут занять
  /// 5-15s на slow devices. 30s — щедрый headroom.
  static const startVpn = Duration(seconds: 30);

  /// `stopVPN` — блокирующий до `setStatus(Stopped)`. Cleanup libbox обычно
  /// 1-3s. 10s — defensive.
  static const stopVpn = Duration(seconds: 10);

  /// Config save/load — file IO, быстро. 5s покрывает worst-case Android
  /// storage latency.
  static const config = Duration(seconds: 5);

  /// `getInstalledApps` — на старых devices список 200+ apps занимает 5-10s.
  /// 15s — headroom.
  static const apps = Duration(seconds: 15);

  /// Per-app fetch (icon/info) — 5s достаточно.
  static const app = Duration(seconds: 5);

  /// Settings methods (battery/notifications/auto-start) — щедрые 3s, обычно
  /// мгновенные.
  static const settings = Duration(seconds: 3);

  /// `requestAddTile` — system dialog может задержать. 10s.
  static const requestTile = Duration(seconds: 10);

  /// `reloadVPN` — sing-box recreates box runtime (~3s) внутри CommandServer.
  /// Запас на slow devices.
  static const reload = Duration(seconds: 10);

  /// `resetNetwork` — лёгкий reset, должен быть мгновенным. Запас.
  static const resetNet = Duration(seconds: 5);

  /// §207 goroutine/heap/block/mutex снимки — мгновенные текстовые pprof-дампы
  /// (без блокирующего ожидания). 5s — щедрый запас на поднятие сервера, GET и
  /// маршалинг дампа через MethodChannel.
  static const goroutineDump = Duration(seconds: 5);

  /// §207 CPU-профиль `?seconds=N` держит соединение N секунд. Dart-таймаут =
  /// `N + cpuHeadroomSeconds` и ОБЯЗАН быть больше native read-timeout
  /// (`N*1000 + 5000` в PProfClient), иначе Dart оборвёт сбор первым → пустой
  /// .pb на длинных профилях. 10s запаса > 5s native → native всегда успевает.
  static const cpuHeadroomSeconds = 10;
}
