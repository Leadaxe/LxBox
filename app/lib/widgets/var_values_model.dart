import 'package:flutter/foundation.dart';

/// §232 — реактивная модель значений template-vars экрана настроек.
///
/// Единый источник истины вместо двух копий (`_varValues` в State +
/// приватная `_values` в [TemplateVarListView]), рассинхрон которых терял
/// программные изменения (`on_change`: галка ipv6 → стратегии).
///
/// Per-key подписка: каждый ключ — свой [ValueNotifier]; виджет-поле
/// оборачивается в [ValueListenableBuilder] на СВОЙ ключ и перерисовывается
/// только на его изменение (одностороннее emit, как просил дизайн §232).
///
/// [set] меняет ТОЛЬКО память (+ помечает ключ dirty) — НЕ пишет
/// storage/cache. Диск/cache трогает только `_persist` экрана-владельца
/// (dispose/paused), итерируя [dirtyKeys]. Юзер, ушедший до persist, ничего
/// не «сохранил» — ровно требуемая семантика.
class VarValuesModel {
  VarValuesModel(Map<String, String> initial) {
    for (final e in initial.entries) {
      _notifiers[e.key] = ValueNotifier<String>(e.value);
    }
  }

  final _notifiers = <String, ValueNotifier<String>>{};
  final _dirty = <String>{};

  /// Notifier ключа — для подписки поля ([ValueListenableBuilder]).
  /// Отсутствующий ключ создаётся лениво с пустым значением (не крашим UI
  /// на var, которого не было в seed).
  ValueNotifier<String> notifier(String name) =>
      _notifiers.putIfAbsent(name, () => ValueNotifier<String>(''));

  String get(String name) => _notifiers[name]?.value ?? '';

  /// Плоский снимок для резолвера #if-движка (`makeResolver`).
  Map<String, String> get snapshot =>
      {for (final e in _notifiers.entries) e.key: e.value.value};

  /// Ключи, изменённые с момента создания/последнего [clearDirty] —
  /// то, что `_persist` должен донести до storage.
  Set<String> get dirtyKeys => Set.unmodifiable(_dirty);

  /// In-memory запись + emit подписчикам ключа. Storage НЕ трогает.
  /// Возвращает true, если значение реально изменилось.
  ///
  /// [markDirty]=false — display-only запись (§161: пустое required-поле
  /// видно в UI, но НЕ попадает в persist). Вместе с [unstage] гарантирует,
  /// что пустота required-var никогда не доезжает до storage.
  bool set(String name, String value, {bool markDirty = true}) {
    final n = notifier(name);
    if (n.value == value) return false;
    n.value = value; // ValueNotifier сам оповестит слушателей
    if (markDirty) _dirty.add(name);
    return true;
  }

  /// §161 — снять ключ со staged-персиста (пустое required: и текущий ввод,
  /// и предыдущий staged-ввод не сохраняются; storage остаётся при исходном).
  void unstage(String name) => _dirty.remove(name);

  void clearDirty() => _dirty.clear();

  void dispose() {
    for (final n in _notifiers.values) {
      n.dispose();
    }
    _notifiers.clear();
  }
}
