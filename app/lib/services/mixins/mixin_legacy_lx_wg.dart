/// §758 — ключи сна WireGuard переехали в `lx.wg.idle` (ядро v1.14.4-lx.36).
///
/// Ядро с lx.36 не загружает конфиг с прежними плоскими именами
/// (`lx.wg.idle_suspend is moved to lx.wg.idle.suspend`), периода
/// совместимости нет. Генератор пишет новые имена из шаблона; старые имена
/// могут лежать только в миксинах пользователя (хранилище, бэкап, Debug API).
/// [migrateLegacyLxWgMixin] переписывает их при чтении миксина: идемпотентно,
/// без маркера, новое имя при совпадении сильнее старого.
library;

/// Прежнее плоское имя в `lx.wg` → имя внутри `lx.wg.idle`.
const Map<String, String> kLegacyLxWgIdleKeys = {
  'idle_suspend': 'suspend',
  'idle_suspend_reachable': 'suspend_reachable',
  'idle_teardown': 'teardown',
  'lazy_build': 'lazy_build',
  'build_max': 'build_max',
  'build_overflow': 'build_overflow',
};

/// Цель и значение миксина на новой раскладке `lx.wg`.
///
/// Переписывается:
/// - цель `lx.wg.<старое>` (и глубже) → `lx.wg.idle.<новое>`;
/// - объект-значение у цели `lx.wg`, `lx` или корня: старые ключи внутри
///   `wg` уходят в `wg.idle`;
/// - `remove` у цели `lx.wg` со списком ключей, если все они старые, —
///   цель `lx.wg.idle` с новыми именами.
///
/// Всё прочее возвращается как есть.
({String target, Object? value}) migrateLegacyLxWgMixin(
    String target, String op, Object? value) {
  const prefix = 'lx.wg.';
  if (target.startsWith(prefix)) {
    final rest = target.substring(prefix.length);
    final dot = rest.indexOf('.');
    final head = dot < 0 ? rest : rest.substring(0, dot);
    final renamed = kLegacyLxWgIdleKeys[head];
    if (renamed != null) {
      final tail = dot < 0 ? '' : rest.substring(dot);
      return (target: '${prefix}idle.$renamed$tail', value: value);
    }
    return (target: target, value: value);
  }
  switch (target) {
    case 'lx.wg':
      if (op == 'remove' && value is List && value.isNotEmpty &&
          value.every((k) => k is String && kLegacyLxWgIdleKeys.containsKey(k))) {
        return (
          target: 'lx.wg.idle',
          value: [for (final k in value) kLegacyLxWgIdleKeys[k as String]],
        );
      }
      return (target: target, value: _wg(value));
    case 'lx':
      return (target: target, value: _withChild(value, 'wg', _wg));
    case '':
      return (
        target: target,
        value: _withChild(value, 'lx', (lx) => _withChild(lx, 'wg', _wg)),
      );
  }
  return (target: target, value: value);
}

Object? _withChild(Object? v, String key, Object? Function(Object?) f) {
  if (v is! Map || !v.containsKey(key)) return v;
  final child = v[key];
  final next = f(child);
  if (identical(next, child)) return v;
  return {...v, key: next};
}

/// Объект `wg` без старых ключей: они — в `idle` под новыми именами.
Object? _wg(Object? wg) {
  if (wg is! Map || !wg.keys.any(kLegacyLxWgIdleKeys.containsKey)) return wg;
  final out = <String, dynamic>{};
  final idle = <String, dynamic>{};
  final existing = wg['idle'];
  for (final e in wg.entries) {
    final renamed = kLegacyLxWgIdleKeys[e.key];
    if (renamed != null) {
      idle[renamed] = e.value;
    } else if (e.key != 'idle') {
      out['${e.key}'] = e.value;
    }
  }
  if (existing is Map) {
    for (final e in existing.entries) {
      idle['${e.key}'] = e.value;
    }
  } else if (existing != null) {
    // Не объект — не наше дело чинить; оставляем как было.
    return wg;
  }
  out['idle'] = idle;
  return out;
}
