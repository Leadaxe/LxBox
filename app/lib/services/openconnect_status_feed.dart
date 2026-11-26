import '../vpn/box_vpn_client.dart';
import '../vpn/cc_channel.dart';

/// Источник данных вкладки Network узла OpenConnect: состояние VPN и статус
/// endpoint'ов openconnect от ядра. Экраны и виджеты не импортируют мост к
/// сервису напрямую (граница `dart-ui-bridge-frozen`), поэтому вкладка
/// берёт всё отсюда.
abstract final class OpenConnectStatusFeed {
  /// Поднят ли туннель сейчас.
  static Future<bool> vpnUp() async =>
      (await BoxVpnClient.I.getVpnStatus()).isUp;

  /// Смены состояния туннеля: `true` — поднят.
  static Stream<bool> get vpnUpChanges =>
      BoxVpnClient.I.onStatusChanged.map((e) => e.status.isUp);

  /// Изменения статуса endpoint'ов (поток шлёт только изменения).
  static Stream<CcOpenConnectSnapshot> get statuses =>
      CcChannel.instance.openConnectStatus;

  /// Текущий снапшот; `null` — ядро не ответило.
  static Future<CcOpenConnectSnapshot?> snapshot() =>
      CcChannel.instance.getOpenConnectStatus();
}
