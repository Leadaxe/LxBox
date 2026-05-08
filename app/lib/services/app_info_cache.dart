import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';

import '../models/app_info.dart';
import '../vpn/box_vpn_client.dart';

/// Session-level cache для app info (display name + icon) по package name.
///
/// Заполняется lazy — handler вызывает [ensure] для pkg'а, при необходимости
/// native `getAppInfo` fire'ится; когда ответ пришёл — cache обновлён и
/// [revision] инкрементится. UI должен AnimatedBuilder'ить на [revision]
/// чтобы перерисоваться когда новая запись подъехала.
///
/// null-значение в cache = уже попробовали, но pkg не найден (uninstalled).
/// Не дёргаем повторно.
///
/// **Полный installed-apps list** (для AppPicker'ов) тоже хранится тут —
/// `loadAllApps()` грузит весь список через `getInstalledApps()` один раз
/// и переиспользует его между разными picker'ами (multi-select из Custom
/// Rules и single-pick из Per-app trace, §044). Каждый загруженный
/// AppInfo заодно populate'ится в `_cache`, так что иконки кочуют между
/// picker'ами без повторных native-вызовов.
class AppInfoCache {
  AppInfoCache._();

  static final _cache = <String, AppInfo?>{};
  static final _inFlight = <String>{};

  /// Инкрементится при каждом обновлении cache'а. Подпишись через
  /// AnimatedBuilder(animation: revision).
  static final ValueNotifier<int> revision = ValueNotifier<int>(0);

  static final BoxVpnClient _vpn = BoxVpnClient();

  /// Полный список installed apps (sorted by appName). Кэшируется один
  /// раз на сессию.
  static List<AppInfo>? _allApps;
  static bool _allLoading = false;

  /// Текущее значение из cache или null.
  static AppInfo? of(String pkg) => _cache[pkg];

  /// Планирует fetch. Fire-and-forget.
  ///
  /// 3 случая:
  /// 1. Никогда не пытались → `getAppInfo(pkg)` (полное метадата + icon).
  /// 2. Пытались, ничего не нашли (`_cache[pkg] == null`) → no-op.
  /// 3. Уже есть AppInfo, но **без icon'а** (например, попал сюда из
  ///    `loadAllApps()` который lightweight-mode без иконок) → fetch'аем
  ///    icon отдельно через `getAppIcon` и обновляем cache.
  static void ensure(String pkg) {
    if (pkg.isEmpty) return;
    if (_inFlight.contains(pkg)) return;
    if (_cache.containsKey(pkg)) {
      final existing = _cache[pkg];
      if (existing == null) return; // already tried, not found
      if (existing.icon != null) return; // already have icon
      _inFlight.add(pkg);
      unawaited(_fetchIcon(pkg, existing));
      return;
    }
    _inFlight.add(pkg);
    unawaited(_fetch(pkg));
  }

  /// Загружает весь list установленных apps (через native
  /// `getInstalledApps`). Кэшируется на сессию: повторные вызовы получают
  /// тот же list мгновенно. Заодно populate'ит `_cache` всеми entries —
  /// AppPicker'ы и любой UI, который использует `AppInfoCache.of(pkg)`,
  /// сразу видит icons + appName без отдельного `getAppInfo` вызова.
  static Future<List<AppInfo>> loadAllApps() async {
    if (_allApps != null) return _allApps!;
    if (_allLoading) {
      while (_allLoading) {
        await Future.delayed(const Duration(milliseconds: 100));
      }
      return _allApps ?? const <AppInfo>[];
    }
    _allLoading = true;
    try {
      final apps = await _vpn.getInstalledApps()
        ..sort((a, b) =>
            a.appName.toLowerCase().compareTo(b.appName.toLowerCase()));
      // Populate per-package cache. Если уже есть запись для pkg —
      // обновляем (свежие данные с native).
      var changed = false;
      for (final a in apps) {
        if (a.packageName.isEmpty) continue;
        _cache[a.packageName] = a;
        _inFlight.remove(a.packageName);
        changed = true;
      }
      _allApps = apps;
      if (changed) revision.value = revision.value + 1;
      return apps;
    } finally {
      _allLoading = false;
    }
  }

  static Future<void> _fetch(String pkg) async {
    try {
      // BoxVpnClient.getAppInfo уже возвращает typed AppInfo (или null если
      // package не установлен).
      _cache[pkg] = await _vpn.getAppInfo(pkg);
    } catch (_) {
      _cache[pkg] = null;
    } finally {
      _inFlight.remove(pkg);
      revision.value = revision.value + 1;
    }
  }

  /// Lightweight icon-only fetch для случая когда AppInfo уже есть (из
  /// `loadAllApps`), а icon — нет. Меньше пейлоад чем `_fetch` (полное
  /// `getAppInfo`).
  static Future<void> _fetchIcon(String pkg, AppInfo existing) async {
    try {
      final b64 = await _vpn.getAppIcon(pkg);
      Uint8List? bytes;
      if (b64.isNotEmpty) {
        try {
          bytes = base64Decode(b64);
        } catch (_) {}
      }
      _cache[pkg] = AppInfo(
        packageName: existing.packageName,
        appName: existing.appName,
        isSystem: existing.isSystem,
        icon: bytes,
      );
    } catch (_) {
      // Keep existing entry; just don't have icon.
    } finally {
      _inFlight.remove(pkg);
      revision.value = revision.value + 1;
    }
  }
}
