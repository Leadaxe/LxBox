import 'dart:async';

import 'package:flutter/widgets.dart';

import '../controllers/subscription_controller.dart';

/// §085 R4 / §076 — общая lazy write-on-exit машинерия для editing-экранов.
///
/// До §085 этот скелет (`_pendingChanges` flag + flush-on-dispose +
/// flush-on-`paused` + sync `configDirty` mark) был byte-for-byte
/// продублирован в 4 экранах (tun_apps_tab, dns_settings_screen,
/// routing_screen, settings_screen Core vars). Mixin захватывает общее;
/// screen-specific disk-write остаётся в [persistChanges].
///
/// **Контракт §076**:
/// - [markDirty] вызывается **синхронно** на каждую mutation — ставит
///   `configDirty=true` сразу (видим `homeReturnObserver` который читает
///   флаг на возврат к home; race-safe).
/// - disk-write deferred до `dispose()` (Navigator.pop) или
///   `AppLifecycleState.paused` (app backgrounded) — атомарный (§072).
/// - `configDirty` **не** сбрасывается в [persistChanges] (rebuild на home
///   его очистит; см. §076 spec).
///
/// Применение:
/// ```dart
/// class _FooState extends State<Foo>
///     with WidgetsBindingObserver, LazyPersistMixin<Foo> {
///   @override
///   SubscriptionController get lazyController => widget.subController;
///   @override
///   Future<void> persistChanges() async { await SettingsStorage.saveX(...); }
///   // на mutation: markDirty();
/// }
/// ```
mixin LazyPersistMixin<T extends StatefulWidget>
    on State<T>, WidgetsBindingObserver {
  bool _lazyPending = false;

  /// True если есть несохранённые изменения (для тестов / условной логики).
  bool get hasPendingChanges => _lazyPending;

  /// Controller, чей `configDirty` помечается на mutation.
  SubscriptionController get lazyController;

  /// Screen-specific atomic disk-write. Вызывается mixin'ом при flush
  /// (dispose / paused). `configDirty` уже выставлен в [markDirty].
  Future<void> persistChanges();

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

  /// Sync mark на каждую mutation. Ставит pending + `configDirty` сразу.
  void markDirty() {
    _lazyPending = true;
    lazyController.configDirty = true; // sync — race-safe для home observer
  }

  Future<void> _flush() async {
    if (!_lazyPending) return; // idempotent: already flushed
    _lazyPending = false;
    await persistChanges();
  }
}
