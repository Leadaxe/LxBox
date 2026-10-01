/// Кодек записи свёртки источника `replace {mode, tag, auto}` (фича 565
/// фаза B, контракт 1.1.78 §74, `backup.schema.json#/$defs/replace`) и формы
/// `auto` Направления (`direction.schema.json#/$defs/auto`), которую свёртка
/// переиспользует. Форма одна в хранении и в бэкапе.
library;

import '../direction.dart';
import '../source_replace.dart';

/// Ключи `replace` и его `auto`: незнакомое называется путём в `unknown`.
const Set<String> kReplaceRecordKeys = {'mode', 'tag', 'auto'};
const Set<String> kDirectionAutoRecordKeys = {
  'mode',
  'url',
  'interval',
  'tolerance',
  'idle_timeout',
  'interrupt_exist_connections',
  'pool',
  'pool_tolerance',
  'sticky_hash',
};

/// Свёртка → запись. `auto` пишется только у режима с автовыбором (§74:
/// при `manual` отсутствует).
Map<String, dynamic> sourceReplaceToRecord(SourceReplace r) => {
      'mode': r.mode.name,
      'tag': r.tag,
      if (r.hasAuto && r.auto != null) 'auto': directionAutoToRecord(r.auto!),
    };

/// Запись → свёртка. Не объект — свёртки нет. Неизвестный `mode` —
/// `manual` (§74). `auto` у `manual` не читается: при ручном режиме его нет.
/// Незнакомые ключи — в [unknown] путями `replace.<ключ>`.
SourceReplace? sourceReplaceFromRecord(Object? raw, [List<String>? unknown]) {
  if (raw is! Map) return null;
  final j = raw.cast<String, dynamic>();
  for (final k in j.keys) {
    if (!kReplaceRecordKeys.contains(k)) unknown?.add('replace.$k');
  }
  final mode = ReplaceMode.fromWire(j['mode']);
  final tag = j['tag'] is String ? (j['tag'] as String).trim() : '';
  final rawAuto = j['auto'];
  DirectionAuto? auto;
  if (rawAuto is Map) {
    final a = rawAuto.cast<String, dynamic>();
    for (final k in a.keys) {
      if (!kDirectionAutoRecordKeys.contains(k)) unknown?.add('replace.auto.$k');
    }
    if (mode != ReplaceMode.manual) auto = directionAutoFromRecord(a);
  }
  return SourceReplace(mode: mode, tag: tag, auto: auto);
}

/// Каноническая форма `auto` Направления → модель.
DirectionAuto directionAutoFromRecord(Map<String, dynamic> j) {
  const fallback = DirectionAuto();
  final rawSticky = j['sticky_hash'];
  // Канон: пустой список НЕ выключает липкость (ядро схлопывает его в
  // умолчание) — выключение это явный ["none"], которого у мобилы нет
  // отдельным ключом: она выражает его пустым списком.
  final sticky = rawSticky is List
      ? (rawSticky.contains('none')
            ? const <StickyHashKey>[]
            : rawSticky
                  .map((e) => StickyHashKey.fromWire(e as String?))
                  .whereType<StickyHashKey>()
                  .toList())
      : fallback.stickyHash;

  return DirectionAuto(
    mode: UrltestMode.fromWire(j['mode'] as String?),
    url: (j['url'] as String?) ?? fallback.url,
    interval: (j['interval'] as String?) ?? fallback.interval,
    // Ноль от чужой стороны означает «не задано» (`templateIntToBackup`
    // разворачивает ссылку на переменную шаблона в 0) — берём своё умолчание,
    // а не чужой ноль: подставлять 0 мс честнее не становится.
    tolerance: clampDirectionTolerance(
      (j['tolerance'] as num?)?.toInt() ?? fallback.tolerance,
    ),
    idleTimeout: (j['idle_timeout'] as String?) ?? fallback.idleTimeout,
    interruptExistConnections:
        j['interrupt_exist_connections'] as bool? ??
        fallback.interruptExistConnections,
    pool: clampDirectionPool((j['pool'] as num?)?.toInt() ?? fallback.pool),
    poolTolerance: clampDirectionTolerance(
      (j['pool_tolerance'] as num?)?.toInt() ?? fallback.poolTolerance,
    ),
    stickyHash: sticky,
  );
}

/// Модель → каноническая форма `auto` Направления.
Map<String, dynamic> directionAutoToRecord(DirectionAuto a) => {
  'mode': a.mode.wire,
  'url': a.url,
  'interval': a.interval,
  'tolerance': clampDirectionTolerance(a.tolerance),
  'idle_timeout': a.idleTimeout,
  'interrupt_exist_connections': a.interruptExistConnections,
  // Балансировочные поля значат что-то только у round_robin — у
  // least_test они уехали бы шумом, который принимающая сторона не
  // отличит от осознанной настройки.
  if (a.mode == UrltestMode.roundRobin) ...{
    'pool': clampDirectionPool(a.pool),
    'pool_tolerance': clampDirectionTolerance(a.poolTolerance),
    // Пустой список у мобилы = липкость выключена; канон выражает
    // выключение явным ["none"], а пустой список схлопнул бы в умолчание.
    'sticky_hash': a.stickyHash.isEmpty
        ? const ['none']
        : [for (final k in a.stickyHash) k.wire],
  },
};
