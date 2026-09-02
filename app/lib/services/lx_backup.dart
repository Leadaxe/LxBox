/// LX Backup v1 — переносимый формат обмена настройками с десктопным
/// лаунчером (SPEC 103, фаза 4). Подробности — в docstring ниже.
library;

import 'dart:convert';

import 'package:package_info_plus/package_info_plus.dart';

import '../models/custom_rule.dart';
import '../config/consts.dart';
import '../models/direction.dart';
import '../models/server_list.dart';
import '../models/source_chain.dart';
import 'parser/uri_utils.dart' show newUuidV4;

/// LX Backup v1 — переносимый формат обмена настройками с десктопным
/// лаунчером (SPEC 103; контракт 0.11.0, §401).
///
/// Схема — `contract/schema/backup.schema.json`, семантика —
/// `contract/docs/BACKUP.md`, принципы — `contract/docs/BACKUP_PRINCIPLES.md`
/// (П1–П7, нормативны). Это НЕ замена [BackupService]: тот делает полный
/// снимок настроек для той же самой установки, а этот переносит общую часть
/// между приложениями.
///
/// **Файл — сериализация состояния** (П1). Ничего сверх состояния в нём нет:
/// ни блобов «на провоз», ни теневых карманов. Следствия, которыми меряется
/// реализация:
///
///  1. экспорт — чистая функция состояния: два неотличимых состояния дают
///     неотличимые файлы;
///  2. состояние после импорта неотличимо от настроенного руками;
///  3. `import(export(x))` в том же приложении = `x`.
///
/// Механизм `extensions` УПРАЗДНЁН целиком (П3). Провоз непонятого создавал
/// ровно то, что запрещает П1: состояние-призрак, которое протухает, когда
/// каноническую часть правят в другом приложении. Непонятое теперь
/// отбрасывается и предъявляется пользователю warning'ом.
///
/// Legacy-путей чтения нет (П4): схема одна — текущая. Старый файл 0.10.x
/// разбирается тем же общим правилом.
///
/// Нет молчаливых потерь (П6): всё неприменённое названо кодом warning'а —
/// и на импорте, и на экспорте.

/// Мажорная версия формата.
const int kLxBackupVersion = 1;

/// Значения `exported_by.app`. §401 — только они: ключами карманов
/// `extensions.<приложение>` эти имена больше не служат, механизм упразднён.
const String kLxAppLxBox = 'lxbox';
const String kLxAppLauncher = 'launcher';

/// Коды предупреждений (общие с Go-стороной, реестр —
/// `contract/registry/backup_warnings.json`).
const String kWarnUnknownOutbound = 'backup_unknown_outbound';
const String kWarnFinalDropped = 'backup_final_dropped';
const String kWarnUnknownPreset = 'backup_unknown_preset';
const String kWarnVarSkipped = 'backup_var_skipped';

/// Ключ вне схемы: в состояние не попадает (П3). Detail называет ПОЛНЫЙ путь
/// (`subscriptions[https://…].outbounds[vpn-1].key`), иначе предупреждение не
/// с чем сопоставить. Эталон — `core/backup/file.go:scanUnknown`.
const String kWarnUnknownField = 'backup_unknown_field';

/// §401 — файл несёт упразднённый механизм `extensions` (схема 0.10.x).
///
/// ОДИН warning на файл с перечнем затронутых записей, а не по ключу на
/// каждую находку: пока `extensions` существовал, он был не «лишним ключом»,
/// а карманом с произвольным содержимым, и перечислять его внутренности по
/// одной значило бы утопить пользователя в списке вместо объяснения.
const String kWarnExtensionsDropped = 'backup_extensions_dropped';

/// §401 — ключ модели пришёл ЧУЖОГО ТИПА: поле отбрасывается, разбор файла
/// продолжается.
///
/// Отдельный код, а не [kWarnUnknownField]: ключ-то знакомый, разошёлся его
/// тип (`subscriptions[].skip` — boolean у LxBox 0.10.x, список фильтров
/// отсева у лаунчера), и пользователю важно различать «такого поля тут нет»
/// и «поле есть, но значение записано по-другому». Уронить файл целиком
/// из-за одного поля значило бы потерять всё прочее молча, вопреки П6.
const String kWarnFieldTypeMismatch = 'backup_field_type_mismatch';

/// §401 — `exclude_from_global` / `expose_group_tags_to_global` приехали из
/// старого файла: класс флагов упразднён (SPEC 118 лаунчера), узлы источника
/// остаются в общем пуле кандидатов.
///
/// Поля ОБЪЯВЛЕНЫ в таблице контракта, поэтому общий обход неизвестных
/// ключей их не ловит — без этого кода они пропадали бы совсем молча.
const String kWarnSourceFlagDropped = 'backup_source_flag_dropped';

/// §401 (D-082) — `label` одиночного узла (сервер/цепочка) разошёлся с тегом
/// и применён не будет: у канона имени, кроме тега, нет (SPEC 112 контракта,
/// «идентичность узла = тег»).
///
/// У сервера БЕЗ `node_tag` подпись ещё может стать именем записи — тогда
/// потери нет и предупреждения тоже.
const String kWarnLabelDropped = 'backup_label_dropped';

/// §401 (D-083) — ключи объекта `subscriptions[].identity`, которые эта
/// сторона применить не умеет (`hash_device_model` и любое незнакомое).
///
/// Detail — `<label подписки>: key1, key2`. Общий обход неизвестных ключей
/// внутрь `identity` НЕ спускается: иначе одна потеря давала бы два
/// предупреждения — своё и [kWarnUnknownField].
const String kWarnSourceIdentityDropped = 'backup_source_identity_dropped';

/// §401 — настройка есть только у ЭТОЙ стороны, дома в общей схеме ей нет:
/// в файл она не едет.
///
/// Ставится на ЭКСПОРТЕ — там, где ещё видно, какие именно поля были заданы.
/// Detail — `<имя сущности>: field1, field2`, ОДИН warning на сущность:
/// перечислять каждое поле отдельной строкой значило бы утопить пользователя
/// в списке. Код общий для обеих сторон и обоих направлений.
const String kWarnLocalOnlyDropped = 'backup_local_only_dropped';

/// §393 B1 — тег приехавшего Направления уже занят на этой стороне.
///
/// Приехавшее НЕ применяется: под этим именем у пользователя уже своё
/// Направление со своими настройками, и перезапись стёрла бы их
/// (BACKUP.md §3). Правило при этом цель находит — тег совпадает, — поэтому
/// тег всё равно пополняет known-множество.
const String kWarnDirectionExists = 'backup_direction_exists';

/// §393 C9 — тег приехавшей цепочки уже занят на этой стороне (SPEC 110,
/// схема v1.2).
///
/// Тот же принцип, что у [kWarnDirectionExists], и та же причина предъявлять
/// его ВСЕГДА: у цепочки нет стабильного id, идентичность несёт только тег.
/// Молчаливое «своя победила» скрыло бы случай СЛУЧАЙНЫХ ТЁЗОК — двух
/// несвязанных маршрутов, одинаково названных на разных устройствах
/// (BACKUP.md §2). Приехавшая запись не применяется, своя остаётся; тег при
/// этом пополняет known-множество — правило, метящее в цепочку, цель
/// находит, она просто чужая.
const String kWarnChainExists = 'backup_chain_exists';

/// §393 B9 — DNS-запись приехала в виде, которому на этой стороне нет места
/// (`kind`, которого мобила не знает; тело без опоры на шаблон).
///
/// §401 — запись НЕ хранится сырой до следующего экспорта: карман провоза
/// упразднён (П3). Она отбрасывается, и молчать об этом нельзя.
const String kWarnDnsEntrySkipped = 'backup_dns_entry_skipped';

/// §393 B8 — запись `warp[]` не разобралась (нет дискриминатора `type`,
/// нет ключа регистрации). Аккаунт без приватного ключа не собирает узел,
/// поэтому применять нечего.
const String kWarnWarpSkipped = 'backup_warp_skipped';

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
///
/// §401 — карманов провоза (`ownExtensions`/`foreignExtensions`/
/// `unknownFields`) больше нет: непонятое отброшено и названо warning'ом
/// (П3), а не спрятано в состоянии до следующего экспорта (П1).
class LxSubscription {
  const LxSubscription({
    required this.url,
    this.label = '',
    this.enabled = true,
    this.tagPrefix = '',
    this.updateIntervalHours,
    this.disabled = const {},
    this.identity,
  });

  final String url;
  final String label;
  final bool enabled;
  final String tagPrefix;
  final int? updateIntervalHours;

  /// §5 BACKUP.md — идентичность узла (тег в рамках источника, SPEC 112) →
  /// unix seconds последней встречи. Ключ для формата обмена НЕПРОЗРАЧЕН и
  /// копируется как есть: legacy-форма 64 hex переживает перенос и мигрирует
  /// на приёмнике первым разбором источника (§400).
  final Map<String, int> disabled;

  /// §401 (D-083) — per-source identity: чем подписка представляется
  /// провайдеру. `null` = в файле объекта не было.
  final SubscriptionIdentityOverride? identity;
}

/// §393 B10 — одиночный сервер: ровно одно из [uri] / [configJson].
class LxServer {
  const LxServer({
    this.uri = '',
    this.configJson,
    this.name = '',
    this.enabled = true,
    this.folder = '',
  });

  final String uri;
  final Map<String, dynamic>? configJson;

  /// Имя записи: `node_tag` схемы, а не подпись. У канона имени, кроме тега,
  /// нет (SPEC 112), и `label` старого файла становится им только когда
  /// `node_tag` отсутствует (§401, D-082).
  final String name;

  final bool enabled;

  /// §401 (D-08x) — имя папки, в которую входит эта запись. Пусто = запись
  /// сама себе источник. Схема контейнеров не знает: члены папки едут
  /// ОТДЕЛЬНЫМИ записями `servers[]`, а собирает их обратно импорт по
  /// совпадению этого имени.
  final String folder;
}

/// §393 B9 — запись DNS с kind-дискриминатором происхождения
/// (`template|preset|user` — канон схемы).
///
/// Мобильные имена другие (`inline` вместо `user`, плюс `srs` у правил, места
/// которому в схеме v1 нет), поэтому маппинг явный, а непоместившееся
/// отбрасывается с [kWarnDnsEntrySkipped] (§401: карман провоза упразднён).
class LxDnsRef {
  const LxDnsRef({
    required this.kind,
    this.name = '',
    this.ref = '',
    this.enabled = true,
    this.value,
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
}

/// §393 B9 — секция `dns` файла.
class LxDns {
  const LxDns({
    this.servers = const [],
    this.rules = const [],
    this.finalServer = '',
    this.strategy = '',
  });

  final List<LxDnsRef> servers;
  final List<LxDnsRef> rules;

  /// `dns.final` — тег DNS-сервера по умолчанию (мобильная var `dns_final`).
  final String finalServer;

  /// `dns.strategy` — мобильная var `dns_strategy`.
  final String strategy;

  bool get isEmpty =>
      servers.isEmpty &&
      rules.isEmpty &&
      finalServer.isEmpty &&
      strategy.isEmpty;
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
    this.chains = const [],
    required this.subscriptions,
    required this.vars,
    required this.routeFinal,
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

  /// §393 C9 — цепочки хопов, ПРИМЕНИМЫЕ на этой стороне (SPEC 110, схема
  /// v1.2): приехавшие теги, которых у нас ещё нет. Занятый тег сюда не
  /// попадает — только в warning [kWarnChainExists].
  ///
  /// ПОРЯДОК ФАЙЛА НОРМАТИВЕН и не сортируется: вложенная цепочка вправе
  /// стоять позицией только у объявленной НИЖЕ по списку, и перестановка
  /// замкнула бы цикл, которого канон запрещает
  /// (`schema/source_chain.schema.json`).
  final List<SourceChain> chains;

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

  final List<LxBackupWarning> warnings;
}

/// Результат экспорта: сам файл + что в него НЕ поехало.
///
/// §401 — предупреждения на экспорте не выдумка, а требование П6: настройка,
/// у которой в общей схеме нет дома, теряется при переносе, и промолчать о
/// ней значило бы отдать пользователю файл, тихо беднее его состояния.
class LxBackupExport {
  const LxBackupExport(this.json, this.warnings);

  final String json;
  final List<LxBackupWarning> warnings;
}

/// Собирает LX Backup из настроек LxBox.
///
/// [directions] — Направления в порядке списка (§393 B2): они цели правил, и
/// без них правило приезжало бы на чужую машину выключенным.
///
/// [dns] — секция DNS в переносимой форме (§393 B9); [warp] — записи
/// регистраций WG/MASQUE (§393 B8) уже в каноне схемы.
///
/// §401 — ключ `extensions` не пишется НИГДЕ: ни на корне, ни внутри записей
/// (П3). Экспорт — чистая функция состояния (П1), поэтому и чужих блобов на
/// входе больше нет: провозить нечего.
Future<LxBackupExport> buildLxBackup({
  required List<ServerList> lists,
  required List<CustomRule> rules,
  required Map<String, String> vars,
  List<Direction> directions = const [],
  List<SourceChain> chains = const [],
  String? routeFinal,
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

  final warnings = <LxBackupWarning>[];
  final subscriptions = <Map<String, dynamic>>[];
  final servers = <Map<String, dynamic>>[];
  for (final list in lists) {
    // ServerList — sealed: url и период обновления есть только у подписки,
    // папки и одиночные серверы устроены иначе.
    if (list is SubscriptionServers) {
      subscriptions.add(_subscriptionToJson(list, warnings));
    } else if (list is FolderServers) {
      // §401 (D-08x) — папка не сущность схемы, а контейнер: её члены едут
      // ОТДЕЛЬНЫМИ записями `servers[]`, связанные полем `folder`. Иначе
      // состав папки пришлось бы прятать в карман, которого больше нет.
      servers.addAll(_folderToJson(list, warnings));
    } else {
      servers.add(_serverListToJson(list, warnings));
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
    // §393 C9 — цепочки хопов (SPEC 110): корневая секция рядом с
    // directions[]. Цепочка описана каноном ИСТОЧНИКА
    // (`source_chain.schema.json`) — общей моделью обеих сторон.
    //
    // Едут ПОСЛЕ directions[] (позиция может ссылаться на Направление) и ДО
    // rules[] (правило может метить в цепочку как в цель). Порядок списка
    // сохраняется дословно: ссылка на цепочку разрешена только ВВЕРХ по
    // списку, и сортировка замкнула бы цикл.
    if (chains.isNotEmpty) 'chains': [for (final c in chains) _chainToJson(c)],
    if (rules.isNotEmpty)
      'rules': [for (final r in rules) _ruleToJson(r, warnings)],
    // §393 B9 — DNS едет секцией, а не варами: `dns_final`/`dns_strategy` без
    // состава серверов на чужой стороне указывают в пустоту.
    if (dns != null && !dns.isEmpty) 'dns': _dnsToJson(dns),
    if (portableVars.isNotEmpty) 'vars': portableVars,
    if (routeFinal != null && routeFinal.isNotEmpty)
      'route': {'final': routeFinal},
    // §393 B8 — регистрации WARP: без них «Add WARP» на новой машине заводит
    // лишнюю device-запись в Cloudflare вместо переноса существующей.
    if (warp.isNotEmpty) 'warp': warp,
  };

  return LxBackupExport(
    const JsonEncoder.withIndent('  ').convert(out),
    warnings,
  );
}

/// §401 — ОДИН warning на сущность с перечнем полей, у которых нет дома в
/// общей схеме. Пустой перечень предупреждения не даёт: шуметь на каждой
/// записи подряд значило бы обесценить сам сигнал.
void _noteLocalOnly(
  List<LxBackupWarning> warnings,
  String entity,
  List<String> fields,
) {
  if (fields.isEmpty) return;
  warnings.add(
    LxBackupWarning(kWarnLocalOnlyDropped, '$entity: ${fields.join(', ')}'),
  );
}

/// §393 B10 — подписка → запись схемы.
///
/// §401 — карманов больше нет: mobile-only настройки в файл не едут и названы
/// предупреждением (П3/П6), а `identity` переехал верхним уровнем записи
/// (D-083).
Map<String, dynamic> _subscriptionToJson(
  SubscriptionServers list,
  List<LxBackupWarning> warnings,
) {
  // Дома в схеме этим настройкам нет: контракт общий с лаунчером, а у него
  // таких понятий не существует. Односторонне заводить их ключами значило бы
  // вернуть ровно тот тайный груз, ради сноса которого убран `extensions`.
  _noteLocalOnly(warnings, list.name.isEmpty ? list.url : list.name, [
    if (list.importRules.isNotEmpty) 'import_rules',
    if (!list.importRulesEnabled) 'import_rules_enabled',
    if (list.onUpdateAction != SubscriptionOnUpdateAction.rebuild)
      'on_update_action',
    if (list.detourPolicy != DetourPolicy.defaults) 'detour_policy',
  ]);

  final tag = <String, dynamic>{
    if (list.tagPrefix.isNotEmpty) 'prefix': list.tagPrefix,
  };

  final update = <String, dynamic>{
    if (list.updateIntervalHours > 0)
      'interval_hours': list.updateIntervalHours,
  };

  final identity = _identityToJson(list.identity);

  return <String, dynamic>{
    'id': list.id,
    'url': list.url,
    // `label` подписки — имя ИСТОЧНИКА, а не узла: D-082 его не трогает.
    'label': list.name,
    if (!list.enabled) 'enabled': false,
    if (tag.isNotEmpty) 'tag': tag,
    if (update.isNotEmpty) 'update': update,
    // §5 BACKUP.md — отметки выключенных узлов по идентичности узла (тег в
    // рамках источника, SPEC 112); значения — unix seconds (мобила хранит
    // DateTime). Ключ непрозрачен и едет как есть: legacy-хеш 64 hex тоже.
    if (list.disabledHashes.isNotEmpty)
      'disabled': {
        for (final e in list.disabledHashes.entries)
          e.key: e.value.toUtc().millisecondsSinceEpoch ~/ 1000,
      },
    'identity': ?identity,
  };
}

/// §401 (D-083) — per-source identity → объект схемы 0.12.
///
/// Пишется, только когда override у подписки ЗАДАН, и только заданными
/// ключами: у этой настройки «не задано» и «задано пустым» значат разное, и
/// пустышка в каждом файле отличала бы два одинаковых состояния (П1).
///
/// `hash_device_model` схема объявляет, но у нас такой настройки нет — не
/// пишем: выдумывать значение честнее файл не делает.
Map<String, dynamic>? _identityToJson(SubscriptionIdentityOverride? id) {
  if (id == null) return null;
  final out = <String, dynamic>{
    if (id.userAgent.isNotEmpty) 'user_agent': id.userAgent,
    'send_hwid': id.sendHwid,
    if (id.hwid.isNotEmpty) 'hwid': id.hwid,
    if (id.deviceOs.isNotEmpty) 'device_os': id.deviceOs,
    if (id.verOs.isNotEmpty) 'ver_os': id.verOs,
    if (id.deviceModel.isNotEmpty) 'device_model': id.deviceModel,
  };
  return out;
}

/// §401 (D-08x) — папка → N записей `servers[]`, связанных полем `folder`.
///
/// Каждый член самодостаточен (§234: URI-строка, WG-INI, JSON-outbound), и
/// схема принимает его ровно так же, как одиночный сервер. Собирает папку
/// обратно импорт — по совпадению имени.
List<Map<String, dynamic>> _folderToJson(
  FolderServers list,
  List<LxBackupWarning> warnings,
) {
  // Настройки САМОЙ папки дома в схеме не имеют. Предупреждаем только о
  // заданных: у папки без своих ping-опций терять нечего.
  _noteLocalOnly(warnings, list.name, [
    if (list.pingUrl != null) 'ping_url',
    if (list.pingTimeoutMs != null) 'ping_timeout_ms',
    if (list.tagPrefix.isNotEmpty) 'tag_prefix',
    if (list.detourPolicy != DetourPolicy.defaults) 'detour_policy',
    // §237 — личный detour члена: у записи схемы такого поля нет.
    if (list.members.any((m) => m.detour.isNotEmpty)) 'member detour',
    // Нечитаемый член (§234: raw не распарсился) поедет записью без имени —
    // на приёмнике он не соберётся в узел, и молчать об этом нельзя.
    if (list.members.any((m) => m.raw.trim().isNotEmpty && m.node == null))
      'unparsed members',
  ]);

  final out = <Map<String, dynamic>>[];
  for (final m in list.members) {
    final body = m.raw.trim();
    if (body.isEmpty) continue;
    final asJson = _tryDecodeObject(body);
    // Тег члена — имя узла (SPEC 112 контракта): у нераспарсенного члена его
    // нет, и выдумывать имя мы не станем — запись поедет безымянной.
    final nodeTag = m.node?.tag ?? '';
    out.add(<String, dynamic>{
      if (asJson == null) 'uri': body,
      'config_json': ?asJson,
      if (nodeTag.isNotEmpty) 'node_tag': nodeTag,
      if (!m.enabled) 'enabled': false,
      'folder': list.name,
    });
  }
  return out;
}

/// Одиночный сервер: url у него нет, поэтому в схему он едет секцией
/// servers[].
///
/// §401 — `label` не пишется (D-082): у канона имя узла одно — тег, и подпись
/// рядом с ним была бы вторым именем, которое разъедется при первом же
/// переименовании. Имя записи едет `node_tag`.
Map<String, dynamic> _serverListToJson(
  ServerList list,
  List<LxBackupWarning> warnings,
) {
  _noteLocalOnly(warnings, list.name, [
    if (list.tagPrefix.isNotEmpty) 'tag_prefix',
    if (list.detourPolicy != DetourPolicy.defaults) 'detour_policy',
  ]);

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
  }

  return <String, dynamic>{
    'id': list.id,
    if (uri.isNotEmpty) 'uri': uri,
    'config_json': ?configJson,
    if (list.name.isNotEmpty) 'node_tag': list.name,
    if (!list.enabled) 'enabled': false,
  };
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
  if (dns.servers.isNotEmpty)
    'servers': [for (final s in dns.servers) _dnsRefToJson(s)],
  if (dns.rules.isNotEmpty)
    'rules': [for (final r in dns.rules) _dnsRefToJson(r)],
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
};

/// Правило LxBox → запись схемы.
///
/// §401 — матчеры, которых нет на десктопе (`packages`, `wifiSsids`,
/// `wifiBssids`, `inbounds`, приватные IP), и тело `kind=json` в файл НЕ едут:
/// дома в общей схеме им нет, и карман провоза упразднён (П3). Каждое
/// правило, у которого такие настройки заданы, даёт один
/// [kWarnLocalOnlyDropped] с их перечнем.
Map<String, dynamic> _ruleToJson(
  CustomRule rule,
  List<LxBackupWarning> warnings,
) {
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
      if (rule.domainKeywords.isNotEmpty) 'domain_keyword': rule.domainKeywords,
      if (rule.ipCidrs.isNotEmpty) 'ip_cidr': rule.ipCidrs,
      if (rule.ports.isNotEmpty) 'port': rule.ports,
      if (rule.portRanges.isNotEmpty) 'port_range': rule.portRanges,
      if (rule.protocols.isNotEmpty) 'protocol': rule.protocols,
      if (rule.network.isNotEmpty) 'network': rule.network,
    };
    if (match.isNotEmpty) out['match'] = match;

    _noteLocalOnly(warnings, rule.name, [
      if (rule.packages.isNotEmpty) 'packages',
      if (rule.wifiSsids.isNotEmpty) 'wifi_ssid',
      if (rule.wifiBssids.isNotEmpty) 'wifi_bssid',
      if (rule.inbounds.isNotEmpty) 'inbound',
      if (rule.ipIsPrivate) 'ip_is_private',
      if (rule.sourceIpCidrs.isNotEmpty) 'source_ip_cidr',
      if (rule.sourceIpIsPrivate) 'source_ip_is_private',
    ]);
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
    // Сырое правило: тело — мобильной формы, дома в схеме у него нет. Без
    // тела правило не восстановимо, поэтому потеря названа целиком.
    _noteLocalOnly(warnings, rule.name, const ['json']);
  }

  // `dns`/`resolve` — наши поля таблицы §2 BACKUP.md: лаунчер отбрасывает их
  // у себя с warning'ом, но в схеме они объявлены, и круг LxBox→LxBox
  // возвращает их на место.
  final dns = raw['dns'];
  if (dns is Map && dns.isNotEmpty) out['dns'] = dns.cast<String, dynamic>();
  final resolve = raw['resolve'];
  if (resolve is Map && resolve.isNotEmpty) {
    out['resolve'] = resolve.cast<String, dynamic>();
  }

  return out;
}

/// Разбирает LX Backup.
///
/// [knownOutbounds] — цели, на которые правилу разрешено ссылаться;
/// пустой набор означает «проверять нечем» — тогда ссылки не режутся.
///
/// [knownChains] — теги ЦЕПОЧЕК, уже заведённых на этой стороне (§393 C9).
/// Отдельно от [knownOutbounds] намеренно: merge цепочек идёт по СВОЕМУ
/// пространству имён — приехавшая цепочка `relay` при существующем
/// Направлении `relay` это не «своя цепочка сильнее», а коллизия тегов, и
/// разгребает её гейт применения ([directionTagConflict]), а не warning
/// `backup_chain_exists`, который отвечает на другой вопрос.
LxBackupFile parseLxBackup(
  String raw, {
  Set<String> knownOutbounds = const {},
  Set<String> knownPresets = const {},
  Set<String> knownChains = const {},
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

  // §401 — default-deny на ВСЮ глубину файла, а не только на корень:
  // вложенный уровень — самое удобное место спрятать чужое поле. Упразднённый
  // `extensions` при этом отделён от прочего незнакомого: он не «лишний
  // ключ», а карман с произвольным содержимым (эталон —
  // `core/backup/file.go:scanUnknown`).
  final warnings = _scanUnknown(decoded);

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
    directions.add(_directionFromCanon(j, tag));
  }

  // §393 C9 — цепочки (SPEC 110, схема v1.2): ПОСЛЕ Направлений (позиция
  // может ссылаться на Направление) и ДО правил (правило может метить в
  // цепочку как в цель). Порядок записей файла сохраняется как есть.
  //
  // Занятый тег — тот же код-путь, что и дубль ВНУТРИ файла: набор
  // `takenChainTags` общий, поэтому first-wins по порядку файла, а вторая
  // запись с тем же тегом получает `backup_chain_exists` наравне с тёзкой
  // локальной цепочки. Тег пополняет known-множество в ЛЮБОМ случае —
  // и у применённой, и у пропущенной: цель под этим именем существует.
  final chains = <SourceChain>[];
  final takenChainTags = <String>{
    for (final t in knownChains) t.trim().toLowerCase(),
  };
  for (final item in (decoded['chains'] as List? ?? const [])) {
    if (item is! Map) continue;
    final j = item.cast<String, dynamic>();
    final tag = (j['tag'] as String?)?.trim() ?? '';
    // Без тега цепочка не адресуема, без канона — не маршрут: битую запись
    // пропускаем молча, как безымянное Направление (защита от правленого
    // файла, а не потеря данных).
    if (tag.isEmpty || j['chain'] is! Map) continue;
    knownWithDirections.add(tag);
    if (!takenChainTags.add(tag.toLowerCase())) {
      warnings.add(LxBackupWarning(kWarnChainExists, tag));
      continue;
    }
    chains.add(_chainFromCanon(j, tag, warnings));
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
    chains: chains,
    subscriptions: [
      for (final s in (decoded['subscriptions'] as List? ?? const []))
        if (s is Map)
          _subscriptionFromJson(s.cast<String, dynamic>(), warnings),
    ],
    servers: [
      for (final s in (decoded['servers'] as List? ?? const []))
        if (s is Map) _serverFromJson(s.cast<String, dynamic>(), warnings),
    ],
    dns: _dnsFromJson(
      (decoded['dns'] as Map?)?.cast<String, dynamic>(),
      warnings,
    ),
    warp: warp,
    vars: vars,
    routeFinal: routeFinal,
    warnings: warnings,
  );
}

// ---------------------------------------------------------------------------
// §401 — обход неизвестных ключей (default-deny на всю глубину файла).
//
// Списки ключей ведутся ЗДЕСЬ, а не выводятся из моделей: это ровно таблица
// полей BACKUP.md §2, то есть контракт. Выводить их из формы наших классов
// значило бы объявить «схемой» текущий код, и любое внутреннее переименование
// молча меняло бы контракт.
// ---------------------------------------------------------------------------

/// Ключ упразднённого механизма провоза (BACKUP_PRINCIPLES.md П3).
const String _extensionsKey = 'extensions';

const Set<String> _rootKeys = {
  'lx_backup',
  'exported_by',
  'exported_at',
  'subscriptions',
  'servers',
  'directions',
  'chains',
  'rules',
  'dns',
  'vars',
  'route',
  'warp',
};

const Set<String> _exportedByKeys = {'app', 'version', 'platform'};
const Set<String> _routeKeys = {'final'};

/// Ссылка detour на узел — общая обвязка источников (BACKUP.md §6). У нас её
/// применить нечем, но ключи ОБЪЯВЛЕНЫ контрактом: ложный
/// `backup_unknown_field` на каждый файл лаунчера был бы шумом.
const Set<String> _sourceRefKeys = {
  'detour_tag',
  'detour_node_source_id',
  'detour_node_tag',
  'detour_node_label',
};

const Set<String> _subscriptionKeys = {
  ..._sourceRefKeys,
  'id',
  'url',
  'label',
  'enabled',
  'max_nodes',
  'tag',
  'update',
  'disabled',
  'skip',
  'outbounds',
  'fold',
  'identity',
  'exclude_from_global',
  'expose_group_tags_to_global',
};

const Set<String> _serverKeys = {
  ..._sourceRefKeys,
  'id',
  'uri',
  'config_json',
  'label',
  'node_tag',
  'enabled',
  'folder',
  'exclude_from_global',
};

const Set<String> _chainKeys = {
  ..._sourceRefKeys,
  'id',
  'tag',
  // Контракт 0.9.0 / D-082 — `label` цепочки СНЕСЁН: имя одно, тег. Ключ
  // остаётся известным, чтобы файл старой версии / лаунчера не поднимал
  // `backup_unknown_field`; разошедшаяся с тегом подпись отбрасывается с
  // [kWarnLabelDropped] (`chains_roundtrip` корпуса).
  'label',
  'enabled',
  'chain',
  'exclude_from_global',
};

const Set<String> _directionKeys = {
  'tag',
  // Контракт 0.9.0 — `label` СНЁСЕН: имя Направления одно, tag. Ключ остаётся
  // известным, чтобы файл старой версии / лаунчера не поднимал
  // `backup_unknown_field`: он законно был, его читают и молча отбрасывают
  // (warning'а, в отличие от servers[]/chains[] по D-082, здесь нет).
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

const Set<String> _directionAutoKeys = {
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

const Set<String> _ruleKeys = {
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
};

/// Канон цепочки (`source_chain.schema.json`). Внутрь хопов сканер не
/// спускается намеренно: хоп ссылается на узел выражениями, чей набор ключей
/// ведёт схема цепочки, а не таблица бэкапа.
const Set<String> _chainBodyKeys = {
  'hops',
  'idle_timeout',
  'rewrite',
  'strip',
  'strip_evasion',
};

/// Union обоих типов регистрации: запись объявляет свой `type`, и разбирать её
/// по типу значило бы завести две почти одинаковые таблицы ради ключей,
/// которых у чужого типа всё равно не бывает.
const Set<String> _warpKeys = {
  'type',
  'private_key',
  'peer_public',
  'client_v4',
  'client_v6',
  'client_id',
  'device_id',
  'token',
  'account_id',
  'license',
  'warp_plus',
  'created_at',
  'private_key_der',
  'server_pub_der',
  'server',
  'port',
  // §401, контракт 0.12.2 — плоские поля записи вместо упразднённого кармана
  // `extensions.lxbox`. `sni`/`idle_timeout` схема объявляет поимённо
  // (`extension: mobile`); `awg`/`endpoint`/`keep_alive` — «snake_case поля
  // самой регистрации» из открытой части секции (`additionalProperties`).
  'sni',
  'idle_timeout',
  'keep_alive',
  'awg',
  'endpoint',
};

const Set<String> _dnsKeys = {'servers', 'rules', 'final', 'strategy'};
const Set<String> _dnsRefKeys = {
  'kind',
  'tag',
  'name',
  'enabled',
  'num',
  'ref',
  'vars',
  'value',
};

/// Чем запись секции называется пользователю: код обязан показать «в подписке
/// https://…», а не «в записи №3», иначе предупреждение не с чем сопоставить.
const Map<String, String> _arrayLabelKeys = {
  'subscriptions': 'url',
  'servers': 'node_tag',
  'chains': 'tag',
  'directions': 'tag',
  'rules': 'name',
  'outbounds': 'tag',
  'warp': 'type',
};

/// §401 — обходит файл и перечисляет всё, чего нет в таблице контракта.
///
/// Два разных класса потерь — два разных сообщения (П6):
///
///  - `extensions` любой глубины: ОДИН warning на файл с перечнем затронутых
///    записей. Это не «лишний ключ», а упразднённый карман с произвольным
///    содержимым, и перечислять его внутренности по одной значило бы утопить
///    пользователя в списке вместо объяснения;
///  - всё прочее: warning с ПОЛНЫМ путём ключа.
///
/// Внутрь `identity` обход не спускается: неприменённые ключи объекта считает
/// сам разбор подписки и выдаёт один [kWarnSourceIdentityDropped] с перечнем.
/// Спустись сканер сюда — одна потеря давала бы два предупреждения.
List<LxBackupWarning> _scanUnknown(Map<String, dynamic> root) {
  final sc = _UnknownScan();

  sc.object('', root, _rootKeys);
  sc.nested(root, 'exported_by', _exportedByKeys);
  sc.nested(root, 'route', _routeKeys);

  final dns = (root['dns'] as Map?)?.cast<String, dynamic>();
  if (dns != null) {
    sc.object('dns', dns, _dnsKeys);
    sc.array(dns, 'dns.servers', 'servers', _dnsRefKeys, 'name', null);
    sc.array(dns, 'dns.rules', 'rules', _dnsRefKeys, 'name', null);
  }

  sc.array(root, 'subscriptions', 'subscriptions', _subscriptionKeys, null, (
    where,
    item,
  ) {
    // Локальные Направления источника — та же каноническая форма, что и
    // directions[] на корне: две таблицы для одной сущности разъехались бы.
    sc.array(
      item,
      '$where.outbounds',
      'outbounds',
      _directionKeys,
      null,
      sc.directionBody,
    );
  });
  sc.array(root, 'servers', 'servers', _serverKeys, null, null);
  sc.array(root, 'chains', 'chains', _chainKeys, null, (where, item) {
    sc.nestedAt(item, where, 'chain', _chainBodyKeys);
  });
  sc.array(
    root,
    'directions',
    'directions',
    _directionKeys,
    null,
    sc.directionBody,
  );
  sc.array(root, 'rules', 'rules', _ruleKeys, null, null);
  sc.array(root, 'warp', 'warp', _warpKeys, null, null);

  return sc.warnings();
}

/// Копит находки обхода: обычные неизвестные ключи по одному, упразднённый
/// `extensions` — списком затронутых записей.
class _UnknownScan {
  final _fields = <String>[];
  final _seenField = <String>{};
  final _extensionsAt = <String>[];
  final _seenExtension = <String>{};

  void _note(String where, String key) {
    if (key == _extensionsKey) {
      final place = where.isEmpty ? '<file root>' : where;
      if (_seenExtension.add(place)) _extensionsAt.add(place);
      return;
    }
    final name = where.isEmpty ? key : '$where.$key';
    if (_seenField.add(name)) _fields.add(name);
  }

  void object(String where, Map<String, dynamic> obj, Set<String> known) {
    for (final key in obj.keys) {
      if (!known.contains(key)) _note(where, key);
    }
  }

  void nested(Map<String, dynamic> parent, String key, Set<String> known) {
    final obj = (parent[key] as Map?)?.cast<String, dynamic>();
    if (obj == null) return;
    object(key, obj, known);
  }

  /// Вложенный объект ВНУТРИ записи: путь уже назван (`chains[relay]`), и имя
  /// ключа дописывается к нему, а не заменяет его.
  void nestedAt(
    Map<String, dynamic> parent,
    String where,
    String key,
    Set<String> known,
  ) {
    final obj = (parent[key] as Map?)?.cast<String, dynamic>();
    if (obj == null) return;
    object('$where.$key', obj, known);
  }

  /// Вложенные уровни одного Направления. Общий для корневых `directions[]` и
  /// локальных `subscriptions[].outbounds[]`: форма у них одна.
  void directionBody(String where, Map<String, dynamic> item) {
    nestedAt(item, where, 'auto', _directionAutoKeys);
  }

  /// Обходит секцию-список. [deeper], если задан, вызывается на каждой записи
  /// с её ПОЛНЫМ путём — им секция спускается на свои вложенные уровни.
  void array(
    Map<String, dynamic> parent,
    String where,
    String key,
    Set<String> known,
    String? labelKey,
    void Function(String, Map<String, dynamic>)? deeper,
  ) {
    final items = parent[key];
    if (items is! List) return;
    final label = labelKey ?? _arrayLabelKeys[key] ?? '';
    for (var i = 0; i < items.length; i++) {
      final item = items[i];
      if (item is! Map) continue;
      final j = item.cast<String, dynamic>();
      final entry = '$where[${_entryLabel(j, label, i)}]';
      object(entry, j, known);
      if (deeper != null) deeper(entry, j);
    }
  }

  static String _entryLabel(
    Map<String, dynamic> item,
    String labelKey,
    int index,
  ) {
    final v = item[labelKey];
    if (v is String && v.isNotEmpty) return v;
    return '#${index + 1}';
  }

  List<LxBackupWarning> warnings() {
    final out = <LxBackupWarning>[];
    if (_extensionsAt.isNotEmpty) {
      final places = _extensionsAt.toList()..sort();
      out.add(LxBackupWarning(kWarnExtensionsDropped, places.join(', ')));
    }
    for (final name in _fields.toList()..sort()) {
      out.add(LxBackupWarning(kWarnUnknownField, name));
    }
    return out;
  }
}

/// §393 B10 — запись `subscriptions[]` → типизированная модель.
///
/// §401 — незнакомое сюда не доезжает: его назвал общий обход
/// ([_scanUnknown]), и класть его в состояние «до следующего экспорта»
/// больше некуда (П1/П3).
LxSubscription _subscriptionFromJson(
  Map<String, dynamic> j,
  List<LxBackupWarning> warnings,
) {
  final label = (j['label'] as String?) ?? '';
  final where = label.isEmpty ? ((j['url'] as String?) ?? '') : label;

  // §401 — класс флагов упразднён (SPEC 118 лаунчера). Ключи ОБЪЯВЛЕНЫ в
  // таблице контракта, поэтому общий обход их не ловит: без отдельного кода
  // они пропадали бы совсем молча.
  for (final key in const [
    'exclude_from_global',
    'expose_group_tags_to_global',
  ]) {
    if (j.containsKey(key)) {
      warnings.add(LxBackupWarning(kWarnSourceFlagDropped, '$where.$key'));
    }
  }

  // §401 — `skip` у лаунчера список фильтров отсева, у нас его применять
  // нечем; наш собственный boolean 0.10.x тоже. Ключ знакомый, разошёлся
  // тип — отдельный код, а не «неизвестное поле».
  if (j['skip'] is List || j['skip'] is bool) {
    warnings.add(LxBackupWarning(kWarnFieldTypeMismatch, '$where.skip'));
  }
  // §401 — объектный `detour` нашего старого формата в схеме 0.11 не
  // объявлен вовсе: его место заняли `detour_tag` + `detour_node_*`. Значит
  // это обычный неизвестный ключ, и называет его общий обход [_scanUnknown],
  // а не отдельный код. Type-mismatch остаётся ровно за `skip` — единственной
  // коллизией ТИПА объявленного ключа между 0.10.x и 0.11.

  final tag = (j['tag'] as Map?)?.cast<String, dynamic>() ?? const {};
  final update = (j['update'] as Map?)?.cast<String, dynamic>() ?? const {};

  return LxSubscription(
    url: (j['url'] as String?) ?? '',
    label: label,
    enabled: j['enabled'] as bool? ?? true,
    tagPrefix: (tag['prefix'] as String?) ?? '',
    updateIntervalHours: (update['interval_hours'] as num?)?.toInt(),
    disabled: _disabledFromJson(j['disabled']),
    identity: _identityFromJson(j['identity'], where, warnings),
  );
}

/// §401 (D-083) — `subscriptions[].identity` → [SubscriptionIdentityOverride].
///
/// Применяются наши шесть ключей. Всё прочее (`hash_device_model` схемы и
/// любое незнакомое) отбрасывается ОДНИМ предупреждением на подписку с
/// перечнем: порядок — сначала ключи схемы, затем чужие по алфавиту, потому
/// что текст обязан быть воспроизводимым (два импорта одного файла дают один
/// и тот же перечень).
SubscriptionIdentityOverride? _identityFromJson(
  Object? raw,
  String where,
  List<LxBackupWarning> warnings,
) {
  if (raw is! Map) return null;
  final j = raw.cast<String, dynamic>();

  final unapplied = <String>[
    for (final k in _identityKeyOrder)
      if (j.containsKey(k) && !_identityAppliedKeys.contains(k)) k,
    ...(j.keys.where((k) => !_identityKeyOrder.contains(k)).toList()..sort()),
  ];
  if (unapplied.isNotEmpty) {
    warnings.add(
      LxBackupWarning(
        kWarnSourceIdentityDropped,
        '$where: ${unapplied.join(', ')}',
      ),
    );
  }

  return SubscriptionIdentityOverride(
    userAgent: (j['user_agent'] as String?) ?? '',
    sendHwid: (j['send_hwid'] as bool?) ?? false,
    hwid: (j['hwid'] as String?) ?? '',
    deviceOs: (j['device_os'] as String?) ?? '',
    verOs: (j['ver_os'] as String?) ?? '',
    deviceModel: (j['device_model'] as String?) ?? '',
  );
}

/// Ключи объекта `identity` в порядке схемы 0.12. Порядок фиксирован, а не
/// взят из обхода map: перечень в предупреждении обязан быть воспроизводимым.
const List<String> _identityKeyOrder = [
  'user_agent',
  'send_hwid',
  'hwid',
  'device_os',
  'ver_os',
  'device_model',
  'hash_device_model',
];

/// То, что LxBox умеет применить. Остальное (включая незнакомое) — в
/// [kWarnSourceIdentityDropped].
const Set<String> _identityAppliedKeys = {
  'user_agent',
  'send_hwid',
  'hwid',
  'device_os',
  'ver_os',
  'device_model',
};

/// §5 BACKUP.md — `disabled`: ключ отметки → unix seconds.
///
/// §400 — ключом идёт идентичность узла (тег в рамках источника), но
/// принимаются и legacy-ключи 64-hex из бэкапов, снятых до контракта 0.10.0:
/// они мигрируют по общему правилу (IDENTITY.md §5.1) при первом разборе
/// источника уже на приёмнике. Пустой ключ отбрасывается — идентичности
/// «пустая строка» не существует. Значение не-числом пропускается: отметка
/// без времени бесполезна для TTL-очистки.
Map<String, int> _disabledFromJson(Object? raw) {
  if (raw is! Map) return const {};
  final out = <String, int>{};
  raw.forEach((k, v) {
    final key = '$k';
    if (key.isEmpty) return;
    final ts = v is num ? v.toInt() : null;
    if (ts == null) return;
    out[key] = ts;
  });
  return out;
}

/// §393 B10 — запись `servers[]` → типизированная модель.
///
/// §401 (D-082) — имя записи берётся из `node_tag`: у канона имя узла одно —
/// тег. `label` — LEGACY-ВХОД: у записи БЕЗ `node_tag` подпись ещё может
/// стать именем (тогда потери нет и предупреждения тоже), иначе она
/// расходится с тегом и отбрасывается с [kWarnLabelDropped].
LxServer _serverFromJson(
  Map<String, dynamic> j,
  List<LxBackupWarning> warnings,
) {
  final nodeTag = (j['node_tag'] as String?)?.trim() ?? '';
  final label = (j['label'] as String?)?.trim() ?? '';
  var name = nodeTag;
  if (nodeTag.isEmpty) {
    name = label;
  } else if (label.isNotEmpty && label != nodeTag) {
    warnings.add(LxBackupWarning(kWarnLabelDropped, nodeTag));
  }

  if (j.containsKey('exclude_from_global')) {
    warnings.add(
      LxBackupWarning(
        kWarnSourceFlagDropped,
        '${name.isEmpty ? 'servers[]' : name}.exclude_from_global',
      ),
    );
  }
  // Объектный `detour` схемой 0.11 не объявлен — это обычный неизвестный
  // ключ, и его называет общий обход [_scanUnknown].

  return LxServer(
    uri: (j['uri'] as String?) ?? '',
    configJson: (j['config_json'] as Map?)?.cast<String, dynamic>(),
    name: name,
    enabled: j['enabled'] as bool? ?? true,
    // §401 (D-08x) — имя папки-контейнера; собирает её обратно применение.
    folder: (j['folder'] as String?)?.trim() ?? '',
  );
}

/// §393 B9 — секция `dns` файла → модель.
///
/// Канон знает три происхождения (`template|preset|user`), мобила — четыре
/// имени (`template|preset|inline` у серверов, плюс `srs` у правил).
/// `user` ↔ `inline` — одно и то же понятие под разными именами.
///
/// §401 — запись, которой в каноне места нет, ОТБРАСЫВАЕТСЯ с
/// [kWarnDnsEntrySkipped], а не хранится сырой до следующего экспорта: карман
/// провоза упразднён (П3), и держать её в состоянии значило бы завести
/// состояние-призрак, которого пользователь не видит.
LxDns? _dnsFromJson(Map<String, dynamic>? j, List<LxBackupWarning> warnings) {
  if (j == null) return null;

  final servers = <LxDnsRef>[];
  for (final item in (j['servers'] as List? ?? const [])) {
    if (item is! Map) continue;
    final e = item.cast<String, dynamic>();
    final ref = _dnsRefFromJson(e);
    if (ref == null) {
      warnings.add(
        LxBackupWarning(kWarnDnsEntrySkipped, 'dns.servers: kind=${e['kind']}'),
      );
      continue;
    }
    servers.add(ref);
  }

  final rules = <LxDnsRef>[];
  for (final item in (j['rules'] as List? ?? const [])) {
    if (item is! Map) continue;
    final e = item.cast<String, dynamic>();
    final ref = _dnsRefFromJson(e);
    if (ref == null) {
      warnings.add(
        LxBackupWarning(kWarnDnsEntrySkipped, 'dns.rules: kind=${e['kind']}'),
      );
      continue;
    }
    rules.add(ref);
  }

  return LxDns(
    servers: servers,
    rules: rules,
    finalServer: (j['final'] as String?) ?? '',
    strategy: (j['strategy'] as String?) ?? '',
  );
}

/// Запись `dns.servers[]` / `dns.rules[]` → [LxDnsRef]; `null` = kind вне
/// канона (он знает ровно три).
LxDnsRef? _dnsRefFromJson(Map<String, dynamic> j) {
  final kind = (j['kind'] as String?) ?? '';
  if (kind != 'template' && kind != 'preset' && kind != 'user') return null;
  return LxDnsRef(
    kind: kind,
    name: (j['name'] as String?) ?? '',
    ref: (j['ref'] as String?) ?? '',
    enabled: j['enabled'] as bool? ?? true,
    value: (j['value'] as Map?)?.cast<String, dynamic>(),
  );
}

/// §393 B1 — каноническая форма → мобильное [Direction].
///
/// Переносится КАНОН, а не внутренняя структура: у сторон они разные. Отбор
/// узлов едет ТЕЛОМ регулярки — язык паттернов различается (`/re/i` у
/// лаунчера, [RegExp] у нас), а тело одинаково, и у мобилы [Direction.nodeFilter]
/// уже хранит тело. Эталон — `core/backup/directions.go:importDirection`.
///
/// §401 — неизвестные ключи здесь больше не пересчитываются: их называет
/// общий обход [_scanUnknown] полным путём. `label` контракт 0.9.0 снёс — он
/// читается как незнакомый ключ и в модель не кладётся.
Direction _directionFromCanon(Map<String, dynamic> j, String tag) {
  final rawAuto = j['auto'];
  return Direction(
    tag: tag,
    // Имя Направления ровно одно — тег (контракт 0.9.0/§402): поля `label`
    // у модели больше нет, из файла ключ читается как известный и молча
    // отбрасывается (`_directionKeys`).
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
        ? _directionAutoFromCanon(rawAuto.cast<String, dynamic>())
        : null,
  );
}

DirectionAuto _directionAutoFromCanon(Map<String, dynamic> j) {
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
///
/// §401 — `label` не пишется: имя Направления ровно одно — тег (контракт
/// 0.9.0), и второе имя рядом с ним разъехалось бы при первом переименовании.
Map<String, dynamic> _directionToJson(Direction d) => {
  'tag': d.tag,
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

/// §393 C9 — мобильная [SourceChain] → запись секции `chains[]`.
///
/// Форма записи: `tag` + опциональный `enabled` + КАНОН цепочки отдельным
/// полем `chain`, без дублирования его полей на верхнем уровне
/// (`schema/backup.schema.json`, секция chains[]).
///
/// §401 (D-082) — `label` НЕ пишется: у цепочки имя одно — тег, и подпись
/// рядом с ним была бы вторым именем, которое разъедется при первом же
/// переименовании на любой из сторон.
Map<String, dynamic> _chainToJson(SourceChain c) => {
  'tag': c.tag,
  // Ключ пишем только для выключенной: отсутствие = true по схеме.
  if (!c.enabled) 'enabled': false,
  // Канон как есть — `SourceChain.toJson` уже пишет ровно его поля, минус
  // идентичность записи (tag/enabled), которая живёт уровнем выше.
  'chain': _chainCanonToJson(c),
};

/// Канон цепочки (`schema/source_chain.schema.json`) для поля `chain`.
///
/// Отдельно от [SourceChain.toJson] намеренно: тот пишет ЗАПИСЬ storage —
/// с `tag`/`enabled`, — а канон описывает только МАРШРУТ. Смешать их
/// значило бы отправить на ту сторону тег дважды и разойтись со схемой
/// (`additionalProperties: false`).
Map<String, dynamic> _chainCanonToJson(SourceChain c) {
  final full = c.toJson()
    ..remove('tag')
    ..remove('label')
    ..remove('enabled')
    // §393 D1 — `order` тоже идентичность записи, а не маршрут: это МЕСТО
    // цепочки в общем списке источников ЭТОГО устройства. Схема канона его не
    // знает (`additionalProperties: false`), и осмысленным на той стороне он
    // быть не может — там свой список источников. Взаимный порядок цепочек
    // при этом не теряется: он и есть порядок записей секции `chains[]`.
    ..remove('order');
  return full;
}

/// §393 C9 — каноническая запись `chains[]` → мобильная [SourceChain].
///
/// Достижимость `hops` здесь НЕ проверяется: хоп — чаще всего узел подписки,
/// которого до её обновления не существует, и рубеж валидации у обеих сторон
/// один — сборка конфига (`chain_hop_missing`). Эталон —
/// `core/backup/import.go:importChain`.
///
/// §401 (D-082) — `label` LEGACY-ВХОД: у цепочки имя одно — тег. Разошедшаяся
/// подпись отбрасывается с [kWarnLabelDropped]; совпавшая с тегом молчит,
/// потому что терять нечего.
SourceChain _chainFromCanon(
  Map<String, dynamic> j,
  String tag,
  List<LxBackupWarning> warnings,
) {
  final label = (j['label'] as String?)?.trim() ?? '';
  if (label.isNotEmpty && label != tag) {
    warnings.add(LxBackupWarning(kWarnLabelDropped, tag));
  }

  final canon =
      (j['chain'] as Map?)?.cast<String, dynamic>() ??
      const <String, dynamic>{};
  // Канон разбирается ШТАТНЫМ парсером модели: второй разбор тех же полей
  // разошёлся бы с ним на первой же правке (трёхзначный `strip_evasion`,
  // порядок каталога `strip`, `null` внутри `rewrite`).
  final parsed = SourceChain.fromJson({...canon, 'tag': tag});
  return parsed.copyWith(
    // Отсутствие ключа = true (`enabled.default` схемы). В ожиданиях корпуса
    // ключа нет вовсе, и читать его отсутствие как false значило бы
    // импортировать выключенными все цепочки лаунчера.
    enabled: j['enabled'] as bool? ?? true,
  );
}

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

  return _ruleBodyFromJson(
    j,
    kindName,
    name,
    enabled,
    orderNum,
    outbound,
    knownPresets,
    warnings,
  );
}

/// Тело разбора правила по виду. Вынесено из [_ruleFromJson], чтобы ветки
/// switch не расходились по мере роста видов.
CustomRule? _ruleBodyFromJson(
  Map<String, dynamic> j,
  String kindName,
  String name,
  bool enabled,
  int? orderNum,
  String outbound,
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
        // §401 — mobile-only матчеры (`packages`, `wifiSsids`, приватные IP)
        // из файла не приезжают: дома в общей схеме им нет, и провозить их
        // больше нечем. Правило собирается из того, что в схеме есть.
        outbound: outbound.isEmpty ? kDirectOutboundTag : outbound,
        // `dns`/`resolve` — наши поля таблицы §2 BACKUP.md: круг LxBox→LxBox
        // возвращает их на место, лаунчер отбрасывает у себя с warning'ом.
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
        // Совпадения имён нет, и без этого значения переменных пресета молча
        // оседали в никуда (фабрика читает только `varsValues`).
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
      // §401 — тело сырого правила в файл не едет (дома в схеме ему нет), и
      // без тела правило не восстановимо: пропускаем, а не заводим пустую
      // оболочку, которая на сборке уронит конфиг.
      //
      // Код — [kWarnUnknownField], как у любого `kind`, который принимающая
      // сторона обработать не может (корпус `unknown_rule_kind_skipped`):
      // [kWarnLocalOnlyDropped] отвечает на другой вопрос — «моя настройка не
      // поехала в файл», а здесь потеря случилась на ЧУЖОМ экспорте.
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

/// Результат слияния подписок файла с локальным состоянием
/// ([mergeBackupSubscriptions]).
typedef BackupSubscriptionMerge = ({
  /// Списки источников после слияния (порядок локальных сохранён, новые — в
  /// хвосте, в порядке файла).
  List<ServerList> lists,

  /// URL подписки → её индекс в [lists]. Нужен последующим секциям импорта.
  Map<String, int> byUrl,

  /// Сколько записей файла реально применилось.
  int applied,
});

/// §393 B6/B10 + §401 (П1) — слияние `subscriptions[]` файла с локальными
/// источниками. Чистая функция: состояние читает и пишет вызывающий.
///
/// Идентичность записи — URL: он и есть идентичность подписки на обеих
/// сторонах контракта.
///
/// **Совпавшая по URL запись ОБНОВЛЯЕТСЯ настройками из файла.** Бэкап — это
/// сериализация состояния (BACKUP_PRINCIPLES П1), и восстановленное состояние
/// обязано быть неотличимо от настроенного руками. Раньше совпавшая запись
/// получала только доливку disabled-отметок, поэтому восстановление СВОЕГО ЖЕ
/// файла на том же устройстве не возвращало ни `identity`, ни префикс тегов:
/// пользователь видел «импорт прошёл» и настроек на месте не находил.
///
/// Исключение ровно одно — **disabled-отметки ОБЪЕДИНЯЮТСЯ**, а не
/// замещаются (§4 BACKUP.md): отметка, которой в файле нет, могла быть
/// поставлена уже после экспорта, и молча включать такой узел нельзя.
///
/// Локальные подписки, которых в файле нет, НЕ удаляются: импорт — слияние,
/// а полная замена раздела была бы другим решением.
///
/// Новая подписка добавляется БЕЗ узлов: тело приедет обычным обновлением.
BackupSubscriptionMerge mergeBackupSubscriptions(
  List<ServerList> lists,
  List<LxSubscription> incoming,
) {
  final byUrl = <String, int>{
    for (var i = 0; i < lists.length; i++)
      if (lists[i] is SubscriptionServers)
        (lists[i] as SubscriptionServers).url: i,
  };
  final merged = lists.toList();
  var applied = 0;

  DateTime at(int unixSeconds) =>
      DateTime.fromMillisecondsSinceEpoch(unixSeconds * 1000, isUtc: true);

  for (final sub in incoming) {
    if (sub.url.isEmpty) continue;
    final idx = byUrl[sub.url];
    if (idx != null) {
      final existing = merged[idx] as SubscriptionServers;
      // Хеш, которого у нас нет, добавляется; свой не перетирается.
      final add = <String, DateTime>{
        for (final e in sub.disabled.entries)
          if (!existing.disabledHashes.containsKey(e.key)) e.key: at(e.value),
      };
      merged[idx] = existing.copyWith(
        disabledHashes: {...existing.disabledHashes, ...add},
        // Пустое имя в файле именем не является — своё не затираем.
        name: sub.label.isNotEmpty ? sub.label : null,
        tagPrefix: sub.tagPrefix,
        updateIntervalHours: sub.updateIntervalHours,
        enabled: sub.enabled,
        // `identity` — слепок целиком: объекта в файле НЕТ значит «настройка
        // сброшена в дефолт», а не «оставь как было». Иначе состояние без
        // override'а не переносилось бы вовсе.
        identity: sub.identity,
        clearIdentity: sub.identity == null,
      );
      applied++;
      continue;
    }

    merged.add(SubscriptionServers(
      id: newUuidV4(),
      name: sub.label,
      enabled: sub.enabled,
      tagPrefix: sub.tagPrefix,
      detourPolicy: DetourPolicy.defaults,
      url: sub.url,
      updateIntervalHours: sub.updateIntervalHours ?? 24,
      // §401 (D-083) — per-source identity: чем подписка представляется
      // провайдеру. Провайдеры ВЕТВЯТ выдачу по UA, и без переноса та же
      // ссылка отдала бы на новой машине другой набор узлов.
      identity: sub.identity,
      disabledHashes: {
        for (final e in sub.disabled.entries) e.key: at(e.value),
      },
    ));
    byUrl[sub.url] = merged.length - 1;
    applied++;
  }

  return (lists: merged, byUrl: byUrl, applied: applied);
}
