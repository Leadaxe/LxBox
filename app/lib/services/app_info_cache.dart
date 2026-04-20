import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/foundation.dart';

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
class AppInfoCache {
  AppInfoCache._();

  static final _cache = <String, AppInfo?>{};
  static final _inFlight = <String>{};

  /// Инкрементится при каждом обновлении cache'а. Подпишись через
  /// AnimatedBuilder(animation: revision).
  static final ValueNotifier<int> revision = ValueNotifier<int>(0);

  static final BoxVpnClient _vpn = BoxVpnClient();

  /// Текущее значение из cache или null.
  static AppInfo? of(String pkg) => _cache[pkg];

  /// Планирует fetch если ещё не пытались. Fire-and-forget.
  static void ensure(String pkg) {
    if (pkg.isEmpty) return;
    if (_cache.containsKey(pkg) || _inFlight.contains(pkg)) return;
    _inFlight.add(pkg);
    unawaited(_fetch(pkg));
  }

  static Future<void> _fetch(String pkg) async {
    try {
      final raw = await _vpn.getAppInfo(pkg);
      _cache[pkg] = raw == null ? null : AppInfo.fromJson(raw);
    } catch (_) {
      _cache[pkg] = null;
    } finally {
      _inFlight.remove(pkg);
      revision.value = revision.value + 1;
    }
  }
}

class AppInfo {
  const AppInfo({
    required this.packageName,
    required this.appName,
    required this.isSystem,
    this.icon,
  });

  final String packageName;
  final String appName;
  final bool isSystem;
  final Uint8List? icon;

  factory AppInfo.fromJson(Map<String, dynamic> j) {
    final iconStr = j['icon'] as String? ?? '';
    Uint8List? bytes;
    if (iconStr.isNotEmpty) {
      try {
        bytes = base64Decode(iconStr);
      } catch (_) {}
    }
    return AppInfo(
      packageName: (j['packageName'] as String?) ?? '',
      appName: (j['appName'] as String?) ?? (j['packageName'] as String? ?? ''),
      isSystem: (j['isSystemApp'] as bool?) ?? false,
      icon: bytes,
    );
  }
}
