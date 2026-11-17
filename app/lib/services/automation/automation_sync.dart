import 'dart:io' show Platform;

import '../../vpn/box_vpn_client.dart';
import '../settings_storage.dart';
import 'event_emitter.dart';

/// §605 — привести автоматизацию в соответствие с хранилищем: перечитать
/// emit-гейты и выставить receiver'ы (`setComponentEnabledSetting`) по
/// `automation_receive_enabled`.
///
/// Переменная приёма — обычная запись allowlist: восстановление бэкапа и
/// загрузка набора меняют её, минуя тумблер. Без синка набор «выкл» оставлял
/// приём включённым (и наоборот). Зовётся на старте приложения, после загрузки
/// набора и после восстановления бэкапа.
///
/// §721 — тем же проходом в native уходит `appfunctions_enabled` (зеркало
/// `boxvpn_boot` + состояние Android AppFunctions): полный ресинк на старте.
///
/// [setReceiver], [setAppFunctions] — inject-точки для тестов (по умолчанию
/// native-вызовы; AppFunctions — только на Android).
Future<void> syncAutomationFromStorage({
  Future<void> Function(bool enabled)? setReceiver,
  Future<void> Function(bool enabled)? setAppFunctions,
}) async {
  await AutomationEventEmitter.I.reload();
  final receive = await SettingsStorage.getAutomationReceiveEnabled();
  await (setReceiver ?? BoxVpnClient.I.setAutomationEnabled)(receive);
  final appFunctions =
      setAppFunctions ??
      (Platform.isAndroid ? BoxVpnClient.I.setAppFunctionsEnabled : null);
  if (appFunctions != null) {
    await appFunctions(await SettingsStorage.getAppFunctionsEnabled());
  }
}
