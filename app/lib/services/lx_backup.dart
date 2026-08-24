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

/// §393 B9 — DNS-запись приехала в виде, которому на этой стороне нет места
/// (`kind`, которого мобила не знает; тело без опоры на шаблон). Запись едет
/// в `extensions.lxbox` файла и в применение НЕ идёт — молчать о ней нельзя
/// (BACKUP.md §3).
const String kWarnDnsEntrySkipped = 'backup_dns_entry_skipped';

/// §393 B8 — запись `warp[]` не разобралась (нет дискриминатора `type`,
/// нет ключа регистрации). Аккаунт без приватного ключа не собирает узел,
/// поэтому применять нечего.
const String kWarnWarpSkipped = 'backup_warp_skipped';

/// §393 B11 — служебный ключ per-entity `extensions.lxbox`, куда складываются
/// поля записи, которых эта сторона не понимает (`skip`/`max_nodes` лаунчера
/// у подписки и т.п.).
///
/// Эталон — `core/backup/import.go:backupFieldsKey`. Имя общее с лаунчером
/// намеренно: круг launcher→LxBox→launcher должен вернуть поля на верхний
/// уровень записи, а не спрятать их навсегда в чужом блобе.
const String kLxBackupFieldsKey = '_backup_fields';

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

/// §393 B10 — подписка в переносимой форме.
///
/// Разбирается ПОЛЯМИ, а не сырым Map: до B10 импорт складывал запись целиком
/// и не применял ничего — «показали в диалоге и выбросили» (§3 BACKUP.md
/// нарушено ровно тем, что потеря была молчаливой).
class LxSubscription {
  const LxSubscription({
    required this.url,
    this.label = '',
    this.enabled = true,
    this.tagPrefix = '',
    this.tagPostfix = '',
    this.tagMask = '',
    this.updateIntervalHours,
    this.updateAuto,
    this.maxNodes,
    this.skip,
    this.disabled = const {},
    this.detour,
    this.ownExtensions = const {},
    this.foreignExtensions = const {},
    this.unknownFields = const {},
  });

  final String url;
  final String label;
  final bool enabled;
  final String tagPrefix;
  final String tagPostfix;
  final String tagMask;
  final int? updateIntervalHours;
  final bool? updateAuto;

  /// Лаунчерные поля: у мобилы понятия «потолок узлов» и «skip-фильтры» нет.
  /// Не применяются, но обязаны вернуться при re-export (B11).
  final int? maxNodes;
  final bool? skip;

  /// §4 BACKUP.md — identity-хеш (64 hex) → unix seconds последней встречи.
  final Map<String, int> disabled;

  /// Политика detour другой стороны: структура чужая, применять нечем.
  final Map<String, dynamic>? detour;

  /// `extensions.lxbox` записи — наше, применяется полями.
  final Map<String, dynamic> ownExtensions;

  /// `extensions.<чужое>` записи — хранить нетронутым до re-export.
  final Map<String, dynamic> foreignExtensions;

  /// Поля записи вне схемы + понятые-но-неприменимые: возвращаются на место
  /// при следующем экспорте (`_backup_fields`).
  final Map<String, dynamic> unknownFields;
}

/// §393 B10 — одиночный сервер: ровно одно из [uri] / [configJson].
class LxServer {
  const LxServer({
    this.uri = '',
    this.configJson,
    this.label = '',
    this.enabled = true,
    this.detour,
    this.ownExtensions = const {},
    this.foreignExtensions = const {},
    this.unknownFields = const {},
  });

  final String uri;
  final Map<String, dynamic>? configJson;
  final String label;
  final bool enabled;
  final Map<String, dynamic>? detour;
  final Map<String, dynamic> ownExtensions;
  final Map<String, dynamic> foreignExtensions;
  final Map<String, dynamic> unknownFields;
}

/// §393 B9 — запись DNS с kind-дискриминатором происхождения
/// (`template|preset|user` — канон схемы).
///
/// Мобильные имена другие (`inline` вместо `user`, плюс `srs` у правил, места
/// которому в схеме v1 нет), поэтому маппинг явный, а непоместившееся едет в
/// `extensions.lxbox` — см. [LxDns.foreignEntries].
class LxDnsRef {
  const LxDnsRef({
    required this.kind,
    this.name = '',
    this.ref = '',
    this.enabled = true,
    this.value,
    this.ownExtensions = const {},
  });

  final String kind;
  final String name;
  final String ref;
  final bool enabled;

  /// Тело записи. Переносится ТОЛЬКО у `kind=user`: у template/preset тело
  /// принадлежит шаблону принимающей стороны, и зафиксировать чужое значило бы
  /// навсегда отрезать пользователя от обновлений шаблона
  /// (`export.go:dnsRefFrom`).
  final Map<String, dynamic>? value;

  final Map<String, dynamic> ownExtensions;
}

/// §393 B9 — секция `dns` файла.
class LxDns {
  const LxDns({
    this.servers = const [],
    this.rules = const [],
    this.finalServer = '',
    this.strategy = '',
    this.foreignServerEntries = const [],
    this.foreignRuleEntries = const [],
  });

  final List<LxDnsRef> servers;
  final List<LxDnsRef> rules;

  /// `dns.final` — тег DNS-сервера по умолчанию (мобильная var `dns_final`).
  final String finalServer;

  /// `dns.strategy` — мобильная var `dns_strategy`.
  final String strategy;

  /// Записи, которым на мобиле нет места (см. [kWarnDnsEntrySkipped]) —
  /// хранятся сырыми и возвращаются в файл при re-export.
  final List<Map<String, dynamic>> foreignServerEntries;
  final List<Map<String, dynamic>> foreignRuleEntries;

  bool get isEmpty =>
      servers.isEmpty &&
      rules.isEmpty &&
      finalServer.isEmpty &&
      strategy.isEmpty &&
      foreignServerEntries.isEmpty &&
      foreignRuleEntries.isEmpty;
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
    this.servers = const [],
    this.dns,
    this.warp = const [],
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

  /// §393 B10 — подписки, разобранные полями. Применяются поверх существующих
  /// списков по URL (он и есть identity подписки на обеих сторонах).
  final List<LxSubscription> subscriptions;

  /// §393 B10 — одиночные серверы (`uri` / `config_json`).
  final List<LxServer> servers;

  /// §393 B9 — секция DNS; `null` = в файле её не было.
  final LxDns? dns;

  /// §393 B8 — записи `warp[]` в канонической форме схемы (дискриминатор
  /// `type: wg|masque`). Разбор в нативные модели — на стороне применения:
  /// парсер не должен знать про storage.
  final List<Map<String, dynamic>> warp;

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
/// в файл как есть (§393 B7). Ключ `lxbox` отсюда игнорируется: своё
/// приложение применяет данные полями, и вернуть их вторым экземпляром
/// значило бы поспорить с самим собой.
///
/// [dns] — секция DNS в переносимой форме (§393 B9); [warp] — записи
/// регистраций WG/MASQUE (§393 B8) уже в каноне схемы.
Future<String> buildLxBackup({
  required List<ServerList> lists,
  required List<CustomRule> rules,
  required Map<String, String> vars,
  List<Direction> directions = const [],
  String? routeFinal,
  Map<String, dynamic> foreignExtensions = const {},
  LxDns? dns,
  List<Map<String, dynamic>> warp = const [],
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

  // §393 B7 — свой ключ из чужих блобов не возвращаем: `extensions.lxbox`
  // верхнего уровня — это НАШЕ поле, и оно наполняется своими данными, а не
  // копией того, что когда-то приехало.
  final foreign = <String, dynamic>{
    for (final e in foreignExtensions.entries)
      if (e.key != kLxAppLxBox) e.key: e.value,
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
    // §393 B9 — DNS едет секцией, а не варами: `dns_final`/`dns_strategy` без
    // состава серверов на чужой стороне указывают в пустоту.
    if (dns != null && !dns.isEmpty) 'dns': _dnsToJson(dns),
    if (portableVars.isNotEmpty) 'vars': portableVars,
    if (routeFinal != null && routeFinal.isNotEmpty)
      'route': {'final': routeFinal},
    // §393 B8 — регистрации WARP: без них «Add WARP» на новой машине заводит
    // лишнюю device-запись в Cloudflare вместо переноса существующей.
    if (warp.isNotEmpty) 'warp': warp,
    if (foreign.isNotEmpty) 'extensions': foreign,
  };

  return const JsonEncoder.withIndent('  ').convert(out);
}

/// §393 B10 — подписка → запись схемы.
///
/// Возвращаются на место и поля, которых мобила не понимает: они лежат в
/// `extensions.lxbox._backup_fields` с прошлого импорта, и молча съесть их
/// значило бы обеднить круг launcher→LxBox→launcher (§1 BACKUP.md).
Map<String, dynamic> _subscriptionToJson(SubscriptionServers list) {
  final own = <String, dynamic>{
    'id': list.id,
    'type': list.type,
    // Mobile-only поля подписки (BACKUP.md §2): на десктопе понятий нет.
    if (list.importRules.isNotEmpty)
      'import_rules': [for (final r in list.importRules) r.toJson()],
    if (!list.importRulesEnabled) 'import_rules_enabled': false,
    if (list.identity != null) 'identity_override': list.identity!.toJson(),
    if (list.onUpdateAction != SubscriptionOnUpdateAction.rebuild)
      'on_update_action': list.onUpdateAction.name,
    // Detour-политика у сторон разная по составу: своя форма — в свой блоб,
    // а общий ключ `detour` схемы остаётся за чужой стороной.
    if (list.detourPolicy != DetourPolicy.defaults)
      'detour_policy': list.detourPolicy.toJson(),
  };

  final restored = _restoreBackupFields(own);

  final tag = <String, dynamic>{
    if (list.tagPrefix.isNotEmpty) 'prefix': list.tagPrefix,
    ...?(restored['tag'] as Map?)?.cast<String, dynamic>(),
  };

  final update = <String, dynamic>{
    if (list.updateIntervalHours > 0)
      'interval_hours': list.updateIntervalHours,
    ...?(restored['update'] as Map?)?.cast<String, dynamic>(),
  };

  return <String, dynamic>{
    'url': list.url,
    'label': list.name,
    if (!list.enabled) 'enabled': false,
    if (tag.isNotEmpty) 'tag': tag,
    if (update.isNotEmpty) 'update': update,
    // §4 BACKUP.md — отметки выключенных узлов только по identity-хешу;
    // значения — unix seconds (мобила хранит DateTime).
    if (list.disabledHashes.isNotEmpty)
      'disabled': {
        for (final e in list.disabledHashes.entries)
          e.key: e.value.toUtc().millisecondsSinceEpoch ~/ 1000,
      },
    // Поля, которых мобила не понимает, — обратно на верхний уровень записи.
    for (final e in restored.entries)
      if (e.key != 'tag' && e.key != 'update') e.key: e.value,
    'extensions': {kLxAppLxBox: own},
  };
}

/// Папка или одиночный сервер: url у них нет, поэтому в схему они едут
/// секцией servers[].
///
/// §393 B10 — оболочка перестала быть пустой: `uri`/`config_json` схемы
/// заполняются телом одиночного сервера. У папки одного тела нет (она
/// контейнер), поэтому её состав едет в `extensions.lxbox` — иначе N членов
/// пришлось бы разложить в N записей `servers[]` и потерять саму папку.
Map<String, dynamic> _serverListToJson(ServerList list) {
  final own = <String, dynamic>{
    'id': list.id,
    'type': list.type,
    if (list.tagPrefix.isNotEmpty) 'tag_prefix': list.tagPrefix,
    if (list.detourPolicy != DetourPolicy.defaults)
      'detour_policy': list.detourPolicy.toJson(),
  };

  var uri = '';
  Map<String, dynamic>? configJson;
  if (list is UserServer) {
    // §393 B10 — тело одиночного сервера. `raw_body` может быть и одной
    // URI-строкой, и JSON-outbound'ом: схема требует ровно одно из
    // `uri`/`config_json`, поэтому разбираем какое именно.
    final body = list.rawBody.trim();
    final asJson = _tryDecodeObject(body);
    if (asJson != null) {
      configJson = asJson;
    } else if (body.isNotEmpty) {
      uri = body;
    }
    own['origin'] = list.origin.name;
    own['created_at'] = list.createdAt.toIso8601String();
  } else if (list is FolderServers) {
    // Папка — контейнер, а не узел: тело в схему не ложится, состав едет
    // мобильным расширением целиком (§2 BACKUP.md «папки LxBox»).
    own['members'] = [for (final m in list.members) m.toJson()];
    own['created_at'] = list.createdAt.toIso8601String();
    if (list.pingUrl != null) own['ping_url'] = list.pingUrl;
    if (list.pingTimeoutMs != null) own['ping_timeout_ms'] = list.pingTimeoutMs;
  }

  final restored = _restoreBackupFields(own);

  return <String, dynamic>{
    if (uri.isNotEmpty) 'uri': uri,
    'config_json': ?configJson,
    'label': list.name,
    if (!list.enabled) 'enabled': false,
    ...restored,
    'extensions': {kLxAppLxBox: own},
  };
}

/// §393 B11 — вынимает `_backup_fields` из своего блоба и отдаёт их для
/// раскладки обратно на верхний уровень записи. Мутирует [own]: служебный
/// ключ в файл не едет (он контейнер хранения, а не поле схемы).
Map<String, dynamic> _restoreBackupFields(Map<String, dynamic> own) {
  final raw = own.remove(kLxBackupFieldsKey);
  if (raw is! Map) return const {};
  return raw.cast<String, dynamic>();
}

/// Строка → JSON-объект, если это он. Массив/скаляр/мусор → null: схема ждёт
/// в `config_json` именно объект-outbound.
Map<String, dynamic>? _tryDecodeObject(String body) {
  if (!body.startsWith('{')) return null;
  try {
    final decoded = jsonDecode(body);
    return decoded is Map ? decoded.cast<String, dynamic>() : null;
  } catch (_) {
    return null;
  }
}

/// §393 B9 — секция DNS → JSON.
Map<String, dynamic> _dnsToJson(LxDns dns) => {
  if (dns.servers.isNotEmpty || dns.foreignServerEntries.isNotEmpty)
    'servers': [
      for (final s in dns.servers) _dnsRefToJson(s),
      ...dns.foreignServerEntries,
    ],
  if (dns.rules.isNotEmpty || dns.foreignRuleEntries.isNotEmpty)
    'rules': [
      for (final r in dns.rules) _dnsRefToJson(r),
      ...dns.foreignRuleEntries,
    ],
  if (dns.finalServer.isNotEmpty) 'final': dns.finalServer,
  if (dns.strategy.isNotEmpty) 'strategy': dns.strategy,
};

Map<String, dynamic> _dnsRefToJson(LxDnsRef ref) => {
  'kind': ref.kind,
  if (ref.name.isNotEmpty) 'name': ref.name,
  if (ref.ref.isNotEmpty) 'ref': ref.ref,
  if (!ref.enabled) 'enabled': false,
  // Тело — только у пользовательских записей: у template/preset оно
  // принадлежит шаблону принимающей стороны (`export.go:dnsRefFrom`).
  if (ref.kind == 'user' && ref.value != null) 'value': ref.value,
  if (ref.ownExtensions.isNotEmpty)
    'extensions': {kLxAppLxBox: ref.ownExtensions},
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

  // Мобильное расширение записи: mobile-only матчеры, тело json-правила и
  // (внутри) транзитный груз чужих полей.
  final own = <String, dynamic>{};

  final raw = rule.toJson();
  // §393 B11 — чужие поля хранятся на правиле; ключ `_backup_fields` в файл
  // не едет, из него раскладываются поля верхнего уровня записи.
  raw.remove(CustomRule.backupFieldsKey);
  if (rule.backupFields.isNotEmpty) {
    own[kLxBackupFieldsKey] = rule.backupFields;
  }

  if (rule is CustomRuleInline) {
    out['outbound'] = rule.outbound;
    final match = <String, dynamic>{
      if (rule.domains.isNotEmpty) 'domain': rule.domains,
      if (rule.domainSuffixes.isNotEmpty) 'domain_suffix': rule.domainSuffixes,
      if (rule.domainKeywords.isNotEmpty) 'domain_keyword': rule.domainKeywords,
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
    own.addAll(mobileOnly);
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
    own['json'] = rule.json;
  }

  // §393 B11 — dns/resolve правила: ключи в схеме есть
  // (`additionalProperties: true`), тело — мобильной формы. Лаунчер их не
  // понимает и провозит через `_backup_fields` нетронутыми, поэтому круг
  // LxBox→launcher→LxBox возвращает опции на место.
  final dns = raw['dns'];
  if (dns is Map && dns.isNotEmpty) out['dns'] = dns.cast<String, dynamic>();
  final resolve = raw['resolve'];
  if (resolve is Map && resolve.isNotEmpty) {
    out['resolve'] = resolve.cast<String, dynamic>();
  }

  // §393 B11 — поля записи, которых мобила не понимает, вернулись из
  // `_backup_fields` на свой верхний уровень.
  out.addAll(_restoreBackupFields(own));

  if (own.isNotEmpty) out['extensions'] = {kLxAppLxBox: own};

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
      'Формат бэкапа v$version новее поддерживаемого v$kLxBackupVersion — обновите приложение',
    );
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
    final parsed = _ruleFromJson(
      j,
      knownWithDirections,
      knownPresets,
      warnings,
    );
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

  // §393 B8 — записи warp[]: разбираются позже, при применении (парсер не
  // знает про storage). Здесь только отсев мусора и дискриминатор.
  final warp = <Map<String, dynamic>>[];
  for (final item in (decoded['warp'] as List? ?? const [])) {
    if (item is! Map) continue;
    final j = item.cast<String, dynamic>();
    final type = (j['type'] as String?) ?? '';
    if (type != 'wg' && type != 'masque') {
      warnings.add(
        LxBackupWarning(
          kWarnWarpSkipped,
          type.isEmpty ? 'warp[]: нет type' : 'warp[]: $type',
        ),
      );
      continue;
    }
    warp.add(j);
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
        if (s is Map) _subscriptionFromJson(s.cast<String, dynamic>()),
    ],
    servers: [
      for (final s in (decoded['servers'] as List? ?? const []))
        if (s is Map) _serverFromJson(s.cast<String, dynamic>()),
    ],
    dns: _dnsFromJson(
      (decoded['dns'] as Map?)?.cast<String, dynamic>(),
      warnings,
    ),
    warp: warp,
    vars: vars,
    routeFinal: routeFinal,
    foreignExtensions: foreign,
    warnings: warnings,
  );
}

/// Ключи записи `subscriptions[]`, которые мобила разбирает полями. Всё
/// остальное едет в `_backup_fields` (§393 B11), а не выбрасывается.
const Set<String> _knownSubscriptionKeys = {
  'url',
  'label',
  'enabled',
  'skip',
  'max_nodes',
  'tag',
  'update',
  'disabled',
  'detour',
  'extensions',
};

const Set<String> _knownServerKeys = {
  'uri',
  'config_json',
  'label',
  'enabled',
  'detour',
  'extensions',
};

/// §393 B10 — запись `subscriptions[]` → типизированная модель.
LxSubscription _subscriptionFromJson(Map<String, dynamic> j) {
  final (own: own, foreign: foreign) = _splitEntityExtensions(j['extensions']);
  final tag = (j['tag'] as Map?)?.cast<String, dynamic>() ?? const {};
  final update = (j['update'] as Map?)?.cast<String, dynamic>() ?? const {};

  final unknown = <String, dynamic>{
    for (final e in j.entries)
      if (!_knownSubscriptionKeys.contains(e.key)) e.key: e.value,
  };
  // `skip`/`max_nodes` мобила понимает как ключи, но применить их нечем —
  // они возвращаются на место при re-export вместе с непонятыми.
  if (j.containsKey('skip')) unknown['skip'] = j['skip'];
  if (j.containsKey('max_nodes')) unknown['max_nodes'] = j['max_nodes'];
  if (j.containsKey('detour')) unknown['detour'] = j['detour'];
  // Части tag/update, которых у мобилы нет: `prefix`/`interval_hours` она
  // применяет, `postfix`/`mask`/`auto` — нет.
  final tagRest = <String, dynamic>{
    for (final e in tag.entries)
      if (e.key != 'prefix') e.key: e.value,
  };
  if (tagRest.isNotEmpty) unknown['tag'] = tagRest;
  final updateRest = <String, dynamic>{
    for (final e in update.entries)
      if (e.key != 'interval_hours') e.key: e.value,
  };
  if (updateRest.isNotEmpty) unknown['update'] = updateRest;

  return LxSubscription(
    url: (j['url'] as String?) ?? '',
    label: (j['label'] as String?) ?? '',
    enabled: j['enabled'] as bool? ?? true,
    tagPrefix: (tag['prefix'] as String?) ?? '',
    tagPostfix: (tag['postfix'] as String?) ?? '',
    tagMask: (tag['mask'] as String?) ?? '',
    updateIntervalHours: (update['interval_hours'] as num?)?.toInt(),
    updateAuto: update['auto'] as bool?,
    maxNodes: (j['max_nodes'] as num?)?.toInt(),
    skip: j['skip'] as bool?,
    disabled: _disabledFromJson(j['disabled']),
    detour: (j['detour'] as Map?)?.cast<String, dynamic>(),
    ownExtensions: own,
    foreignExtensions: foreign,
    unknownFields: unknown,
  );
}

/// §4 BACKUP.md — `disabled`: 64-hex → unix seconds. Значения не тех форм
/// пропускаются: отметка без времени бесполезна для TTL-очистки.
Map<String, int> _disabledFromJson(Object? raw) {
  if (raw is! Map) return const {};
  final out = <String, int>{};
  raw.forEach((k, v) {
    final key = '$k';
    if (key.length != 64) return;
    final ts = v is num ? v.toInt() : null;
    if (ts == null) return;
    out[key] = ts;
  });
  return out;
}

/// §393 B10 — запись `servers[]` → типизированная модель.
LxServer _serverFromJson(Map<String, dynamic> j) {
  final (own: own, foreign: foreign) = _splitEntityExtensions(j['extensions']);
  final unknown = <String, dynamic>{
    for (final e in j.entries)
      if (!_knownServerKeys.contains(e.key)) e.key: e.value,
  };
  if (j.containsKey('detour')) unknown['detour'] = j['detour'];

  return LxServer(
    uri: (j['uri'] as String?) ?? '',
    configJson: (j['config_json'] as Map?)?.cast<String, dynamic>(),
    label: (j['label'] as String?) ?? '',
    enabled: j['enabled'] as bool? ?? true,
    detour: (j['detour'] as Map?)?.cast<String, dynamic>(),
    ownExtensions: own,
    foreignExtensions: foreign,
    unknownFields: unknown,
  );
}

/// Per-entity `extensions`: своё применяется полями, чужое хранится нетронутым
/// (§1 BACKUP.md; эталон — `import.go:keepForeignEntityExtensions`).
({Map<String, dynamic> own, Map<String, dynamic> foreign})
_splitEntityExtensions(Object? raw) {
  if (raw is! Map) return (own: const {}, foreign: const {});
  final own = <String, dynamic>{};
  final foreign = <String, dynamic>{};
  raw.forEach((k, v) {
    if ('$k' == kLxAppLxBox) {
      if (v is Map) own.addAll(v.cast<String, dynamic>());
    } else {
      foreign['$k'] = v;
    }
  });
  return (own: own, foreign: foreign);
}

/// §393 B9 — секция `dns` файла → модель.
///
/// Канон знает три происхождения (`template|preset|user`), мобила — четыре
/// имени (`template|preset|inline` у серверов, плюс `srs` у правил).
/// `user` ↔ `inline` — одно и то же понятие под разными именами; `srs`
/// в схему v1 не ложится и едет сырой записью, а не молча пропадает.
LxDns? _dnsFromJson(Map<String, dynamic>? j, List<LxBackupWarning> warnings) {
  if (j == null) return null;
  const knownKeys = {'servers', 'rules', 'final', 'strategy'};
  for (final key in j.keys) {
    if (!knownKeys.contains(key)) {
      warnings.add(LxBackupWarning(kWarnUnknownField, 'dns.$key'));
    }
  }

  final servers = <LxDnsRef>[];
  final foreignServers = <Map<String, dynamic>>[];
  for (final item in (j['servers'] as List? ?? const [])) {
    if (item is! Map) continue;
    final e = item.cast<String, dynamic>();
    final ref = _dnsRefFromJson(e);
    if (ref == null) {
      foreignServers.add(e);
      if (!_isOwnDnsEntry(e)) {
        warnings.add(
          LxBackupWarning(
            kWarnDnsEntrySkipped,
            'dns.servers: kind=${e['kind']}',
          ),
        );
      }
      continue;
    }
    servers.add(ref);
  }

  final rules = <LxDnsRef>[];
  final foreignRules = <Map<String, dynamic>>[];
  for (final item in (j['rules'] as List? ?? const [])) {
    if (item is! Map) continue;
    final e = item.cast<String, dynamic>();
    final ref = _dnsRefFromJson(e);
    if (ref == null) {
      foreignRules.add(e);
      if (!_isOwnDnsEntry(e)) {
        warnings.add(
          LxBackupWarning(kWarnDnsEntrySkipped, 'dns.rules: kind=${e['kind']}'),
        );
      }
      continue;
    }
    rules.add(ref);
  }

  return LxDns(
    servers: servers,
    rules: rules,
    finalServer: (j['final'] as String?) ?? '',
    strategy: (j['strategy'] as String?) ?? '',
    foreignServerEntries: foreignServers,
    foreignRuleEntries: foreignRules,
  );
}

/// Запись с kind вне канона, но с НАШИМ расширением — это наша же запись,
/// вернувшаяся с чужой стороны (мобильные `srs`-правила DNS ездят так).
/// Предупреждать о ней нечего: применение её восстановит, а warning
/// «не применилось» был бы прямой ложью.
bool _isOwnDnsEntry(Map<String, dynamic> j) {
  final ext = j['extensions'];
  return ext is Map && ext[kLxAppLxBox] is Map;
}

/// Запись `dns.servers[]` / `dns.rules[]` → [LxDnsRef]; `null` = kind вне
/// канона (v1 знает ровно три).
LxDnsRef? _dnsRefFromJson(Map<String, dynamic> j) {
  final kind = (j['kind'] as String?) ?? '';
  if (kind != 'template' && kind != 'preset' && kind != 'user') return null;
  final (own: own, foreign: _) = _splitEntityExtensions(j['extensions']);
  return LxDnsRef(
    kind: kind,
    name: (j['name'] as String?) ?? '',
    ref: (j['ref'] as String?) ?? '',
    enabled: j['enabled'] as bool? ?? true,
    value: (j['value'] as Map?)?.cast<String, dynamic>(),
    ownExtensions: own,
  );
}

/// Ключи канонической формы Направления (`schema/direction.schema.json`).
/// Default-deny (§2): всё вне этого списка названо warning'ом, а не съедено.
const Set<String> _knownDirectionKeys = {
  'tag',
  'label',
  'enabled',
  'filter',
  'invert',
  'default',
  'include_direct',
  'include_block',
  'include',
  'interrupt_exist_connections',
  'auto',
};

const Set<String> _knownDirectionAutoKeys = {
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
    interruptExistConnections:
        j['interrupt_exist_connections'] as bool? ?? true,
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
      warnings.add(
        LxBackupWarning(kWarnUnknownField, 'directions[].auto.$key'),
      );
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
    warnings.add(
      LxBackupWarning(
        kWarnUnknownOutbound,
        '${name.isEmpty ? kindName : name} → $outbound',
      ),
    );
  }

  final ext =
      ((j['extensions'] as Map?)?[kLxAppLxBox] as Map?)
          ?.cast<String, dynamic>() ??
      const {};

  // §393 B11 — груз, который эта сторона не применяет, но обязана вернуть
  // при re-export: поля записи вне схемы + прошлый `_backup_fields`
  // (чужая сторона положила туда то, чего не понимала она).
  final carried = <String, dynamic>{
    for (final e in j.entries)
      if (!_knownRuleKeys.contains(e.key)) e.key: e.value,
  };
  final prior = ext[kLxBackupFieldsKey];
  if (prior is Map) carried.addAll(prior.cast<String, dynamic>());

  final rule = _ruleBodyFromJson(
    j,
    kindName,
    name,
    enabled,
    orderNum,
    outbound,
    ext,
    knownPresets,
    warnings,
  );
  if (rule == null) return null;
  if (carried.isNotEmpty) rule.backupFields = carried;
  return rule;
}

/// Ключи записи `rules[]`, которые мобила разбирает полями. Всё остальное —
/// транзитный груз (§393 B11).
const Set<String> _knownRuleKeys = {
  'kind',
  'name',
  'enabled',
  'num',
  'outbound',
  'ref',
  'vars',
  'match',
  'dns',
  'resolve',
  'extensions',
};

/// Тело разбора правила по виду. Вынесено из [_ruleFromJson], чтобы груз
/// чужих полей навешивался в ОДНОЙ точке на все виды: раньше `return` из
/// каждой ветки switch расходился бы с ним по мере роста видов.
CustomRule? _ruleBodyFromJson(
  Map<String, dynamic> j,
  String kindName,
  String name,
  bool enabled,
  int? orderNum,
  String outbound,
  Map<String, dynamic> ext,
  Set<String> knownPresets,
  List<LxBackupWarning> warnings,
) {
  switch (kindName) {
    case 'inline':
      final match = (j['match'] as Map?)?.cast<String, dynamic>() ?? const {};
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
        // §393 B11 — dns/resolve правила: ключи схемы, тело мобильной формы
        // (чужая сторона провозит его нетронутым через `_backup_fields`).
        dns: RuleDns.fromJson(j['dns']),
        resolve: RuleResolve.fromJson(j['resolve']),
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
        // Ключ модели — `varsValues`; `vars` схемы сюда переименовывается.
        // Совпадения имён нет, и до §393 B11 значения переменных пресета
        // молча оседали в никуда (фабрика читает только `varsValues`).
        'varsValues': (j['vars'] as Map?)?.cast<String, dynamic>() ?? const {},
      });

    case 'srs':
      return CustomRuleSrs.fromJson({
        'name': name,
        'enabled': enabled,
        'num': ?orderNum,
        // Тот же случай, что и с `varsValues` выше: фабрика читает `srsUrl`,
        // а не `url`, и URL правила терялся целиком.
        'srsUrl': j['ref'] ?? '',
        'outbound': outbound,
        'dns': ?j['dns'],
        'resolve': ?j['resolve'],
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
      warnings.add(
        LxBackupWarning(kWarnUnknownField, 'rules[].kind=json: $name'),
      );
      return null;

    default:
      warnings.add(
        LxBackupWarning(kWarnUnknownField, 'rules[].kind=$kindName'),
      );
      return null;
  }
}

List<String> _strList(Object? v) {
  if (v is List) return [for (final e in v) '$e'];
  return const [];
}
