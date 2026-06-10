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
/// §109 — семантика записей (см. tasks/109):
///   - нет ключа в `_cache`     → ещё не проверяли, или проверка сорвалась
///                                 и ждёт retry — состояние «unknown»;
///   - `_cache[pkg] == null`    → native ПОДТВЕРДИЛ «не установлено»
///                                 (NameNotFoundException), не дёргаем
///                                 повторно;
///   - `_cache[pkg] == AppInfo` → установлено.
/// Timeout / ошибка канала null НЕ пишут (раньше писали — и приложение до
/// конца сессии помечалось «uninstalled» на Tunnel apps) — вместо этого до
/// [retryDelays].length повторов с нарастающей задержкой; ручной [ensure]
/// после исчерпания даёт ещё одну попытку.
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

  /// §109: счётчик сорвавшихся проверок (timeout / PlatformException) на
  /// pkg. Сбрасывается при успешном ответе native (любом — found/not-found).
  static final _attempts = <String, int>{};

  static const List<Duration> _defaultRetryDelays = [
    Duration(seconds: 2),
    Duration(seconds: 5),
    Duration(seconds: 15),
  ];

  /// Задержки между повторами после сорвавшейся проверки. Длина списка =
  /// максимум автоматических повторов. Переопределяется только в тестах.
  @visibleForTesting
  static List<Duration> retryDelays = _defaultRetryDelays;

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

  /// §109: true только когда native ПОДТВЕРДИЛ что пакет не установлен.
  /// «Ещё грузится» и «проверка сорвалась» → false — UI не имеет права
  /// рисовать «uninstalled» по этим состояниям.
  static bool isNotFound(String pkg) =>
      _cache.containsKey(pkg) && _cache[pkg] == null;

  /// Планирует fetch. Fire-and-forget.
  ///
  /// 3 случая:
  /// 1. Никогда не пытались (или прошлые попытки сорвались) →
  ///    `getAppInfo(pkg)` (метаданные; иконка дотянется вторым вызовом).
  /// 2. Пытались, native подтвердил «не установлено»
  ///    (`_cache[pkg] == null`) → no-op.
  /// 3. Уже есть AppInfo, но **без icon'а** (например, попал сюда из
  ///    `loadAllApps()` который lightweight-mode без иконок) → fetch'аем
  ///    icon отдельно через `getAppIcon` и обновляем cache.
  static void ensure(String pkg) {
    if (pkg.isEmpty) return;
    if (_inFlight.contains(pkg)) return;
    if (_cache.containsKey(pkg)) {
      final existing = _cache[pkg];
      if (existing == null) return; // подтверждённый not-found
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
      // обновляем (свежие данные с native). Заодно лечит ложные
      // null-записи и сбрасывает retry-счётчики (§109).
      var changed = false;
      for (final a in apps) {
        if (a.packageName.isEmpty) continue;
        _cache[a.packageName] = a;
        _inFlight.remove(a.packageName);
        _attempts.remove(a.packageName);
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
    AppInfo? info;
    var verified = false;
    try {
      // §109 контракт BoxVpnClient.getAppInfo: AppInfo = установлен,
      // null = ПОДТВЕРЖДЁННЫЙ not-found, throw = не удалось проверить.
      info = await _vpn.getAppInfo(pkg);
      verified = true;
    } catch (_) {
      // Timeout / PlatformException — retryable. НЕ кэшируем «не
      // установлено» (до §109 кэшировали — ложный «uninstalled» до конца
      // сессии).
    }
    if (!verified) {
      _inFlight.remove(pkg);
      _scheduleRetry(pkg);
      return;
    }
    _attempts.remove(pkg);
    _cache[pkg] = info;
    if (info == null) {
      _inFlight.remove(pkg);
      revision.value = revision.value + 1;
      return;
    }
    // Метаданные есть — имя показываем сразу, иконку дотягиваем вторым
    // вызовом (native getAppInfo с §109 иконку не шлёт).
    revision.value = revision.value + 1;
    await _fetchIcon(pkg, info); // снимет _inFlight + bump revision в finally
  }

  /// §109: повтор после сорвавшейся проверки. Максимум
  /// `retryDelays.length` автоматических попыток на pkg; дальше пакет
  /// остаётся «unknown» (без записи в cache), и следующий ручной [ensure]
  /// (новый заход на экран) пробует снова.
  static void _scheduleRetry(String pkg) {
    final n = (_attempts[pkg] ?? 0) + 1;
    _attempts[pkg] = n;
    if (n > retryDelays.length) return;
    unawaited(Future.delayed(retryDelays[n - 1], () {
      // Кто-то мог успеть: ручной ensure (in flight) или loadAllApps
      // (запись в cache) — тогда повтор не нужен.
      if (_cache.containsKey(pkg) || _inFlight.contains(pkg)) return;
      _inFlight.add(pkg);
      unawaited(_fetch(pkg));
    }));
  }

  /// Lightweight icon-only fetch для случая когда AppInfo уже есть (из
  /// `loadAllApps` или metadata-ответа `_fetch`), а icon — нет.
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

  /// Полный сброс статического состояния между тестами.
  @visibleForTesting
  static void resetForTest() {
    _cache.clear();
    _inFlight.clear();
    _attempts.clear();
    _allApps = null;
    _allLoading = false;
    retryDelays = _defaultRetryDelays;
    revision.value = 0;
  }
}
