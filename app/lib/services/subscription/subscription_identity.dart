import 'dart:math';

import 'package:device_info_plus/device_info_plus.dart';

import '../settings_storage.dart';

/// §118 — глобальная идентичность HTTP-фетча подписок: кастомный User-Agent +
/// HWID (Remnawave-стиль). Static-holder, инициализируется в `main()` до
/// `runApp` и обновляется при сохранении в App Settings — чтобы `_fetch`
/// читал значения синхронно (как `resolveSubscriptionUserAgent` читает версию).
///
/// Var'ы хранятся через [SettingsStorage] (generic). НЕ config-significant —
/// влияют только на фетч, не на sing-box-конфиг (не в `_configVarKeys`).
class SubscriptionIdentity {
  SubscriptionIdentity._();

  /// Storage-ключи (generic vars).
  static const varUserAgent = 'subscription_user_agent';
  static const varSendHwid = 'subscription_send_hwid';
  static const varHwid = 'subscription_hwid';
  static const varDeviceOs = 'subscription_device_os';
  static const varVerOs = 'subscription_ver_os';
  static const varDeviceModel = 'subscription_device_model';

  /// Пусто = слать брендированный `LxBox-android/<ver>` ([resolveSubscriptionUserAgent]).
  static String userAgentOverride = '';

  /// Слать ли `x-hwid` + device-meta. OFF по умолчанию (решение №3).
  static bool sendHwid = false;

  /// `x-hwid` — UUIDv4 (решение №2), переписываемый юзером.
  static String hwid = '';

  /// Override'ы device-meta. Пусто → device-дефолт (см. `effective*`).
  /// Все четыре заголовка переписываемы.
  static String deviceOsOverride = '';
  static String verOsOverride = '';
  static String deviceModelOverride = '';

  /// device-дефолты (кэшируются на init, в рантайме не меняются).
  static const deviceOsDefault = 'android';
  static String osVersion = ''; // Build.VERSION.RELEASE
  static String deviceModel = ''; // Build.MODEL

  /// Эффективные значения: override > device-дефолт.
  static String get effectiveDeviceOs =>
      deviceOsOverride.isNotEmpty ? deviceOsOverride : deviceOsDefault;
  static String get effectiveVerOs =>
      verOsOverride.isNotEmpty ? verOsOverride : osVersion;
  static String get effectiveDeviceModel =>
      deviceModelOverride.isNotEmpty ? deviceModelOverride : deviceModel;

  /// Читает var'ы + device-info. Зовётся в `main()` после `VersionInfo`.
  static Future<void> init() async {
    userAgentOverride =
        (await SettingsStorage.getVar(varUserAgent, '')).trim();
    sendHwid = (await SettingsStorage.getVar(varSendHwid, 'false')) == 'true';
    hwid = (await SettingsStorage.getVar(varHwid, '')).trim();
    deviceOsOverride =
        (await SettingsStorage.getVar(varDeviceOs, '')).trim();
    verOsOverride = (await SettingsStorage.getVar(varVerOs, '')).trim();
    deviceModelOverride =
        (await SettingsStorage.getVar(varDeviceModel, '')).trim();
    try {
      final info = await DeviceInfoPlugin().androidInfo;
      osVersion = info.version.release;
      deviceModel = info.model;
    } catch (_) {
      // Не-Android (общая lib) / сбой плагина — device-дефолты пустые,
      // effective* отдадут override либо пусто (заголовок не положится).
    }
  }

  /// Обновляет runtime-значения из App Settings на save (persist делает экран).
  static void apply({
    String? userAgentOverride,
    bool? sendHwid,
    String? hwid,
    String? deviceOsOverride,
    String? verOsOverride,
    String? deviceModelOverride,
  }) {
    if (userAgentOverride != null) {
      SubscriptionIdentity.userAgentOverride = userAgentOverride.trim();
    }
    if (sendHwid != null) SubscriptionIdentity.sendHwid = sendHwid;
    if (hwid != null) SubscriptionIdentity.hwid = hwid.trim();
    if (deviceOsOverride != null) {
      SubscriptionIdentity.deviceOsOverride = deviceOsOverride.trim();
    }
    if (verOsOverride != null) {
      SubscriptionIdentity.verOsOverride = verOsOverride.trim();
    }
    if (deviceModelOverride != null) {
      SubscriptionIdentity.deviceModelOverride = deviceModelOverride.trim();
    }
  }

  /// HWID-заголовки для GET подписки. Пусто, если HWID выключен или не задан.
  /// Каждый meta-заголовок — effective (override > device-дефолт); пустые
  /// не кладём.
  static Map<String, String> fetchHeaders() {
    if (!sendHwid || hwid.isEmpty) return const {};
    return {
      'x-hwid': hwid,
      if (effectiveDeviceOs.isNotEmpty) 'x-device-os': effectiveDeviceOs,
      if (effectiveVerOs.isNotEmpty) 'x-ver-os': effectiveVerOs,
      if (effectiveDeviceModel.isNotEmpty)
        'x-device-model': effectiveDeviceModel,
    };
  }
}

/// §118 — UUIDv4 без внешнего пакета (`uuid` нет в зависимостях). Crypto-rand
/// 16 байт + version/variant биты, формат `8-4-4-4-12`.
String generateUuidV4() {
  final r = Random.secure();
  final bytes = List<int>.generate(16, (_) => r.nextInt(256));
  bytes[6] = (bytes[6] & 0x0f) | 0x40; // version 4
  bytes[8] = (bytes[8] & 0x3f) | 0x80; // variant 10xx
  final hex = [
    for (final b in bytes) b.toRadixString(16).padLeft(2, '0'),
  ].join();
  return '${hex.substring(0, 8)}-${hex.substring(8, 12)}-'
      '${hex.substring(12, 16)}-${hex.substring(16, 20)}-${hex.substring(20)}';
}

/// §119 — пароль для локального mixed-inbound (proxy / vpn_proxy). Crypto-rand
/// 16 байт → 32-hex. Тот же подход, что `clash_secret` (`build_config.dart`).
String generateProxyPassword() {
  final r = Random.secure();
  final bytes = List<int>.generate(16, (_) => r.nextInt(256));
  return bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
}
