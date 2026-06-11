import 'dart:io';

import 'package:device_info_plus/device_info_plus.dart';

import '../../vpn/box_vpn_client.dart';
import '../version_info.dart';

/// User-Agent, отправляемый на каждый HTTP-fetch подписки.
///
/// **Зачем это важно.** Часть subscription-панелей (Remnawave / Marzban-типа)
/// маршрутизирует тело ответа по подстроке в User-Agent: клиента, опознанного
/// как sing-box, кормят base64/URI-списком, который парсер v2 умеет ингестить;
/// неопознанному клиенту панель может отдать полный sing-box JSON-конфиг
/// (`{dns,route,inbounds,outbounds,...}`) или generic-заглушку — такой формат
/// парсер не переваривает, и добавление подписки падает.
///
/// Эмпирически (боевая панель `sub.vern13.ru`): UA с голым `singbox` (без
/// дефиса) → JSON-объект; UA с `sing-box` (с дефисом) или `LxBox` → base64.
///
/// Поэтому UA обязан держать инварианты — зеркалят десктоп `LxBox-desktop`
/// (singbox-launcher `core/config/configtypes`, коммит 18aaafd):
///   1. бренд-токен начинается с `LxBox-android/` — продуктовая марка,
///      суффикс `-android` отличает от десктопной сборки;
///   2. присутствует токен `sing-box/<core>` — по нему панели опознают
///      настоящий sing-box-клиент;
///   3. НЕТ голой подстроки `singbox` (без дефиса) — именно она триггерит
///      неправильную маршрутизацию (см. regression-тест в
///      `test/subscription/user_agent_test.dart`).
///
/// Формат (зеркалит десктоп `LxBox-desktop/<ver> (sing-box/<core>; <os> <arch>)`):
///
/// ```
/// LxBox-android/<appVersion> (sing-box/<coreVersion>; android <sdk> <abi>)
/// ```
///
/// например `LxBox-android/2.0.4 (sing-box/1.13.13-lx.6; android 34 arm64-v8a)`.

const _kProductToken = 'LxBox-android';

/// Чистая функция-конструктор UA. Подставляет значения и гарантирует все три
/// инварианта независимо от мусора на входе. Вынесена отдельно ради
/// regression-теста и переиспользования резолвером ниже.
String buildSubscriptionUserAgent({
  required String appVersion,
  required String coreVersion,
  String platform = 'android',
}) {
  final ver = _sanitizeToken(appVersion, fallback: 'unknown');
  final core = _sanitizeToken(coreVersion, fallback: 'unknown');
  final plat = platform.trim().isEmpty ? 'android' : platform.trim();
  return '$_kProductToken/$ver (sing-box/$core; $plat)';
}

/// Срезает ведущий `v` (`libbox.version` = `v1.13.13-lx.6`) и символы, которые
/// сломали бы структуру UA-комментария (скобки / точка-с-запятой / пробелы).
/// На пустом результате — [fallback], чтобы инварианты держались даже на
/// недоступных runtime-источниках.
String _sanitizeToken(String raw, {required String fallback}) {
  var s = raw.trim();
  if (s.startsWith('v')) s = s.substring(1);
  s = s.replaceAll(RegExp(r'[()\s;]+'), '');
  return s.isEmpty ? fallback : s;
}

String? _cachedUa;

/// Резолвит UA из runtime-источников: версия приложения — [VersionInfo],
/// версия ядра — `Libbox.version()` через [BoxVpnClient], SDK/ABI —
/// `device_info_plus`. Тяжёлые вызовы кешируются: версия/ядро/устройство в
/// рамках процесса не меняются.
///
/// Если ядро ещё не подняло method-channel (core == '', ранний старт или
/// тестовое окружение), результат **не** кешируется — следующий fetch получит
/// настоящую core-версию. Все источники best-effort: их недоступность даёт
/// `unknown`-токены, но инварианты UA сохраняются.
Future<String> resolveSubscriptionUserAgent() async {
  final cached = _cachedUa;
  if (cached != null) return cached;

  final appVersion = VersionInfo.I.version;

  var core = '';
  try {
    core = await BoxVpnClient().getCoreVersion();
  } catch (_) {
    // method-channel недоступен (ранний старт / тесты) — fallback в билдере.
  }

  final platform = await _platformToken();

  final ua = buildSubscriptionUserAgent(
    appVersion: appVersion,
    coreVersion: core,
    platform: platform,
  );

  if (core.trim().isNotEmpty) _cachedUa = ua; // не кешируем degraded core
  return ua;
}

/// `android <sdk> <abi>` (например `android 34 arm64-v8a`). На не-Android или
/// при недоступном `device_info` — просто `android`.
Future<String> _platformToken() async {
  if (!Platform.isAndroid) return 'android';
  try {
    final a = await DeviceInfoPlugin().androidInfo;
    final abi = a.supportedAbis.isNotEmpty ? a.supportedAbis.first : '';
    return [
      'android',
      if (a.version.sdkInt > 0) '${a.version.sdkInt}',
      if (abi.isNotEmpty) abi,
    ].join(' ');
  } catch (_) {
    return 'android';
  }
}
