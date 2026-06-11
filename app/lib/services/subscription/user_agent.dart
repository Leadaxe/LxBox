import 'dart:io';

import 'package:device_info_plus/device_info_plus.dart';

import '../version_info.dart';

/// User-Agent, отправляемый на каждый HTTP-fetch подписки.
///
/// **Зачем это важно.** Часть subscription-панелей (Remnawave / Marzban-типа)
/// маршрутизирует тело ответа по подстроке в User-Agent: клиента, опознанного
/// как наш лаунчер, кормят base64/URI-списком, который парсер v2 умеет
/// ингестить; неопознанному клиенту панель может отдать полный sing-box
/// JSON-конфиг (`{dns,route,inbounds,outbounds,...}`) или generic-заглушку —
/// такой формат парсер не переваривает, и добавление подписки падает.
///
/// Эмпирически (боевая панель `sub.vern13.ru`): UA с голым `singbox` (без
/// дефиса) → JSON-объект; UA с подстрокой `LxBox` → base64 URI-list. Поэтому
/// бренд-токен `LxBox-android` сам по себе достаточен для распознавания —
/// токен `sing-box` сознательно НЕ включаем (см. таск 114).
///
/// Инварианты:
///   1. бренд-токен начинается с `LxBox-android/` — по нему панель опознаёт
///      клиента и отдаёт base64/URI-list; суффикс `-android` отличает от
///      десктопной сборки `LxBox-desktop`;
///   2. голой подстроки `singbox` (без дефиса) нет нигде — именно она триггерит
///      неправильную маршрутизацию (см. regression-тест в
///      `test/subscription/user_agent_test.dart`).
///
/// Формат:
///
/// ```
/// LxBox-android/<appVersion> (android <sdk> <abi>)
/// ```
///
/// например `LxBox-android/2.0.4 (android 34 arm64-v8a)`.

const _kProductToken = 'LxBox-android';

/// Чистая функция-конструктор UA. Подставляет значения и гарантирует
/// инварианты независимо от мусора на входе. Вынесена отдельно ради
/// regression-теста и переиспользования резолвером ниже.
String buildSubscriptionUserAgent({
  required String appVersion,
  String platform = 'android',
}) {
  final ver = _sanitizeToken(appVersion, fallback: 'unknown');
  final plat = platform.trim().isEmpty ? 'android' : platform.trim();
  return '$_kProductToken/$ver ($plat)';
}

/// Срезает ведущий `v` и символы, которые сломали бы структуру UA-комментария
/// (скобки / точка-с-запятой / пробелы). На пустом результате — [fallback],
/// чтобы инварианты держались даже на недоступных runtime-источниках.
String _sanitizeToken(String raw, {required String fallback}) {
  var s = raw.trim();
  if (s.startsWith('v')) s = s.substring(1);
  s = s.replaceAll(RegExp(r'[()\s;]+'), '');
  return s.isEmpty ? fallback : s;
}

String? _cachedUa;

/// Резолвит UA из runtime-источников: версия приложения — [VersionInfo],
/// SDK/ABI — `device_info_plus`. Кешируется: версия/устройство в рамках
/// процесса не меняются. Пока версия не инициализирована
/// (`VersionInfo.init()` ещё не отработал — ранний старт / тесты), результат
/// **не** кешируется. Источники best-effort: их недоступность даёт
/// `unknown`/`android`-токены, но инварианты UA сохраняются.
Future<String> resolveSubscriptionUserAgent() async {
  final cached = _cachedUa;
  if (cached != null) return cached;

  final appVersion = VersionInfo.I.version;
  final platform = await _platformToken();

  final ua = buildSubscriptionUserAgent(
    appVersion: appVersion,
    platform: platform,
  );

  // '0.0.0' — дефолт до VersionInfo.init(); не кешируем degraded версию.
  if (appVersion != '0.0.0') _cachedUa = ua;
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
