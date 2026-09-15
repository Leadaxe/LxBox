part of '../post_steps.dart';

/// §442 — правило 8 графового санитайзера: пара `interval`/`idle_timeout` у
/// `urltest`. Порт правила 6 лаунчера (`core/build/outbound_graph_urltest.go`,
/// SPEC 128).
///
/// Ядро строит группу так (`protocol/group/urltest.go`, `NewURLTestGroup`):
/// нулевой `interval` → 3m, нулевой `idle_timeout` → 30m, затем
/// `interval > idle_timeout` — фатальная ошибка «interval must be less or
/// equal than idle_timeout». Проверка живёт в КОНСТРУКТОРЕ группы, а не в
/// разборе схемы: `sing-box check` конфиг принимает, падает только `run`.
/// Режим `round_robin` форка lx идёт тем же `Start()` → `NewURLTestGroup` —
/// балансировщик цепляется к группе уже после проверки.
///
/// Входов, где пара расходится, несколько: Xray-балансер берёт `interval` из
/// `burstObservatory.pingConfig`, а `idle_timeout` — всегда умолчание 30m;
/// группа sing-box подписки переносит `interval` провайдера без пары;
/// Направление и узел автовыбора хранят оба поля независимо. Правило живёт
/// здесь одно, а не проверкой в каждом входе.
///
/// Политика — поднять `idle_timeout` до `interval` (×1), `interval` не менять
/// никогда: это частота перепроверки ВСЕХ узлов группы, и замена провайдерских
/// 3h на 5m дала бы серверу в 36 раз больше проб, чем он просил.
/// `idle_timeout` про нагрузку не отвечает — это простой, после которого группа
/// перестаёт проверять себя фоном; его удлинение стоит одной лишней проверки у
/// неактивной группы. При ×1 в конфиге стоит ровно пришедшее значение, без
/// изобретённого нами.
///
/// Разбор — по правилам ЯДРА ([parseCoreDurationNanos], суффикс `d`
/// включён). Не распознанное ядром значение (мусор, пустая строка, не строка)
/// не трогается: ядро отвергнет его с ошибкой про сам ключ, а подстановка
/// спрятала бы ошибку конфига. Отрицательные значения — тоже не наш класс.
///
/// Отсутствие ключа и `0` значат для ядра одно и то же — умолчание. Поэтому
/// группа без `interval`, но с `idle_timeout` меньше 3m, тоже падает, и
/// `idle_timeout` поднимается до `3m` (у эталона лаунчера этой ветки нет).
///
/// Каждое вмешательство — строка в [warnings] с обеими величинами и причиной.
void _sanitizeUrltestTimings(
  Map<String, dynamic> e,
  List<String> warnings,
) {
  if (e['type'] != 'urltest') return;

  final interval = _urltestDuration(e, 'interval', _kCoreUrltestIntervalNs);
  final idle = _urltestDuration(e, 'idle_timeout', _kCoreUrltestIdleTimeoutNs);
  if (interval == null || idle == null) return;
  if (interval.ns <= idle.ns) return;

  // `interval` остаётся как есть; `idle_timeout` получает его же строку, а
  // при умолчании ядра — её литерал (строки в конфиге нет).
  final target = interval.raw ?? _kCoreUrltestInterval;
  e['idle_timeout'] = target;

  String describe(({int ns, String? raw}) d, String coreDefault) =>
      d.raw == null ? '$coreDefault (core default)' : '"${d.raw}"';
  final tag = _tagOf(e);
  warnings.add(
      'Group "$tag": interval ${describe(interval, _kCoreUrltestInterval)} is '
      'greater than idle_timeout '
      '${describe(idle, _kCoreUrltestIdleTimeout)} — idle_timeout '
      '${idle.raw == null ? 'set' : 'raised'} to "$target", otherwise the core '
      'would not start. The interval is kept: shortening it would probe the '
      'servers more often than configured.');
}

/// Умолчания ядра (`constant/timeout.go`): `DefaultURLTestInterval`,
/// `DefaultURLTestIdleTimeout`.
const _kCoreUrltestInterval = '3m';
const _kCoreUrltestIdleTimeout = '30m';
const _kCoreUrltestIntervalNs = 3 * 60 * 1000000000;
const _kCoreUrltestIdleTimeoutNs = 30 * 60 * 1000000000;

/// Действующее для ядра значение поля [key]: `ns` и исходная строка `raw`
/// (`null` — ядро возьмёт умолчание [defaultNs]). `null` целиком — значение
/// ядро отвергнет само или оно отрицательно: такое правило не трогает.
({int ns, String? raw})? _urltestDuration(
  Map<String, dynamic> e,
  String key,
  int defaultNs,
) {
  if (!e.containsKey(key)) return (ns: defaultNs, raw: null);
  final raw = e[key];
  if (raw is! String) return null;
  final ns = parseCoreDurationNanos(raw);
  if (ns == null || ns < 0) return null;
  if (ns == 0) return (ns: defaultNs, raw: null);
  return (ns: ns, raw: raw);
}
