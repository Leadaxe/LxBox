import 'dart:async';

import 'package:flutter/widgets.dart';

import '../controllers/subscription_controller.dart';
import '../services/settings_storage.dart';

/// §085 R4 / §076 / §107 — общая lazy write-on-exit машинерия для
/// editing-экранов.
///
/// **Контракт §107** (staging):
/// - [markDirty] вызывается **синхронно** на каждую mutation — ставит
///   `configDirty=true` сразу и стартует [stageChanges]: буфер экрана
///   уезжает в in-memory `SettingsStorage._cache` в ближайших микротасках
///   (заведомо до следующего жеста юзера). Любой читатель — rebuild на
///   возврате к home, гейт на Start, bootstrap — видит свежие данные, не
///   дожидаясь dispose.
/// - Дисковая запись deferred до `dispose()` (Navigator.pop) или
///   `AppLifecycleState.paused` (app backgrounded) — один атомарный
///   `SettingsStorage.flushToDisk()` (§072).
/// - `configDirty` **не** сбрасывается здесь — его очищает успешный rebuild.
///
/// История: §076 предполагал, что flush-on-dispose успевает раньше, чем
/// home-handler прочитает storage. Предпосылка была неверна — `didPop`
/// стреляет в момент pop'а, а dispose — после exit-анимации (~300 мс
/// позже); конфиг собирался из состояния «до последней правки»
/// (см. docs/spec/tasks/107).
///
/// Применение:
/// ```dart
/// class _FooState extends State<Foo>
///     with WidgetsBindingObserver, LazyPersistMixin<Foo> {
///   @override
///   SubscriptionController get lazyController => widget.subController;
///   @override
///   Future<void> stageChanges() async {
///     await SettingsStorage.saveX(_cfg, flush: false);
///   }
///   // на mutation: markDirty();
/// }
/// ```
mixin LazyPersistMixin<T extends StatefulWidget>
    on State<T>, WidgetsBindingObserver {
  bool _lazyPending = false;

  /// True если есть не записанные на диск изменения (для тестов / условной
  /// логики).
  bool get hasPendingChanges => _lazyPending;

  /// Controller, чей `configDirty` помечается на mutation.
  SubscriptionController get lazyController;

  /// Screen-specific staging (§107): переносит локальный буфер экрана в
  /// in-memory `SettingsStorage._cache` через `setX(..., flush: false)` —
  /// без диска. Вызывается mixin'ом на каждую mutation ([markDirty]) и ещё
  /// раз перед дисковым flush'ем (safety-net, идемпотентно).
  Future<void> stageChanges();

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    // write-on-exit: Navigator.pop → dispose → flush. dispose не await'ит —
    // unawaited; write атомарен (§072), corrupt-state невозможен.
    if (_lazyPending) unawaited(_flush());
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    // safety-net: app backgrounded → flush (OS может убить process). Только
    // `paused` — `inactive` слишком часто (transient).
    if (state == AppLifecycleState.paused && _lazyPending) {
      unawaited(_flush());
    }
  }

  /// Sync mark на каждую mutation: pending + `configDirty` сразу; staging
  /// буфера в `_cache` стартует тут же (без диска).
  void markDirty() {
    _lazyPending = true;
    lazyController.configDirty = true; // sync — race-safe для home observer
    unawaited(stageChanges());
  }

  Future<void> _flush() async {
    if (!_lazyPending) return; // idempotent: already flushed
    _lazyPending = false;
    await stageChanges(); // safety-net: буфер гарантированно в _cache
    await SettingsStorage.flushToDisk();
  }
}
