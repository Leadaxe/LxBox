/// §286 — единый реестр активного пробирования папок (`ProbeRunner`).
///
/// Проба папки (§236/§284) гоняет `urlTestOutbound`/`probeUrlTest` по членам
/// пачками; её единственная отмена — кооперативный флаг `_cancelled` внутри
/// runner'а. До §286 этот флаг дёргал ТОЛЬКО экран деталей папки, поэтому sweep
/// переживал stop VPN / смерть туннеля / сворачивание приложения и «молотил»
/// после остановки.
///
/// Реестр разрывает эту связь: каждый `ProbeRunner` регистрирует свой
/// `cancel` на старте `run()` и снимает в `finally`. `HomeController` дёргает
/// [haltAll] из всех «активность пора гасить» переходов (disconnected/revoked,
/// смерть туннеля, app-pause) — и любой активный sweep, кем бы он ни был запущен
/// (экран папки, Debug API), отменяется детерминированно.
class ProbeLifecycle {
  ProbeLifecycle._();

  /// Синглтон (паттерн проекта: `CcChannel.instance`, `SelectorInfo.I`).
  static final ProbeLifecycle I = ProbeLifecycle._();

  /// Активные отменители. `identity`-Set: один runner = один callback-инстанс.
  final Set<void Function()> _cancellers = <void Function()>{};

  /// Зарегистрировать отменитель активного пробирования. Возвращает тот же
  /// callback для симметричного [deregister] в `finally`.
  void Function() register(void Function() cancel) {
    _cancellers.add(cancel);
    return cancel;
  }

  /// Снять отменитель (проба завершилась/отменилась). Идемпотентно.
  void deregister(void Function() cancel) {
    _cancellers.remove(cancel);
  }

  /// Отменить ВСЁ активное пробирование. Дёргается на stop VPN / смерти туннеля
  /// / сворачивании. Снимок берётся до обхода — `cancel()` внутри может
  /// синхронно снять себя через runner'ов `finally` (мутация набора при обходе).
  void haltAll() {
    if (_cancellers.isEmpty) return;
    for (final cancel in _cancellers.toList()) {
      cancel();
    }
    _cancellers.clear();
  }

  /// Есть ли активное пробирование (для тестов/диагностики).
  bool get isProbing => _cancellers.isNotEmpty;
}
