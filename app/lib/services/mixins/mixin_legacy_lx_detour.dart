/// §761 — `lx.mtu_align` переехал в `lx.detour.mtu_align` (ядро
/// v1.14.4-lx.37-rc.2, SPEC 165 форка); исключения `lx.mtu_align.except` —
/// в общий `lx.detour.except_outbounds`.
///
/// Ядро с rc.2 не загружает конфиг со старым ключом (`lx.mtu_align is moved
/// to lx.detour.mtu_align`). Шаблон пишет новый путь; старый может лежать
/// только в миксинах пользователя. [migrateLegacyLxDetourMixin] переписывает
/// его при чтении миксина — как [migrateLegacyLxWgMixin] в §758:
/// идемпотентно, без маркера, значение в `detour` при совпадении сильнее
/// старого.
library;

/// Цель и значение миксина на новой раскладке `lx.detour`.
///
/// Переписывается:
/// - цель `lx.mtu_align` со строкой режима → `lx.detour.mtu_align`;
/// - цель `lx.mtu_align` с объектом `{mode, except}` → цель `lx.detour`,
///   значение `{mtu_align: mode, except_outbounds: except}`;
/// - цели `lx.mtu_align.mode` → `lx.detour.mtu_align`,
///   `lx.mtu_align.except` → `lx.detour.except_outbounds`;
/// - объект-значение у цели `lx` или корня: `mtu_align` уходит в `detour`.
///
/// Всё прочее возвращается как есть.
({String target, Object? value}) migrateLegacyLxDetourMixin(
    String target, String op, Object? value) {
  switch (target) {
    case 'lx.mtu_align':
      if (value is Map) {
        return (target: 'lx.detour', value: _detourFromLegacy(value));
      }
      return (target: 'lx.detour.mtu_align', value: value);
    case 'lx.mtu_align.mode':
      return (target: 'lx.detour.mtu_align', value: value);
    case 'lx.mtu_align.except':
      return (target: 'lx.detour.except_outbounds', value: value);
    case 'lx':
      return (target: target, value: _lx(value));
    case '':
      if (value is! Map || !value.containsKey('lx')) {
        return (target: target, value: value);
      }
      final lx = value['lx'];
      final next = _lx(lx);
      if (identical(next, lx)) return (target: target, value: value);
      return (target: target, value: {...value, 'lx': next});
  }
  return (target: target, value: value);
}

/// Объект `lx` без `mtu_align`: он — в `detour`.
Object? _lx(Object? lx) {
  if (lx is! Map || !lx.containsKey('mtu_align')) return lx;
  final legacy = lx['mtu_align'];
  final existing = lx['detour'];
  if (existing != null && existing is! Map) {
    // `detour: true/false` — не наше дело чинить; оставляем как было.
    return lx;
  }
  final detour = <String, dynamic>{
    ...?(legacy is Map
        ? _detourFromLegacy(legacy)
        : legacy == null
            ? null
            : {'mtu_align': legacy}),
    if (existing is Map)
      for (final e in existing.entries) '${e.key}': e.value,
  };
  return {
    for (final e in lx.entries)
      if (e.key != 'mtu_align' && e.key != 'detour') '${e.key}': e.value,
    'detour': detour,
  };
}

/// `{mode, except}` старого `lx.mtu_align` → поля `lx.detour`.
Map<String, dynamic> _detourFromLegacy(Map legacy) => {
      if (legacy.containsKey('mode')) 'mtu_align': legacy['mode'],
      if (legacy.containsKey('except')) 'except_outbounds': legacy['except'],
    };
