/// LX Backup v1 — переносимый формат обмена настройками с десктопным
/// лаунчером (SPEC 103, фаза 4). Подробности — в docstring ниже.
library;

import 'dart:convert';

import 'package:package_info_plus/package_info_plus.dart';

import '../models/custom_rule.dart';
import '../config/consts.dart';
import '../models/direction.dart';
import '../models/server_list.dart';

/// LX Backup v1 — переносимый формат обмена настройками с десктопным
/// лаунчером (SPEC 103, фаза 4).
///
/// Схема — `contract/schema/backup.schema.json`, семантика —
/// `contract/docs/BACKUP.md`. Это НЕ замена [BackupService]: тот делает
/// полный снимок настроек для той же самой установки, а этот переносит
/// общую часть между приложениями.
///
/// Три инварианта:
///
///  1. Lossless round-trip: непереносимое (`packages`, `wifiSsids`, папки)
///     уезжает в `extensions.lxbox` и обязано пережить чужой импорт
///     нетронутым — иначе бэкап, побывавший на десктопе, возвращается
///     обеднённым.
///  2. Default-deny: неизвестный ключ вне `extensions` не применяется молча.
///  3. Нет молчаливых потерь: неприменённое названо кодом warning'а.

/// Мажорная версия формата.
const int kLxBackupVersion = 1;

const String kLxAppLxBox = 'lxbox';
const String kLxAppLauncher = 'launcher';

/// Коды предупреждений импорта (общие с Go-стороной).
const String kWarnUnknownOutbound = 'backup_unknown_outbound';
const String kWarnFinalDropped = 'backup_final_dropped';
const String kWarnUnknownPreset = 'backup_unknown_preset';
const String kWarnVarSkipped = 'backup_var_skipped';
const String kWarnUnknownField = 'backup_unknown_field';

/// §393 B1 — тег приехавшего Направления уже занят на этой стороне.
///
/// Приехавшее НЕ применяется: под этим именем у пользователя уже своё
/// Направление со своими настройками, и перезапись стёрла бы их
/// (BACKUP.md §3). Правило при этом цель находит — тег совпадает, — поэтому
/// тег всё равно пополняет known-множество.
const String kWarnDirectionExists = 'backup_direction_exists';

/// Переносимые имена переменных — зеркало `registry/vars.json` (portable=true).
///
/// Сверяется с реестром тестом: разъехавшийся список означает, что бэкап либо
/// теряет настройку, либо тащит на чужую машину значение, которое там значит
/// другое (пути, интерфейсы, платформенные флаги).
const Set<String> kLxPortableVars = {
  'auto_detect_interface',
  'dns_default_domain_resolver',
  'dns_final',
  'dns_strategy',
  'ipv6_enabled',
  'log_level',
  'resolve_strategy',
  'tls_fragment',
  'tls_fragment_fallback_delay',
  'tls_mixed_case_sni',
  'tls_record_fragment',
  // SPEC 109 (N7): tun_address стал однострочником на обеих сторонах и
  // переносим наравне с tun_address6 — адрес TUN не привязан к машине.
  'tun_address',
  'tun_address6',
  'tun_mtu',
  'tun_stack',
  'urltest_interval',
  'urltest_tolerance',
  'urltest_url',
};

/// Зарезервированные цели: существуют всегда, объявлять не нужно.
const Set<String> _reservedOutbounds = {
  'direct',
  'block',
  'reject',
  'drop',
  'dns-out',
};

/// Предупреждение импорта: код + что затронуто.
class LxBackupWarning {
  const LxBackupWarning(this.code, this.detail);

  final String code;
  final String detail;

  @override
  String toString() => '$code: $detail';
}

/// Результат разбора файла.
class LxBackupFile {
  const LxBackupFile({
    required this.version,
    required this.exportedByApp,
    required this.exportedByVersion,
    required this.exportedAt,
    required this.directions,
    required this.rules,
    required this.subscriptions,
    required this.vars,
    required this.routeFinal,
    required this.foreignExtensions,
    required this.warnings,
  });

  final int version;
  final String exportedByApp;
  final String exportedByVersion;
  final String exportedAt;

  /// §393 B1 — Направления, ПРИМЕНИМЫЕ на этой стороне: приехавшие в файле
  /// теги, которых у нас ещё нет. Занятый тег сюда не попадает (он остался
  /// у пользователя своим) — только в warning `backup_direction_exists`.
  ///
  /// Порядок файла нормативен: `include[]` разрешает ссылаться только на
  /// Направления ВЫШЕ по списку, и перестановка ломала бы состав.
  final List<Direction> directions;

  /// Правила в порядке файла (ось `num` учтена при разборе).
  final List<CustomRule> rules;

  /// Подписки: url → метаданные, применяются поверх существующих списков.
  final List<Map<String, dynamic>> subscriptions;

  final Map<String, String> vars;
  final String? routeFinal;

  /// Блобы чужих приложений — хранить нетронутыми до следующего экспорта.
  final Map<String, dynamic> foreignExtensions;

  final List<LxBackupWarning> warnings;
}

/// Собирает LX Backup из настроек LxBox.
///
/// [directions] — Направления в порядке списка (§393 B2): они цели правил, и
/// без них правило приезжало бы на чужую машину выключенным.
///
/// [foreignExtensions] — сохранённые блобы других приложений; возвращаются
/// в файл как есть.
Future<String> buildLxBackup({
  required List<ServerList> lists,
  required List<CustomRule> rules,
  required Map<String, String> vars,
  List<Direction> directions = const [],
  String? routeFinal,
  Map<String, dynamic> foreignExtensions = const {},
}) async {
  var appVersion = '';
  try {
    final info = await PackageInfo.fromPlatform();
    appVersion = '${info.version}+${info.buildNumber}';
  } catch (_) {
    // В тестовом окружении PackageInfo недоступен — версия не критична.
  }

  final subscriptions = <Map<String, dynamic>>[];
  final servers = <Map<String, dynamic>>[];
  for (final list in lists) {
    // ServerList — sealed: url и период обновления есть только у подписки,
    // папки и одиночные серверы устроены иначе.
    if (list is SubscriptionServers) {
      subscriptions.add(_subscriptionToJson(list));
    } else {
      servers.add(_serverListToJson(list));
    }
  }

  final portableVars = <String, String>{
    for (final e in vars.entries)
      if (kLxPortableVars.contains(e.key)) e.key: e.value,
  };

  final out = <String, dynamic>{
    'lx_backup': kLxBackupVersion,
    'exported_by': {
      'app': kLxAppLxBox,
      'version': appVersion,
      'platform': 'android',
    },
    'exported_at': DateTime.now().toUtc().toIso8601String(),
    if (subscriptions.isNotEmpty) 'subscriptions': subscriptions,
    if (servers.isNotEmpty) 'servers': servers,
    // §393 B2 — цели едут ПЕРЕД правилами и в порядке списка: `include[]`
    // ссылается только вверх, перестановка сломала бы состав.
    if (directions.isNotEmpty)
      'directions': [for (final d in directions) _directionToJson(d)],
    // TODO(§393 B-хвост / C9): цепочек (SPEC 110, `chains[]`) в LX Backup
    // ПОКА НЕТ — ни здесь, ни в разборе. Это не забывчивость: раздела для
    // источников-цепочек в контракте (`docs/BACKUP.md`) не объявлено, и
    // лаунчер их в бэкап тоже не кладёт. Класть их в `extensions.lxbox`
    // нельзя — цепочка описана каноном ИСТОЧНИКА (`source_chain.schema.json`),
    // то есть общей моделью обеих сторон, а не мобильным расширением;
    // односторонний блоб сделал бы круг launcher→LxBox→launcher лживым.
    // Решается доп. разделом контракта (задача C9) — синхронно с лаунчером.
    // Внутренний бэкап цепочки уже переносит (`backup_service`, категория
    // routing), так что перенос устройство→устройство работает.
    if (rules.isNotEmpty) 'rules': [for (final r in rules) _ruleToJson(r)],
    if (portableVars.isNotEmpty) 'vars': portableVars,
    if (routeFinal != null && routeFinal.isNotEmpty)
      'route': {'final': routeFinal},
    if (foreignExtensions.isNotEmpty) 'extensions': foreignExtensions,
  };

  return const JsonEncoder.withIndent('  ').convert(out);
}

Map<String, dynamic> _subscriptionToJson(SubscriptionServers list) => {
      'url': list.url,
      'label': list.name,
      if (!list.enabled) 'enabled': false,
      if (list.tagPrefix.isNotEmpty) 'tag': {'prefix': list.tagPrefix},
      if (list.updateIntervalHours > 0)
        'update': {'interval_hours': list.updateIntervalHours},
      // Непереносимое (собственный id, тип списка) — в extensions: на
      // десктопе этих понятий нет, но вернуться они обязаны.
      'extensions': {
        kLxAppLxBox: {'id': list.id, 'type': list.type},
      },
    };

/// Папка или одиночный сервер: url у них нет, поэтому в схему они едут
/// секцией servers[]. Узлы не переносятся — они производные от подписки
/// либо принадлежат конкретной установке.
Map<String, dynamic> _serverListToJson(ServerList list) => {
      'label': list.name,
      if (!list.enabled) 'enabled': false,
      'extensions': {
        kLxAppLxBox: {'id': list.id, 'type': list.type},
      },
    };

/// Правило LxBox → запись схемы.
///
/// Матчеры, которых нет на десктопе (`packages`, `wifiSsids`, `wifiBssids`,
/// `inbounds`), уезжают в `extensions.lxbox`: применить их там нечем, а
/// терять при round-trip нельзя.
Map<String, dynamic> _ruleToJson(CustomRule rule) {
  final out = <String, dynamic>{
    'kind': rule.kind.name,
    'name': rule.name,
    if (!rule.enabled) 'enabled': false,
    if (rule.orderNum != null) 'num': rule.orderNum,
  };

  final raw = rule.toJson();

  if (rule is CustomRuleInline) {
    out['outbound'] = rule.outbound;
    final match = <String, dynamic>{
      if (rule.domains.isNotEmpty) 'domain': rule.domains,
      if (rule.domainSuffixes.isNotEmpty) 'domain_suffix': rule.domainSuffixes,
      if (rule.domainKeywords.isNotEmpty)
        'domain_keyword': rule.domainKeywords,
      if (rule.ipCidrs.isNotEmpty) 'ip_cidr': rule.ipCidrs,
      if (rule.ports.isNotEmpty) 'port': rule.ports,
      if (rule.portRanges.isNotEmpty) 'port_range': rule.portRanges,
      if (rule.protocols.isNotEmpty) 'protocol': rule.protocols,
      if (rule.network.isNotEmpty) 'network': rule.network,
    };
    if (match.isNotEmpty) out['match'] = match;

    final mobileOnly = <String, dynamic>{
      if (rule.packages.isNotEmpty) 'packages': rule.packages,
      if (rule.wifiSsids.isNotEmpty) 'wifiSsids': rule.wifiSsids,
      if (rule.wifiBssids.isNotEmpty) 'wifiBssids': rule.wifiBssids,
      if (rule.inbounds.isNotEmpty) 'inbounds': rule.inbounds,
      if (rule.ipIsPrivate) 'ipIsPrivate': true,
      if (rule.sourceIpCidrs.isNotEmpty) 'sourceIpCidrs': rule.sourceIpCidrs,
      if (rule.sourceIpIsPrivate) 'sourceIpIsPrivate': true,
    };
    if (mobileOnly.isNotEmpty) {
      out['extensions'] = {kLxAppLxBox: mobileOnly};
    }
  } else if (rule is CustomRuleSrs) {
    out['ref'] = (raw['url'] as String?) ?? (raw['srsUrl'] as String?) ?? '';
    out['outbound'] = (raw['outbound'] as String?) ?? '';
  } else if (rule is CustomRulePreset) {
    out['ref'] = (raw['presetId'] as String?) ?? (raw['ref'] as String?) ?? '';
    final vars = raw['vars'];
    if (vars is Map && vars.isNotEmpty) {
      out['vars'] = vars.map((k, v) => MapEntry('$k', '$v'));
    }
  } else if (rule is CustomRuleJson) {
    // Сырое правило: на десктопе применить нечем, но и терять нельзя.
    out['extensions'] = {
      kLxAppLxBox: {'json': rule.json},
    };
  }

  return out;
}

/// Разбирает LX Backup.
///
/// [knownOutbounds] — цели, на которые правилу разрешено ссылаться;
/// пустой набор означает «проверять нечем» — тогда ссылки не режутся.
LxBackupFile parseLxBackup(
  String raw, {
  Set<String> knownOutbounds = const {},
  Set<String> knownPresets = const {},
}) {
  final dynamic decoded = jsonDecode(raw);
  if (decoded is! Map<String, dynamic>) {
    throw const FormatException('Это не файл LX Backup');
  }
  final version = decoded['lx_backup'];
  if (version is! int) {
    throw const FormatException('Это не файл LX Backup: нет поля lx_backup');
  }
  if (version > kLxBackupVersion) {
    throw FormatException(
        'Формат бэкапа v$version новее поддерживаемого v$kLxBackupVersion — обновите приложение');
  }

  final warnings = <LxBackupWarning>[];

  // Default-deny: ключи вне схемы не применяются молча.
  const known = {
    'lx_backup', 'exported_by', 'exported_at', 'subscriptions', 'servers',
    'rules', 'dns', 'vars', 'route', 'warp', 'extensions',
    // §393 B1 — схема v1.1: Направления едут вместе с правилами.
    'directions',
  };
  for (final key in decoded.keys) {
    if (!known.contains(key)) {
      warnings.add(LxBackupWarning(kWarnUnknownField, key));
    }
  }

  final by = (decoded['exported_by'] as Map?)?.cast<String, dynamic>() ?? {};

  // §393 B1 — Направления разбираются ПЕРВЫМИ и пополняют known-множество:
  // правило, чья цель приехала в этом же файле, обязано прийти РАБОЧИМ, а не
  // выключенным с warning'ом о мёртвой ссылке (BACKUP.md §3).
  //
  // Занятый тег — не ошибка файла: у пользователя под этим именем своё
  // Направление со своими настройками. Приехавшее не применяется (warning),
  // но тег в known входит — правило цель находит, она просто чужая.
  final directions = <Direction>[];
  final knownWithDirections = knownOutbounds.toSet();
  final takenTags = <String>{
    for (final t in knownOutbounds) t.trim().toLowerCase(),
  };
  for (final item in (decoded['directions'] as List? ?? const [])) {
    if (item is! Map) continue;
    final j = item.cast<String, dynamic>();
    final tag = (j['tag'] as String?)?.trim() ?? '';
    if (tag.isEmpty) continue; // без тега Направление не адресуемо
    knownWithDirections.add(tag);
    if (!takenTags.add(tag.toLowerCase())) {
      warnings.add(LxBackupWarning(kWarnDirectionExists, tag));
      continue;
    }
    directions.add(_directionFromCanon(j, tag, warnings));
  }

  final rules = <CustomRule>[];
  for (final item in (decoded['rules'] as List? ?? const [])) {
    if (item is! Map) continue;
    final j = item.cast<String, dynamic>();
    final parsed =
        _ruleFromJson(j, knownWithDirections, knownPresets, warnings);
    if (parsed != null) rules.add(parsed);
  }
  // Ось порядка: относительный порядок сохраняется, номера — свои.
  rules.sort((a, b) => (a.orderNum ?? 0).compareTo(b.orderNum ?? 0));

  final vars = <String, String>{};
  final rawVars = (decoded['vars'] as Map?)?.cast<String, dynamic>() ?? {};
  for (final key in rawVars.keys.toList()..sort()) {
    if (!kLxPortableVars.contains(key)) {
      warnings.add(LxBackupWarning(kWarnVarSkipped, key));
      continue;
    }
    vars[key] = '${rawVars[key]}';
  }

  String? routeFinal;
  final route = (decoded['route'] as Map?)?.cast<String, dynamic>();
  final finalTag = route?['final'] as String?;
  if (finalTag != null && finalTag.isNotEmpty) {
    if (knownOutbounds.isEmpty ||
        _isKnownOutbound(finalTag, knownWithDirections)) {
      routeFinal = finalTag;
    } else {
      warnings.add(LxBackupWarning(kWarnFinalDropped, finalTag));
    }
  }

  final foreign = <String, dynamic>{};
  final ext = (decoded['extensions'] as Map?)?.cast<String, dynamic>() ?? {};
  for (final entry in ext.entries) {
    if (entry.key == kLxAppLxBox) continue; // своё применяется полями выше
    foreign[entry.key] = entry.value;
  }

  return LxBackupFile(
    version: version,
    exportedByApp: (by['app'] as String?) ?? '',
    exportedByVersion: (by['version'] as String?) ?? '',
    exportedAt: (decoded['exported_at'] as String?) ?? '',
    directions: directions,
    rules: rules,
    subscriptions: [
      for (final s in (decoded['subscriptions'] as List? ?? const []))
        if (s is Map) s.cast<String, dynamic>(),
    ],
    vars: vars,
    routeFinal: routeFinal,
    foreignExtensions: foreign,
    warnings: warnings,
  );
}

/// Ключи канонической формы Направления (`schema/direction.schema.json`).
/// Default-deny (§2): всё вне этого списка названо warning'ом, а не съедено.
const Set<String> _knownDirectionKeys = {
  'tag', 'label', 'enabled', 'filter', 'invert', 'default',
  'include_direct', 'include_block', 'include',
  'interrupt_exist_connections', 'auto',
};

const Set<String> _knownDirectionAutoKeys = {
  'mode', 'url', 'interval', 'tolerance', 'idle_timeout',
  'interrupt_exist_connections', 'pool', 'pool_tolerance', 'sticky_hash',
};

/// §393 B1 — каноническая форма → мобильное [Direction].
///
/// Переносится КАНОН, а не внутренняя структура: у сторон они разные. Отбор
/// узлов едет ТЕЛОМ регулярки — язык паттернов различается (`/re/i` у
/// лаунчера, [RegExp] у нас), а тело одинаково, и у мобилы [Direction.nodeFilter]
/// уже хранит тело. Эталон — `core/backup/directions.go:importDirection`.
Direction _directionFromCanon(
  Map<String, dynamic> j,
  String tag,
  List<LxBackupWarning> warnings,
) {
  for (final key in j.keys) {
    if (!_knownDirectionKeys.contains(key)) {
      warnings.add(LxBackupWarning(kWarnUnknownField, 'directions[].$key'));
    }
  }

  final rawAuto = j['auto'];
  return Direction(
    tag: tag,
    // Пустое имя — законно: канон говорит «показываем tag».
    label: (j['label'] as String?) ?? '',
    // Отсутствие ключа = true (`enabled.default` схемы), а не false.
    enabled: j['enabled'] as bool? ?? true,
    nodeFilter: (j['filter'] as String?) ?? '',
    nodeFilterInvert: j['invert'] as bool? ?? false,
    defaultFilter: (j['default'] as String?) ?? '',
    // Служебные опции у сторон зовутся по-своему (`direct-out`/`block-out` у
    // лаунчера, `direct`/`block` у нас) и потому едут признаками, а не тегами.
    includeDirect: j['include_direct'] as bool? ?? false,
    includeBlock: j['include_block'] as bool? ?? false,
    include: _strList(j['include']),
    // Отсутствие ключа означает «решает шаблон», а не false: у мобилы
    // шаблонное значение — true (см. `Direction.interruptExistConnections`).
    interruptExistConnections: j['interrupt_exist_connections'] as bool? ?? true,
    auto: rawAuto is Map
        ? _directionAutoFromCanon(rawAuto.cast<String, dynamic>(), warnings)
        : null,
  );
}

DirectionAuto _directionAutoFromCanon(
  Map<String, dynamic> j,
  List<LxBackupWarning> warnings,
) {
  for (final key in j.keys) {
    if (!_knownDirectionAutoKeys.contains(key)) {
      warnings.add(LxBackupWarning(kWarnUnknownField, 'directions[].auto.$key'));
    }
  }

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
        (j['tolerance'] as num?)?.toInt() ?? fallback.tolerance),
    idleTimeout: (j['idle_timeout'] as String?) ?? fallback.idleTimeout,
    interruptExistConnections: j['interrupt_exist_connections'] as bool? ??
        fallback.interruptExistConnections,
    pool: clampDirectionPool((j['pool'] as num?)?.toInt() ?? fallback.pool),
    poolTolerance: clampDirectionTolerance(
        (j['pool_tolerance'] as num?)?.toInt() ?? fallback.poolTolerance),
    stickyHash: sticky,
  );
}

/// §393 B2 — мобильное [Direction] → каноническая форма.
///
/// Прямые значения, без ссылок: у мобилы ссылочно-served полей (шаблонных
/// `@urltest_tolerance` лаунчера) нет вовсе — экспортируется то, что лежит.
Map<String, dynamic> _directionToJson(Direction d) => {
      'tag': d.tag,
      if (d.label.isNotEmpty) 'label': d.label,
      // Ключ пишем только для выключенного: отсутствие = true по схеме, и
      // «enabled: true» у каждой записи раздувало бы файл без смысла.
      if (!d.enabled) 'enabled': false,
      if (d.nodeFilter.isNotEmpty) 'filter': d.nodeFilter,
      if (d.nodeFilterInvert) 'invert': true,
      if (d.defaultFilter.isNotEmpty) 'default': d.defaultFilter,
      if (d.includeDirect) 'include_direct': true,
      if (d.includeBlock) 'include_block': true,
      if (d.include.isNotEmpty) 'include': d.include,
      'interrupt_exist_connections': d.interruptExistConnections,
      if (d.auto != null) 'auto': _directionAutoToJson(d.auto!),
    };

Map<String, dynamic> _directionAutoToJson(DirectionAuto a) => {
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

bool _isKnownOutbound(String tag, Set<String> known) {
  final t = tag.trim().toLowerCase();
  return _reservedOutbounds.contains(t) ||
      known.map((e) => e.trim().toLowerCase()).contains(t);
}

/// Запись схемы → правило LxBox.
///
/// Ссылка в никуда не повод терять правило: оно приезжает ВЫКЛЮЧЕННЫМ.
/// Включённое правило с несуществующей целью роняет конфиг ядра целиком.
CustomRule? _ruleFromJson(
  Map<String, dynamic> j,
  Set<String> knownOutbounds,
  Set<String> knownPresets,
  List<LxBackupWarning> warnings,
) {
  final kindName = (j['kind'] as String?) ?? '';
  final name = (j['name'] as String?) ?? '';
  var enabled = (j['enabled'] as bool?) ?? true;
  final rawNum = j['num'];
  final orderNum = rawNum is num ? rawNum.toInt() : null;
  final outbound = (j['outbound'] as String?) ?? '';

  if (outbound.isNotEmpty &&
      knownOutbounds.isNotEmpty &&
      !_isKnownOutbound(outbound, knownOutbounds)) {
    enabled = false;
    warnings.add(LxBackupWarning(
        kWarnUnknownOutbound, '${name.isEmpty ? kindName : name} → $outbound'));
  }

  final ext = ((j['extensions'] as Map?)?[kLxAppLxBox] as Map?)
          ?.cast<String, dynamic>() ??
      const {};

  switch (kindName) {
    case 'inline':
      final match =
          (j['match'] as Map?)?.cast<String, dynamic>() ?? const {};
      return CustomRuleInline(
        name: name,
        enabled: enabled,
        orderNum: orderNum,
        domains: _strList(match['domain']),
        domainSuffixes: _strList(match['domain_suffix']),
        domainKeywords: _strList(match['domain_keyword']),
        ipCidrs: _strList(match['ip_cidr']),
        ports: _strList(match['port']),
        portRanges: _strList(match['port_range']),
        protocols: _strList(match['protocol']),
        network: _strList(match['network']),
        // Mobile-only матчеры возвращаются из extensions — иначе round-trink
        // через десктоп терял бы их безвозвратно.
        packages: _strList(ext['packages']),
        wifiSsids: _strList(ext['wifiSsids']),
        wifiBssids: _strList(ext['wifiBssids']),
        inbounds: _strList(ext['inbounds']),
        ipIsPrivate: ext['ipIsPrivate'] == true,
        sourceIpCidrs: _strList(ext['sourceIpCidrs']),
        sourceIpIsPrivate: ext['sourceIpIsPrivate'] == true,
        outbound: outbound.isEmpty ? kDirectOutboundTag : outbound,
      );

    case 'preset':
      final ref = (j['ref'] as String?) ?? '';
      if (knownPresets.isNotEmpty && !knownPresets.contains(ref)) {
        enabled = false;
        warnings.add(LxBackupWarning(kWarnUnknownPreset, ref));
      }
      return CustomRulePreset.fromJson({
        'name': name,
        'enabled': enabled,
        'num': ?orderNum,
        'presetId': ref,
        'vars': (j['vars'] as Map?)?.cast<String, dynamic>() ?? const {},
      });

    case 'srs':
      return CustomRuleSrs.fromJson({
        'name': name,
        'enabled': enabled,
        'num': ?orderNum,
        'url': j['ref'] ?? '',
        'outbound': outbound,
      });

    case 'json':
      final body = ext['json'];
      if (body is String && body.isNotEmpty) {
        return CustomRuleJson.fromJson({
          'name': name,
          'enabled': enabled,
          'num': ?orderNum,
          'json': body,
        });
      }
      warnings.add(LxBackupWarning(kWarnUnknownField, 'rules[].kind=json: $name'));
      return null;

    default:
      warnings.add(LxBackupWarning(kWarnUnknownField, 'rules[].kind=$kindName'));
      return null;
  }
}

List<String> _strList(Object? v) {
  if (v is List) return [for (final e in v) '$e'];
  return const [];
}
