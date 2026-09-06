import 'dart:io' show Platform;

import 'package:flutter/services.dart';

import '../app_log.dart';
import '../platform_channels.dart';
import '../settings_storage.dart';

/// §425 — регион пулов WARP: какая секция `loc.<cc>` asset'а
/// `warp_endpoints.json` накладывается на корень.
///
/// Настройка `warp_region` (App Settings): `auto` — страна определяется сама,
/// `default` — корень без региона, иначе явный код страны. Автоопределение:
/// страна текущей сети (MCC оператора / SIM, нативно) → страна из локали
/// устройства → пусто. Код страны, а не UI-язык: русскоязычный юзер в
/// Израиле сидит не за ТСПУ, и российские SNI ему ни к чему.
class WarpRegion {
  WarpRegion._();

  static const _channel = MethodChannel(PlatformChannels.utils);

  /// Автоопределённая страна (кэш на процесс; `''` — не определилась).
  static String? _detected;

  /// Для тестов / инъекции: подмена нативного детекта.
  static Future<String?> Function()? detectorOverride;

  /// Эффективный код региона (`''` = корень). Учитывает настройку.
  static Future<String> effective() async {
    final setting = await SettingsStorage.getWarpRegion();
    if (setting == SettingsStorage.warpRegionDefault) return '';
    if (setting != SettingsStorage.warpRegionAuto) return setting;
    return detected();
  }

  /// Страна по сети/локали (нижний регистр, 2 буквы; `''` если неизвестна).
  static Future<String> detected() async {
    final cached = _detected;
    if (cached != null) return cached;
    String? cc;
    try {
      cc = detectorOverride != null
          ? await detectorOverride!()
          : await _channel.invokeMethod<String>('networkCountry');
    } catch (e) {
      // Не Android / канал недоступен (тесты) — идём в локаль.
      AppLog.I.debug('WarpRegion: native lookup failed ($e)');
    }
    cc ??= _localeCountry();
    final norm = cc.trim().toLowerCase();
    return _detected = RegExp(r'^[a-z]{2}$').hasMatch(norm) ? norm : '';
  }

  /// Страна из `Platform.localeName` (`ru_RU`, `en-US`, `he_IL`).
  static String _localeCountry() {
    try {
      final m = RegExp(r'^[A-Za-z]{2,3}[_-]([A-Za-z]{2})\b')
          .firstMatch(Platform.localeName);
      return m?.group(1) ?? '';
    } catch (_) {
      return '';
    }
  }

  /// Сброс кэша детекта (тесты; смена SIM в рантайме не отслеживается).
  static void resetForTest() => _detected = null;
}
