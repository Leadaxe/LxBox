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

  /// Пусто = слать брендированный `LxBox-android/<ver>` ([resolveSubscriptionUserAgent]).
  static String userAgentOverride = '';

  /// Слать ли `x-hwid` + device-meta. OFF по умолчанию (решение №3).
  static bool sendHwid = false;

  /// Значение `x-hwid` — UUIDv4 (решение №2), переписываемый юзером.
  static String hwid = '';

  /// device-meta (Remnawave: `x-device-os`/`x-ver-os`/`x-device-model`).
  /// Кэшируются на init — в рантайме не меняются.
  static const deviceOs = 'android';
  static String osVersion = '';
  static String deviceModel = '';

  /// Читает var'ы + device-info. Зовётся в `main()` после `VersionInfo`.
  static Future<void> init() async {
    userAgentOverride =
        (await SettingsStorage.getVar(varUserAgent, '')).trim();
    sendHwid = (await SettingsStorage.getVar(varSendHwid, 'false')) == 'true';
    hwid = (await SettingsStorage.getVar(varHwid, '')).trim();
    try {
      final info = await DeviceInfoPlugin().androidInfo;
      osVersion = info.version.release;
      deviceModel = info.model;
    } catch (_) {
      // Не-Android (общая lib) / сбой плагина — meta остаётся пустой,
      // [fetchHeaders] просто не положит эти ключи.
    }
  }

  /// Обновляет runtime-значения из App Settings на save (persist делает экран).
  static void apply({String? userAgentOverride, bool? sendHwid, String? hwid}) {
    if (userAgentOverride != null) {
      SubscriptionIdentity.userAgentOverride = userAgentOverride.trim();
    }
    if (sendHwid != null) SubscriptionIdentity.sendHwid = sendHwid;
    if (hwid != null) SubscriptionIdentity.hwid = hwid.trim();
  }

  /// HWID-заголовки для GET подписки. Пусто, если HWID выключен или не задан.
  static Map<String, String> fetchHeaders() {
    if (!sendHwid || hwid.isEmpty) return const {};
    return {
      'x-hwid': hwid,
      'x-device-os': deviceOs,
      if (osVersion.isNotEmpty) 'x-ver-os': osVersion,
      if (deviceModel.isNotEmpty) 'x-device-model': deviceModel,
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
