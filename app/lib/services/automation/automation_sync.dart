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
/// [setReceiver] — inject-точка для тестов (по умолчанию native-вызов).
Future<void> syncAutomationFromStorage({
  Future<void> Function(bool enabled)? setReceiver,
}) async {
  await AutomationEventEmitter.I.reload();
  final receive = await SettingsStorage.getAutomationReceiveEnabled();
  await (setReceiver ?? BoxVpnClient.I.setAutomationEnabled)(receive);
}
