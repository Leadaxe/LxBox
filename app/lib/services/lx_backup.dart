/// LX Backup v1 — переносимый формат обмена настройками с десктопным
/// лаунчером (SPEC 103, фаза 4). Подробности — в docstring ниже.
library;

import 'dart:convert';

import 'package:package_info_plus/package_info_plus.dart';

import '../models/custom_rule.dart';
import '../config/consts.dart';
import '../models/direction.dart';
import '../models/dns_ref.dart';
import '../models/node_sections.dart';
import '../models/parser_config.dart' show kDefaultRuleNum;
import '../models/record_codec.dart';
import '../models/server_list.dart';
import '../models/source_chain.dart';
import 'node_hash.dart' show deepSortKeys;
import 'parser/body_decoder.dart' show IniConfig, decode;
import 'parser/uri_utils.dart' show newUuidV4;
import 'tag_resolver.dart';

/// LX Backup — переносимый формат обмена настройками с десктопным лаунчером
/// (SPEC 103; контракт 1.0, §438).
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
/// §438 — пишется формат 1.0 ([buildLxBackup]). Читаются оба: `lx_backup: 1`
/// (семейство 0.x, legacy-вход) и `lx_backup: 2`. Каждый разбирается своим
/// декодером в одни и те же промежуточные записи ([LxBackupFile]), дальше
/// работает ОДИН код слияния ([mergeBackupSubscriptions],
/// [mergeBackupServers], [resolveBackupChainHops], [renumberBackupAxis],
/// `applyDnsBackup`). Файл 0.10.x разбирается декодером 0.x общим правилом.
///
/// Нет молчаливых потерь (П6): всё неприменённое названо кодом warning'а —
/// и на импорте, и на экспорте.

/// Маркер семейства 0.x в ключе `lx_backup` (только чтение).
const int kLxBackupFormat0x = 1;

/// Маркер контракта 1.0 в ключе `lx_backup` (BACKUP.md §8).
const int kLxBackupFormat10 = 2;

/// §438 — формат, который эта сторона пишет, и старший, который читает. Файл
/// с `lx_backup` выше отвергается целиком, а не разбирается частично
/// (BACKUP.md §8); младший `1` читается legacy-входом.
const int kLxBackupVersion = kLxBackupFormat10;

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

/// §401 (D-082) — `label` одиночного сервера разошёлся с тегом и применён не
/// будет: у канона имени, кроме тега, нет (SPEC 112 контракта, «идентичность
/// узла = тег»). §405 — цепочки этот код больше не касается: их `label`
/// применяет LxBox, оно читается и пишется.
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

/// §438 — запись секций узла отброшена ЦЕЛИКОМ (норма B3,
/// `NODE_SECTIONS.md` §1), или поле `sections` пришло у записи, которой оно
/// не положено. [LxBackupWarning.kind] — вид отброшенной записи,
/// [LxBackupWarning.reason] — `kind` | `rule_set` | `not_allowed`
/// ([kSectionDropKind] и соседи). Остальные записи узла применяются.
const String kWarnSectionRecordDropped = 'backup_section_record_dropped';

/// §438 — запись `sources[]` вида, которому на этой стороне нет места:
/// корневые `auto`/`unsupported` (union 1.0 их не выражает, BACKUP.md §2),
/// незнакомый `kind`, а у LxBox ещё члены папки `chain`/`auto` — цепочка
/// здесь только корневой источник, провайдерской группы в модели нет.
/// [LxBackupWarning.kind] — вид записи. Запись не применяется.
const String kWarnSourceKindUnsupported = 'backup_source_kind_unsupported';

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
  const LxBackupWarning(this.code, this.detail, {this.kind = '', this.reason = ''});

  final String code;
  final String detail;

  /// §438 — вид записи там, где реестр объявляет его параметром
  /// (`backup_section_record_dropped`, `backup_source_kind_unsupported`).
  final String kind;

  /// §438 — причина из закрытого перечня реестра
  /// (`backup_section_record_dropped`: `kind` | `rule_set` | `not_allowed`).
  final String reason;

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
    this.id = '',
    this.fullSettings = false,
    this.position = 0,
  });

  /// §438 — место записи в `sources[]` файла 1.0: новые источники встают в
  /// конец В ПОРЯДКЕ ФАЙЛА (BACKUP.md §9 п. 8), все виды вместе. У 0.x — 0.
  final int position;

  /// §438 — `id` записи в файле. Новая подписка берёт его, если он свободен
  /// (BACKUP.md §9 п. 8); совпавшая держит локальный.
  final String id;

  /// §438 — формат несёт настройки подписки целиком (1.0): у совпавшей
  /// записи отсутствие поля в файле значит умолчание, а не «оставь своё».
  /// Вход 0.x — `false`: там отсутствие значит «файл про это не знает».
  final bool fullSettings;

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
///
/// §438 — та же запись для узла формата 1.0: `origin.raw` вида `uri`/`wg_ini`
/// едет в [uri] (текст как есть), вида `json` и тело без исходника — в
/// [configJson] с тегом записи. Член папки 1.0 ссылается на свою папку
/// [folderRef], а не именем.
class LxServer {
  const LxServer({
    this.uri = '',
    this.configJson,
    this.name = '',
    this.enabled = true,
    this.folder = '',
    this.folderRef = '',
    this.id = '',
    this.sections,
    this.sectionsPresent = false,
    this.detour,
    this.position = 0,
  });

  /// §438 — место корневой записи в `sources[]` файла 1.0 (см.
  /// [LxSubscription.position]); член папки идёт местом своей папки.
  final int position;

  /// §438 — личный detour узла 1.0 (`detour{folder_id?, tag}`): у LxBox это
  /// `overrideDetour` одиночного сервера и `detour` члена папки. Тег конфига
  /// из ссылки получает слияние ([mergeBackupServers]).
  final LxNodeLink? detour;

  /// URI-строка или текст WG-INI.
  final String uri;
  final Map<String, dynamic>? configJson;

  /// §438 — ключ папки файла 1.0 ([LxFolder.key]), членом которой узел
  /// является. Пусто — корневой узел или вход 0.x (там папка — [folder]).
  final String folderRef;

  /// §438 — `id` корневой записи 1.0; у членов папки и у 0.x пусто.
  final String id;

  /// §438 — секции узла из файла 1.0, уже отсеянные по норме B3.
  final NodeSections? sections;

  /// §438 — было ли поле `sections` в записи вообще. Совпавший по телу узел
  /// получает секции файла ЦЕЛИКОМ (включая пустые), только если поле было
  /// (BACKUP.md §9 п. 2); иначе свои остаются.
  final bool sectionsPresent;

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

/// §438 — запись папки формата 1.0 (`sources[]` вида `folder`): её
/// идентичность и собственные настройки. Состав едет записями [LxServer] с
/// [LxServer.folderRef] == [key].
///
/// Применяются настройки, у которых в модели LxBox есть дом: `enabled` и
/// префикс `tag_policy`. `postfix`, `fold`/`fold_tag`, `detour` — поля
/// лаунчера (колонка «Поддержка» BACKUP.md §2), игнорируются молча.
class LxFolder {
  const LxFolder({
    required this.key,
    this.id = '',
    required this.name,
    this.enabled = true,
    this.tagPrefix = '',
    this.position = 0,
  });

  /// §438 — место записи в `sources[]` файла (см. [LxSubscription.position]).
  final int position;

  /// Ключ папки внутри файла: её `id`, а у записи без `id` — синтетический
  /// номер. Им члены ссылаются на свою папку, даже когда файл несёт тёзок.
  final String key;

  /// `id` папки в файле; пусто — не было.
  final String id;
  final String name;
  final bool enabled;
  final String tagPrefix;
}

/// §438 — ссылка формата 1.0 на узел (`hops[]`, `detour`): `folder_id`
/// контейнера машины-экспортёра и сырой тег. Пустой [folderId] — корневое
/// пространство финальных тегов (BACKUP.md §6).
class LxNodeLink {
  const LxNodeLink({this.folderId = '', required this.tag});

  final String folderId;
  final String tag;
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
    this.defaultDomainResolver = '',
  });

  /// §438 — `dns.default_domain_resolver` (1.0; мобильная var
  /// `dns_default_domain_resolver`). Третий скаляр секции живёт по тому же
  /// правилу, что [finalServer] и [strategy] (BACKUP.md §9 п. 5).
  final String defaultDomainResolver;

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
      strategy.isEmpty &&
      defaultDomainResolver.isEmpty;
}

/// §409 — per-Направление бюджет теста узла (`ping_options.groups[tag]`,
/// §040) в переносимой форме: `directions[].ping_url` /
/// `directions[].ping_timeout_ms`.
///
/// Это НЕ `auto.url` / `auto.idle_timeout`: те настраивают urltest-двойника
/// `<tag>-auto` внутри ядра, а эти — ручной и массовый тест узлов в
/// приложении. Поля разные по адресату, и слить их значило бы менять
/// поведение ядра правкой кнопки «Ping».
///
/// Поля объявлены в схеме, применяет их только LxBox (колонка «Поддержка»
/// `docs/BACKUP.md` §2); лаунчер игнорирует молча.
///
/// `null` у поля = override этой половины нет.
///
/// Нормализация — В КОНСТРУКТОРЕ, а не у каждого вызывающего: схема требует
/// `ping_url.minLength: 1` и `ping_timeout_ms.minimum: 1` (контракт 0.12.6,
/// D-096), и пустая строка с нулём — не «строгий бюджет», а мёртвая кнопка
/// «Ping». Держать проверку в одном месте дешевле, чем ловить её пропуск на
/// новом пути записи: сюда сходятся и storage, и разбор файла.
class LxDirectionPing {
  LxDirectionPing({String? url, int? timeoutMs})
    : url = (url != null && url.trim().isNotEmpty) ? url.trim() : null,
      timeoutMs = (timeoutMs != null && timeoutMs > 0) ? timeoutMs : null;

  final String? url;
  final int? timeoutMs;

  bool get isEmpty => url == null && timeoutMs == null;

  /// Форма хранения (`ping_options.groups[tag]`): те же ключи, что пишет
  /// `SettingsStorage.setGroupPing`.
  Map<String, dynamic> toStorage() => <String, dynamic>{
    if (url != null) 'url': url,
    if (timeoutMs != null) 'timeout_ms': timeoutMs,
  };
}

/// §409 — `ping_options` из storage → карта «тег Направления → бюджет теста»
/// для [buildLxBackup].
///
/// Читается ТОЛЬКО подкарта `groups` (per-Направление override'ы): глобальные
/// `url`/`timeout_ms` — настройка приложения, а не Направления, и её место в
/// `vars`, а не в записи `directions[]`.
///
/// Фильтр здесь тот же, что и на импорте: пустой URL и неположительный
/// таймаут в файл не едут — в состоянии они означают «override нет», и
/// выписать их значило бы отправить на ту сторону мёртвую кнопку «Ping».
/// Порядок карты — порядок `groups` в storage, но на файл он не влияет:
/// поля пишутся внутрь записи своего Направления.
Map<String, LxDirectionPing> lxDirectionPingFromStorage(
  Map<String, dynamic> pingOptions,
) {
  final groups = pingOptions['groups'];
  if (groups is! Map) return const {};
  final out = <String, LxDirectionPing>{};
  for (final entry in groups.entries) {
    final tag = entry.key;
    final value = entry.value;
    if (tag is! String || tag.isEmpty || value is! Map) continue;
    final rawUrl = value['url'];
    final rawTimeout = value['timeout_ms'];
    // Отсев пустого делает конструктор: пустой URL и неположительный таймаут
    // в storage значат ровно «override нет».
    final ping = LxDirectionPing(
      url: rawUrl is String ? rawUrl : null,
      timeoutMs: rawTimeout is num ? rawTimeout.toInt() : null,
    );
    if (ping.isEmpty) continue;
    out[tag] = ping;
  }
  return out;
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
    this.directionPing = const {},
    this.chains = const [],
    required this.subscriptions,
    required this.vars,
    required this.routeFinal,
    required this.warnings,
    this.servers = const [],
    this.folders = const [],
    this.chainHops = const {},
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

  /// §409 — бюджеты теста узла, приехавшие вместе с Направлениями: тег →
  /// override. Ключи — ТОЛЬКО теги из [directions]: у Направления с занятым
  /// тегом приехавшее не применяется целиком (§9 BACKUP.md,
  /// [kWarnDirectionExists]), и бюджет вместе с ним — иначе файл менял бы
  /// настройку чужому Направлению, которого сам не создавал.
  ///
  /// Отдельной картой, а не полем [Direction]: у мобилы бюджет живёт не в
  /// Направлении, а в `ping_options.groups[tag]` (§040), и заводить ему
  /// зеркало в модели значило бы получить второй источник правды.
  final Map<String, LxDirectionPing> directionPing;

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
  ///
  /// §438 — у файла 1.0 здесь и корневые узлы, и члены папок (с
  /// [LxServer.folderRef]) в порядке файла.
  final List<LxServer> servers;

  /// §438 — папки формата 1.0 со своими `id` и настройками. У 0.x пусто:
  /// там папка — имя в [LxServer.folder].
  final List<LxFolder> folders;

  /// §438 — позиции цепочек формата 1.0 ссылками (тег цепочки → хопы).
  /// В [chains] хопы до слияния лежат сырыми тегами; в теги конфига их
  /// переводит [resolveBackupChainHops], когда известна карта папок. У 0.x
  /// пусто: там позиции уже строки.
  final Map<String, List<LxNodeLink>> chainHops;

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

/// Собирает LX Backup формата 1.0 (`lx_backup: 2`) из настроек LxBox.
///
/// §438 — запись = запись состояния (BACKUP.md §1): `sources[]` одним
/// списком (подписки, одиночные узлы и папки в порядке списка источников,
/// следом цепочки — так их показывает экран источников), правила и
/// DNS-записи кодеком записей (`record_codec.dart`), секции узлов как есть.
/// Тонкий слой — `directions[]`, `disabled{}`, `identity{}`, переносимые
/// `vars`, `route.final`, `warp[]` — той же формы, что в 0.12.
///
/// [directions] — Направления в порядке списка (§393 B2): они цели правил, и
/// без них правило приезжало бы на чужую машину выключенным.
///
/// [directionPing] — §409, бюджеты теста узла по тегу Направления
/// (`ping_options.groups`, §040). Пишутся только заданные половины.
///
/// [dns] — секция DNS в переносимой форме (`dnsToBackup`); [warp] — записи
/// регистраций WG/MASQUE (§393 B8) уже в каноне схемы.
///
/// Ссылки на узлы (`hops[]` цепочки, `detour` узла) у LxBox — теги конфига;
/// в файл они едут формой `{folder_id?, tag}`: тег члена папки или узла
/// подписки с префиксом становится сырым тегом с `id` контейнера — обратное
/// тому, что делает импорт ([resolveBackupChainHops]).
///
/// Предупреждения: настройки LxBox, которым в 1.0 дома нет (import-rules и
/// реакция на обновление подписки, политика detour источника, ping-опции
/// папки, имя цепочки, `srs`-правила DNS …), названы
/// [kWarnLocalOnlyDropped] — одним на сущность (П6).
Future<LxBackupExport> buildLxBackup({
  required List<ServerList> lists,
  required List<CustomRule> rules,
  required Map<String, String> vars,
  List<Direction> directions = const [],
  Map<String, LxDirectionPing> directionPing = const {},
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
  final links = _LinkIndex(lists);
  final sources = <Map<String, dynamic>>[
    for (final list in lists)
      switch (list) {
        SubscriptionServers() => _subscription10ToJson(list, warnings),
        FolderServers() => _folder10ToJson(list, links, warnings),
        UserServer() => _server10ToJson(list, links, warnings),
      },
    for (final c in chains) _chain10ToJson(c, links, warnings),
  ];

  final portableVars = <String, String>{
    for (final e in vars.entries)
      if (kLxPortableVars.contains(e.key)) e.key: e.value,
  };

  final ruleRecords = <Map<String, dynamic>>[
    for (final r in rules) ..._rule10ToJson(r, warnings),
  ];

  // Порядок ключей корня — перечень BACKUP.md §2: файл читают и правят руками,
  // и перестановка ключей между версиями была бы шумом в diff'ах.
  final out = <String, dynamic>{
    'lx_backup': kLxBackupVersion,
    'exported_by': {
      'app': kLxAppLxBox,
      'version': appVersion,
      'platform': 'android',
    },
    'exported_at': DateTime.now().toUtc().toIso8601String(),
    if (sources.isNotEmpty) 'sources': sources,
    // §393 B2 — цели едут ПЕРЕД правилами и в порядке списка: `include[]`
    // ссылается только вверх, перестановка сломала бы состав.
    if (directions.isNotEmpty)
      'directions': [
        for (final d in directions) _directionToJson(d, directionPing[d.tag]),
      ],
    if (ruleRecords.isNotEmpty) 'rules': ruleRecords,
    if (dns != null && !dns.isEmpty) 'dns': _dns10ToJson(dns),
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

/// §438 — обратный перевод тегов конфига в ссылки формата 1.0.
///
/// Тег корневого узла — `{tag}`; тег члена папки (префикс папки + сырой тег)
/// и узла подписки с префиксом — `{folder_id: id контейнера, tag: сырой}`;
/// всё прочее (Направления, цепочки, служебные теги) — `{tag}` как есть.
/// Импорт делает ровно обратное: префикс найденного контейнера + сырой тег.
class _LinkIndex {
  _LinkIndex(List<ServerList> lists) {
    for (final l in lists) {
      switch (l) {
        case UserServer():
          if (l.name.isNotEmpty) _root.add(l.name);
          for (final n in l.nodes) {
            _root.add(TagResolver.displayTag(l.tagPrefix, n.tag));
          }
        case FolderServers():
          for (final m in l.members) {
            final bare = m.node?.tag ?? '';
            if (bare.isEmpty) continue;
            _members.putIfAbsent(
              TagResolver.displayTag(l.tagPrefix, bare),
              () => (id: l.id, tag: bare),
            );
          }
        case SubscriptionServers():
          if (l.tagPrefix.isNotEmpty) _prefixes.add((l.tagPrefix, l.id));
      }
    }
  }

  final _root = <String>{};
  final _members = <String, ({String id, String tag})>{};
  final _prefixes = <(String, String)>[];

  Map<String, dynamic> link(String tag) {
    if (_root.contains(tag)) return {'tag': tag};
    final member = _members[tag];
    if (member != null) return {'folder_id': member.id, 'tag': member.tag};
    for (final (prefix, id) in _prefixes) {
      final head = '$prefix ';
      if (tag.startsWith(head) && tag.length > head.length) {
        return {'folder_id': id, 'tag': tag.substring(head.length)};
      }
    }
    return {'tag': tag};
  }
}

/// Узел формата 1.0: `origin` из исходника LxBox (текст, каким узел
/// добавлен) и `body` — объект sing-box, когда исходник им и является.
/// Материализованное тело URI/WG-INI не пишется: принимающая сторона берёт
/// исходник (BACKUP.md §9 п. 2), а второй эмиттер тел здесь разошёлся бы со
/// сборкой.
Map<String, dynamic> _origin10(String raw) {
  final t = raw.trim();
  final obj = _tryDecodeObject(t);
  if (obj != null) {
    final isOutbound = obj['type'] is String &&
        !obj.containsKey('outbounds') &&
        !obj.containsKey('endpoints');
    return {
      'origin': {'kind': 'json', 'raw': raw},
      if (isOutbound)
        'body': {
          for (final e in obj.entries)
            if (e.key != 'tag' && e.key != 'detour') e.key: e.value,
        },
    };
  }
  final kind = decode(t) is IniConfig ? 'wg_ini' : 'uri';
  return {
    'origin': {'kind': kind, 'raw': raw},
  };
}

/// §438 — подписка → запись `sources[]` вида `subscription`.
Map<String, dynamic> _subscription10ToJson(
  SubscriptionServers list,
  List<LxBackupWarning> warnings,
) {
  // Дома в 1.0 этим настройкам нет: у лаунчера таких понятий не существует,
  // а односторонний ключ был бы тайным грузом (П1/П3). `detour` источника
  // формат знает, но это поле лаунчера (BACKUP.md §2): политика detour LxBox
  // шире одной ссылки и в файл не едет.
  _noteLocalOnly(warnings, list.name.isEmpty ? list.url : list.name, [
    if (list.importRules.isNotEmpty) 'import_rules',
    if (!list.importRulesEnabled) 'import_rules_enabled',
    if (list.onUpdateAction != SubscriptionOnUpdateAction.rebuild)
      'on_update_action',
    if (list.detourPolicy != DetourPolicy.defaults) 'detour_policy',
  ]);
  final identity = _identityToJson(list.identity);
  return <String, dynamic>{
    'kind': 'subscription',
    'enabled': list.enabled,
    'id': list.id,
    // `name` подписки — имя ИСТОЧНИКА, а не узла.
    'name': list.name,
    if (list.tagPrefix.isNotEmpty)
      'tag_policy': {'prefix': _prefixToContract(list.tagPrefix)},
    'url': list.url,
    'identity': ?identity,
    'update': {'interval_hours': list.updateIntervalHours},
    // §5 BACKUP.md — отметки выключенных узлов: тег → unix seconds (мобила
    // хранит DateTime). Ключ непрозрачен: legacy-хеш 64 hex едет как есть.
    if (list.disabledHashes.isNotEmpty)
      'disabled': {
        for (final e in list.disabledHashes.entries)
          e.key: e.value.toUtc().millisecondsSinceEpoch ~/ 1000,
      },
  };
}

/// §401 (D-083) — per-source identity → объект схемы.
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

/// §438 — одиночный сервер → запись `sources[]` вида `server`.
///
/// Тег записи — имя сервера, а у безымянного — тег его узла. Личный detour
/// узла (`overrideDetour`) едет ссылкой `detour`; остальные флаги политики
/// detour дома в 1.0 не имеют. Префикса тегов у корневого узла в 1.0 нет.
Map<String, dynamic> _server10ToJson(
  UserServer list,
  _LinkIndex links,
  List<LxBackupWarning> warnings,
) {
  final tag = list.name.isNotEmpty
      ? list.name
      : (list.nodes.isNotEmpty ? list.nodes.first.tag : '');
  final policy = list.detourPolicy;
  _noteLocalOnly(warnings, tag, [
    if (list.tagPrefix.isNotEmpty) 'tag_prefix',
    if (policy.copyWith(overrideDetour: '') != DetourPolicy.defaults)
      'detour_policy',
  ]);
  return <String, dynamic>{
    'kind': 'server',
    if (tag.isNotEmpty) 'tag': tag,
    'enabled': list.enabled,
    if (list.rawBody.trim().isNotEmpty) ..._origin10(list.rawBody),
    if (policy.overrideDetour.isNotEmpty)
      'detour': links.link(policy.overrideDetour),
    if (list.sections != null) 'sections': list.sections!.toJson(),
    'id': list.id,
  };
}

/// §438 — папка → запись `sources[]` вида `folder` с составом в `nodes[]`.
///
/// Член с разобранным узлом — `server`; член, чей текст не разобрался, —
/// `unsupported` с исходником (так он и хранится у LxBox, §234).
Map<String, dynamic> _folder10ToJson(
  FolderServers list,
  _LinkIndex links,
  List<LxBackupWarning> warnings,
) {
  _noteLocalOnly(warnings, list.name, [
    if (list.pingUrl != null) 'ping_url',
    if (list.pingTimeoutMs != null) 'ping_timeout_ms',
    if (list.detourPolicy != DetourPolicy.defaults) 'detour_policy',
  ]);
  final nodes = <Map<String, dynamic>>[];
  for (final m in list.members) {
    if (m.raw.trim().isEmpty) continue;
    final node = m.node;
    nodes.add(<String, dynamic>{
      'kind': node == null ? 'unsupported' : 'server',
      if (node != null && node.tag.isNotEmpty) 'tag': node.tag,
      'enabled': m.enabled,
      ..._origin10(m.raw),
      if (m.detour.isNotEmpty) 'detour': links.link(m.detour),
      if (node == null) 'reason': 'the member text does not parse into a node',
      if (m.sections != null) 'sections': m.sections!.toJson(),
    });
  }
  return <String, dynamic>{
    'kind': 'folder',
    'enabled': list.enabled,
    'id': list.id,
    'name': list.name,
    if (list.tagPrefix.isNotEmpty)
      'tag_policy': {'prefix': _prefixToContract(list.tagPrefix)},
    'nodes': nodes,
  };
}

/// §438 — цепочка → запись `sources[]` вида `chain`: настройки маршрута в
/// `body` (канон `source_chain.schema.json` без позиций), позиции — ссылками
/// в `hops[]`. Имени цепочки (`label`) дома в 1.0 нет.
Map<String, dynamic> _chain10ToJson(
  SourceChain c,
  _LinkIndex links,
  List<LxBackupWarning> warnings,
) {
  _noteLocalOnly(warnings, c.tag, [
    if (c.label.isNotEmpty && c.label != c.tag) 'label',
  ]);
  final canon = c.toJson()
    ..remove('tag')
    ..remove('label')
    ..remove('enabled')
    ..remove('hops')
    // `order` — место цепочки в списке источников ЭТОГО устройства; в файле
    // его роль играет порядок записей `sources[]`.
    ..remove('order');
  return <String, dynamic>{
    'kind': 'chain',
    'tag': c.tag,
    'enabled': c.enabled,
    'body': {'type': kChainOutboundType, ...canon},
    'hops': [for (final h in c.hops) links.link(h)],
  };
}

/// §438 — правило LxBox → записи `rules[]` формата 1.0 (кодек записей).
///
/// Правило вида json (§225) — это inline 1.0 с телом как есть. Массив тел —
/// по записи на тело, в том же месте оси; текст, который телом не
/// разбирается, дома не имеет и назван [kWarnLocalOnlyDropped].
List<Map<String, dynamic>> _rule10ToJson(
  CustomRule rule,
  List<LxBackupWarning> warnings,
) {
  if (rule is! CustomRuleJson) return [ruleToRecord(rule)];
  Object? decoded;
  try {
    decoded = jsonDecode(rule.json);
  } catch (_) {
    decoded = null;
  }
  final bodies = switch (decoded) {
    Map() => [decoded.cast<String, dynamic>()],
    List() when decoded.isNotEmpty && decoded.every((e) => e is Map) => [
        for (final e in decoded) (e as Map).cast<String, dynamic>(),
      ],
    _ => const <Map<String, dynamic>>[],
  };
  if (bodies.isEmpty) {
    _noteLocalOnly(warnings, rule.name, const ['json']);
    return const [];
  }
  return [
    for (var i = 0; i < bodies.length; i++)
      <String, dynamic>{
        'kind': 'inline',
        if (i == 0) 'id': rule.id,
        'name': i == 0 ? rule.name : '${rule.name} #${i + 1}',
        'enabled': rule.enabled,
        if (rule.orderNum != null) 'num': rule.orderNum,
        'body': bodies[i],
      },
  ];
}

/// §438 — секция DNS → форма 1.0 кодеком записей: сервер `user` телом без
/// `tag`, `template` — тегом, `preset` — ссылкой `ref`; правило `user` телом
/// с `server`, `preset` — ссылкой.
Map<String, dynamic> _dns10ToJson(LxDns dns) => {
      if (dns.strategy.isNotEmpty) 'strategy': dns.strategy,
      if (dns.finalServer.isNotEmpty) 'final': dns.finalServer,
      if (dns.defaultDomainResolver.isNotEmpty)
        'default_domain_resolver': dns.defaultDomainResolver,
      if (dns.servers.isNotEmpty)
        'servers': [
          for (final s in dns.servers)
            switch (s.kind) {
              'user' => dnsServerToRecord(DnsServerInline(
                  enabled: s.enabled,
                  tag: s.name,
                  body: s.value ?? const {},
                )),
              // `ref` собран `dnsToBackup` в форме `<preset_id>:<tag>`.
              'preset' => _presetServerRecord(s),
              _ => dnsServerToRecord(
                  DnsServerTemplate(enabled: s.enabled, tag: s.name)),
            },
        ],
      if (dns.rules.isNotEmpty)
        'rules': [
          for (final r in dns.rules)
            r.kind == 'preset'
                ? dnsRuleToRecord(
                    DnsRulePreset(presetId: r.ref, enabled: r.enabled))
                : dnsRuleToRecord(DnsRuleInline(
                    name: r.name,
                    rule: r.value ?? const {},
                    enabled: r.enabled,
                  )),
        ],
    };

Map<String, dynamic> _presetServerRecord(LxDnsRef s) {
  final ref = s.ref.isNotEmpty ? s.ref : s.name;
  final presetId = presetIdOfDnsServerRef(ref);
  return dnsServerToRecord(
    DnsServerPreset(
      enabled: s.enabled,
      tag: presetId.isEmpty ? ref : ref.substring(ref.indexOf(':') + 1),
    ),
    presetId: presetId,
  );
}

/// Строка → JSON-объект, если это он. Массив/скаляр/мусор → null.
Map<String, dynamic>? _tryDecodeObject(String body) {
  if (!body.startsWith('{')) return null;
  try {
    final decoded = jsonDecode(body);
    return decoded is Map ? decoded.cast<String, dynamic>() : null;
  } catch (_) {
    return null;
  }
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
///
/// §438 — формат опознаётся ключом `lx_backup` одним сравнением ещё до
/// разбора тела (BACKUP.md §8): `1` — декодер 0.x, `2` — декодер 1.0.
/// Больше [kLxBackupVersion] — отказ целиком; вне `{1, 2}` — не наш файл.
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
  if (version < kLxBackupFormat0x) {
    throw const FormatException('Это не файл LX Backup: нет поля lx_backup');
  }
  if (version == kLxBackupFormat10) {
    return _parse10(
      decoded,
      knownOutbounds: knownOutbounds,
      knownPresets: knownPresets,
      knownChains: knownChains,
    );
  }
  return _parse0x(
    decoded,
    version,
    knownOutbounds: knownOutbounds,
    knownPresets: knownPresets,
    knownChains: knownChains,
  );
}

/// Декодер семейства 0.x (`lx_backup: 1`).
LxBackupFile _parse0x(
  Map<String, dynamic> decoded,
  int version, {
  required Set<String> knownOutbounds,
  required Set<String> knownPresets,
  required Set<String> knownChains,
}) {
  // §401 — default-deny на ВСЮ глубину файла, а не только на корень:
  // вложенный уровень — самое удобное место спрятать чужое поле. Упразднённый
  // `extensions` при этом отделён от прочего незнакомого: он не «лишний
  // ключ», а карман с произвольным содержимым (эталон —
  // `core/backup/file.go:scanUnknown`).
  final warnings = _scanUnknown(decoded);

  final directions = _parseDirections(decoded, knownOutbounds, warnings);
  final knownWithDirections = directions.known;

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
    for (final t in knownChains) t.trim(),
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
    if (!takenChainTags.add(tag)) {
      warnings.add(LxBackupWarning(kWarnChainExists, tag));
      continue;
    }
    chains.add(_chainFromCanon(j, tag));
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

  // Порядок разбора секций = порядок предупреждений в превью: переменные,
  // `route.final`, `warp[]`, затем записи источников.
  final vars = _parseVars(decoded, warnings);
  final routeFinal = _parseRouteFinal(
    decoded,
    knownOutbounds,
    knownWithDirections,
    warnings,
  );
  final warp = _parseWarp(decoded, warnings);

  final by = (decoded['exported_by'] as Map?)?.cast<String, dynamic>() ?? {};
  return LxBackupFile(
    version: version,
    exportedByApp: (by['app'] as String?) ?? '',
    exportedByVersion: (by['version'] as String?) ?? '',
    exportedAt: (decoded['exported_at'] as String?) ?? '',
    directions: directions.directions,
    directionPing: directions.ping,
    rules: sortRulesByAxis(rules),
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

/// Направления файла и то, что они дают остальному разбору.
typedef _ParsedDirections = ({
  List<Direction> directions,
  Map<String, LxDirectionPing> ping,

  /// Известные цели: [knownOutbounds] разбора плюс теги Направлений файла.
  /// Изменяемое: декодер дописывает сюда теги цепочек.
  Set<String> known,
});

/// §393 B1 — Направления разбираются ПЕРВЫМИ и пополняют known-множество:
/// правило, чья цель приехала в этом же файле, обязано прийти РАБОЧИМ, а не
/// выключенным с warning'ом о мёртвой ссылке (BACKUP.md §3). Форма
/// `directions[]` у 0.x и 1.0 одна (тонкий слой, BACKUP.md §1), поэтому и
/// разбор один.
///
/// Занятый тег — не ошибка файла: у пользователя под этим именем своё
/// Направление со своими настройками. Приехавшее не применяется (warning),
/// но тег в known входит — правило цель находит, она просто чужая.
_ParsedDirections _parseDirections(
  Map<String, dynamic> decoded,
  Set<String> knownOutbounds,
  List<LxBackupWarning> warnings,
) {
  final directions = <Direction>[];
  // §409 — бюджеты теста узла применённых Направлений (`ping_options.groups`).
  final directionPing = <String, LxDirectionPing>{};
  final knownWithDirections = knownOutbounds.toSet();
  // §406 (D-095) — занятость тега определяется ТОЧНЫМ совпадением, как при
  // создании Направления руками (`directionTagConflict`). `VPN-DE` при живом
  // `vpn-de` — не тёзка, а второе Направление: для ядра это два разных
  // outbound'а, и объявлять одно из них «уже существующим» значило бы молча
  // потерять приехавшую запись.
  final takenTags = <String>{
    for (final t in knownOutbounds) t.trim(),
  };
  final items = decoded['directions'];
  for (final item in (items is List ? items : const [])) {
    if (item is! Map) continue;
    final j = item.cast<String, dynamic>();
    final rawTag = j['tag'];
    final tag = rawTag is String ? rawTag.trim() : '';
    if (tag.isEmpty) continue; // без тега Направление не адресуемо
    knownWithDirections.add(tag);
    if (!takenTags.add(tag)) {
      warnings.add(LxBackupWarning(kWarnDirectionExists, tag));
      continue;
    }
    directions.add(_directionFromCanon(j, tag));
    // §409 — бюджет теста узла разбирается ТОЛЬКО у применённого
    // Направления: занятый тег уводит запись в `continue` выше, и бюджет
    // уходит вместе с ней. Иначе файл менял бы настройку Направлению,
    // которого сам не создавал (§9 BACKUP.md — своё остаётся своим).
    final ping = _directionPingFromCanon(j, tag, warnings);
    if (!ping.isEmpty) directionPing[tag] = ping;
  }
  return (
    directions: directions,
    ping: directionPing,
    known: knownWithDirections,
  );
}

/// `vars` — только переносимые имена (обе формы одинаковы).
Map<String, String> _parseVars(
  Map<String, dynamic> decoded,
  List<LxBackupWarning> warnings,
) {
  final vars = <String, String>{};
  final raw = decoded['vars'];
  final rawVars = raw is Map ? raw.cast<String, dynamic>() : const {};
  for (final key in rawVars.keys.toList()..sort()) {
    if (!kLxPortableVars.contains(key)) {
      warnings.add(LxBackupWarning(kWarnVarSkipped, key));
      continue;
    }
    vars[key] = '${rawVars[key]}';
  }
  return vars;
}

/// `route.final` — применяется только при известной цели (BACKUP.md §3).
String? _parseRouteFinal(
  Map<String, dynamic> decoded,
  Set<String> knownOutbounds,
  Set<String> known,
  List<LxBackupWarning> warnings,
) {
  final route = decoded['route'];
  final finalTag = route is Map ? route['final'] : null;
  if (finalTag is! String || finalTag.isEmpty) return null;
  if (knownOutbounds.isEmpty || _isKnownOutbound(finalTag, known)) {
    return finalTag;
  }
  warnings.add(LxBackupWarning(kWarnFinalDropped, finalTag));
  return null;
}

/// §393 B8 — записи warp[]: разбираются позже, при применении (парсер не
/// знает про storage). Здесь только отсев мусора и дискриминатор.
List<Map<String, dynamic>> _parseWarp(
  Map<String, dynamic> decoded,
  List<LxBackupWarning> warnings,
) {
  final warp = <Map<String, dynamic>>[];
  final items = decoded['warp'];
  for (final item in (items is List ? items : const [])) {
    if (item is! Map) continue;
    final j = item.cast<String, dynamic>();
    final rawType = j['type'];
    final type = rawType is String ? rawType : '';
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
  return warp;
}

/// §438 — правила по оси `num`, стабильно; неразмеченные — в хвост, в
/// порядке файла (у них нет места на оси, и перебивать размеченных им не за
/// что). Порядок, который разбор отдаёт превью и слиянию.
List<CustomRule> sortRulesByAxis(List<CustomRule> rules) {
  final indexed = [
    for (var i = 0; i < rules.length; i++) (i, rules[i]),
  ];
  indexed.sort((a, b) {
    final an = a.$2.orderNum;
    final bn = b.$2.orderNum;
    if (an != null && bn != null && an != bn) return an.compareTo(bn);
    if (an == null && bn != null) return 1;
    if (an != null && bn == null) return -1;
    return a.$1.compareTo(b.$1);
  });
  return [for (final e in indexed) e.$2];
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
  // §435 / контракт ## 13 — `sections` объявлено схемой (BACKUP.md §2,
  // сторона launcher): до контракта 1.0 ни одна сторона его не пишет, а
  // 0.12-форму записей (`match`/`value`) LxBox не разбирает — второй парсер.
  // Чужое объявленное игнорируется МОЛЧА (BACKUP.md §1): в allowlist ради
  // тишины, без ветки в `_serverFromJson`.
  'sections',
};

const Set<String> _chainKeys = {
  ..._sourceRefKeys,
  'id',
  'tag',
  // §405 — `label` цепочки объявлен в схеме, и применяет его ТОЛЬКО LxBox
  // (колонка «Поддержка» `docs/BACKUP.md` §2, D-094): у нас цепочка носит
  // собственное имя рядом с тегом-ссылкой, лаунчер не применяет и провозит
  // молча.
  // Отсюда: читаем в модель, [kWarnLabelDropped] на нём НЕ поднимаем — терять
  // нечего, поле наше.
  'label',
  'enabled',
  'chain',
  'exclude_from_global',
};

const Set<String> _directionKeys = {
  'tag',
  // §405 — `label` Направления объявлен в схеме, и применяет его только
  // LxBox (колонка «Поддержка» `docs/BACKUP.md` §2, D-094): читается в модель
  // и пишется обратно; лаунчер не применяет и провозит молча.
  'label',
  'enabled',
  'filter',
  'invert',
  'default',
  'include_direct',
  'include_block',
  'include',
  'interrupt_exist_connections',
  // §409 — бюджет теста узла у Направления (`ping_options.groups[tag]`,
  // §040). Поля объявлены в схеме, применяет их только LxBox (колонка
  // «Поддержка» `docs/BACKUP.md` §2); лаунчер не применяет и провозит молча.
  // Без них файл LxBox ловил бы `backup_unknown_field` на собственном
  // экспорте.
  'ping_url',
  'ping_timeout_ms',
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
  'refs', // ## 12 (D-100)
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
    id: (j['id'] is String) ? (j['id'] as String).trim() : '',
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
/// общий обход [_scanUnknown] полным путём.
///
/// §405 — `label` читается В МОДЕЛЬ: это поле применяет LxBox (колонка
/// «Поддержка» `docs/BACKUP.md` §2, D-094). Отсутствие ключа — пустое имя, и
/// показан будет тег ([Direction.displayLabel]).
Direction _directionFromCanon(Map<String, dynamic> j, String tag) {
  final rawAuto = j['auto'];
  return Direction(
    tag: tag,
    // §405 — пустое имя законно: отображаем тег.
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
        ? _directionAutoFromCanon(rawAuto.cast<String, dynamic>())
        : null,
  );
}

/// §409 — `directions[].ping_url` / `directions[].ping_timeout_ms` → бюджет
/// теста узла ([LxDirectionPing]).
///
/// Отсутствие ключа = override нет, и это НЕ ошибка: подавляющее большинство
/// Направлений живёт на глобальном бюджете.
///
/// Валидация повторяет ту, что делает диалог §040 при сохранении: URL идёт
/// обрезанным по краям и пустым не сохраняется, таймаут — целое положительное.
/// Значение, не прошедшее её, ОТБРАСЫВАЕТСЯ, а Направление применяется без
/// него: пустой URL и нулевой таймаут не «строгий бюджет», а мёртвая кнопка
/// «Ping», и уронить из-за них весь файл значило бы потерять всё прочее (П6).
///
/// Тип разошёлся (строка вместо числа, число вместо строки) — знакомый ключ с
/// чужим значением: [kWarnFieldTypeMismatch], как у `subscriptions[].skip`
/// (§401). Значение ВНЕ диапазона своего типа (пустая строка, 0, минус)
/// предупреждения не даёт: тип тот, и приехало ровно то, что на этой стороне
/// означает «override сброшен».
LxDirectionPing _directionPingFromCanon(
  Map<String, dynamic> j,
  String tag,
  List<LxBackupWarning> warnings,
) {
  final rawUrl = j['ping_url'];
  if (rawUrl != null && rawUrl is! String) {
    warnings.add(
      LxBackupWarning(kWarnFieldTypeMismatch, 'directions[$tag].ping_url'),
    );
  }

  final rawTimeout = j['ping_timeout_ms'];
  // `bool` в Dart не `num`, поэтому отдельной проверки на него не нужно.
  if (rawTimeout != null && rawTimeout is! num) {
    warnings.add(
      LxBackupWarning(
        kWarnFieldTypeMismatch,
        'directions[$tag].ping_timeout_ms',
      ),
    );
  }

  // Пустую строку и неположительный таймаут отсеивает конструктор: тип у них
  // верный, и означают они «override сброшен», а не ошибку файла.
  return LxDirectionPing(
    url: rawUrl is String ? rawUrl : null,
    timeoutMs: rawTimeout is num ? rawTimeout.toInt() : null,
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
/// §405 — `label` пишется, когда он непустой И отличается от тега. Поле
/// объявлено в схеме, применяет его только LxBox (колонка «Поддержка»
/// `docs/BACKUP.md` §2, D-094), лаунчер не применяет и провозит молча.
/// `label == tag` не пишем: там нет имени, там повтор тега, и на той стороне
/// он был бы неотличим от осознанно введённого имени.
///
/// §409 — `ping_url` / `ping_timeout_ms` пишутся ТОЛЬКО когда у Направления
/// есть соответствующий override в `ping_options.groups[tag]`: отсутствие
/// ключа и означает «override нет», а выписывать сюда разрешённое значение
/// (глобальное или шаблонное) значило бы превратить умолчание в
/// зафиксированную настройку на принимающей стороне.
Map<String, dynamic> _directionToJson(Direction d, LxDirectionPing? ping) => {
  'tag': d.tag,
  if (d.label.isNotEmpty && d.label != d.tag) 'label': d.label,
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
  if (ping?.url != null) 'ping_url': ping!.url,
  if (ping?.timeoutMs != null) 'ping_timeout_ms': ping!.timeoutMs,
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

/// §393 C9 — каноническая запись `chains[]` → мобильная [SourceChain].
///
/// Достижимость `hops` здесь НЕ проверяется: хоп — чаще всего узел подписки,
/// которого до её обновления не существует, и рубеж валидации у обеих сторон
/// один — сборка конфига (`chain_hop_missing`). Эталон —
/// `core/backup/import.go:importChain`.
///
/// §405 — `label` читается В МОДЕЛЬ: поле применяет LxBox (колонка
/// «Поддержка» `docs/BACKUP.md` §2, D-094). [kWarnLabelDropped] не
/// поднимается —
/// предупреждать не о чем, ничего не теряется. Отсутствие ключа — пустое имя,
/// показан будет тег.
SourceChain _chainFromCanon(Map<String, dynamic> j, String tag) {
  final canon =
      (j['chain'] as Map?)?.cast<String, dynamic>() ??
      const <String, dynamic>{};
  // Канон разбирается ШТАТНЫМ парсером модели: второй разбор тех же полей
  // разошёлся бы с ним на первой же правке (трёхзначный `strip_evasion`,
  // порядок каталога `strip`, `null` внутри `rewrite`).
  final parsed = SourceChain.fromJson({...canon, 'tag': tag});
  return parsed.copyWith(
    label: (j['label'] as String?) ?? '',
    // Отсутствие ключа = true (`enabled.default` схемы). В ожиданиях корпуса
    // ключа нет вовсе, и читать его отсутствие как false значило бы
    // импортировать выключенными все цепочки лаунчера.
    enabled: j['enabled'] as bool? ?? true,
  );
}

/// §406 (D-095) — цель правила и `route.final` опознаются ТОЧНЫМ совпадением
/// после `trim()`.
///
/// Тег outbound'а у ядра регистрозависим: правило на `VPN-DE` при Направлении
/// `vpn-de` ядро не свяжет ни с чем. Регистронезависимое опознание объявляло
/// бы такую цель известной и пропускало правило ВКЛЮЧЁННЫМ — то есть ровно в
/// тот отказ конфига, ради которого гейт и стоит. Разошедшийся регистр — это
/// неизвестная цель, и правило обязано приехать выключенным.
///
/// Зарезервированные литералы сравниваются в каноническом написании ядра
/// (`_reservedOutbounds`, всё в нижнем регистре): `Direct` таким же
/// outbound'ом для ядра не является.
bool _isKnownOutbound(String tag, Set<String> known) {
  final t = tag.trim();
  return _reservedOutbounds.contains(t) ||
      known.map((e) => e.trim()).contains(t);
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
        // ## 12 — `refs` главнее `ref`; без него фабрика возьмёт `srsUrl`.
        'srsUrls': _strList(j['refs']),
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

// ---------------------------------------------------------------------------
// §438 — декодер формата 1.0 (`lx_backup: 2`).
//
// Записи файла 1.0 — записи состояния лаунчера («метаданные + body»), и
// переводятся они в те же промежуточные записи, что даёт декодер 0.x:
// [LxSubscription], [LxServer], [LxFolder], [SourceChain], [CustomRule],
// [LxDns]. Слияние дальше одно на оба формата. Правила, DNS-записи и секции
// узлов читает кодек записей (`record_codec.dart`, `NodeSections.fromJson`) —
// тот же, что станет корневым парсером хранения в волне 4.
//
// Разбор терпим к типам: ключ чужого типа не роняет файл (П6), а читается
// как отсутствующий.
// ---------------------------------------------------------------------------

String _str(Object? v) => v is String ? v : '';

/// §438 — `tag_policy.prefix` контракта → префикс LxBox и обратно.
///
/// У контракта финальный тег = `prefix` + сырой тег (разделитель — часть
/// префикса: `"[P] "`), у LxBox = префикс + пробел + сырой тег
/// ([TagResolver.displayTag]). Без перевода `"[P] "` давал бы у LxBox
/// `"[P]  NL-1"`, а префикс LxBox `"PR"` у лаунчера — `"PRnode"`, и ссылки
/// правил на финальные теги расходились бы между сторонами.
String _prefixFromContract(Object? v) => _str(v).trimRight();

String _prefixToContract(String prefix) => prefix.isEmpty ? '' : '$prefix ';

String _trimmed(Object? v) => v is String ? v.trim() : '';

Map<String, dynamic>? _obj(Object? v) =>
    v is Map ? v.cast<String, dynamic>() : null;

List<Object?> _list(Object? v) => v is List ? v : const [];

bool _enabledOf(Map<String, dynamic> j) =>
    j['enabled'] is bool ? j['enabled'] as bool : true;

/// Как назвать запись `sources[]` пользователю: адрес подписки, иначе имя,
/// иначе тег (эталон — `source10Label` лаунчера).
String _source10Label(Map<String, dynamic> j) {
  final url = _trimmed(j['url']);
  if (url.isNotEmpty) return url;
  final name = _trimmed(j['name']);
  if (name.isNotEmpty) return name;
  return _trimmed(j['tag']);
}

LxBackupFile _parse10(
  Map<String, dynamic> decoded, {
  required Set<String> knownOutbounds,
  required Set<String> knownPresets,
  required Set<String> knownChains,
}) {
  final warnings = _scanUnknown10(decoded);

  final parsedDirections = _parseDirections(decoded, knownOutbounds, warnings);
  final known = parsedDirections.known;

  final subscriptions = <LxSubscription>[];
  final servers = <LxServer>[];
  final folders = <LxFolder>[];
  final chains = <SourceChain>[];
  final chainHops = <String, List<LxNodeLink>>{};
  final takenChainTags = <String>{
    for (final t in knownChains) t.trim(),
  };

  final sources = _list(decoded['sources']);
  for (var i = 0; i < sources.length; i++) {
    final j = _obj(sources[i]);
    if (j == null) continue;
    final kind = _str(j['kind']);
    switch (kind) {
      case 'subscription':
        _dropForeignSections(j, kind, warnings);
        subscriptions.add(_subscription10(j, i, warnings));
      case 'server':
        final server = _server10(j, warnings, position: i);
        if (server != null) servers.add(server);
      case 'folder':
        _dropForeignSections(j, kind, warnings);
        final id = _trimmed(j['id']);
        // Имя папки сравнивается как есть (BACKUP.md §9 п. 3): без подрезки.
        final name = _str(j['name']);
        // Члены ссылаются на папку ключом, а не именем: в файле бывают тёзки.
        // У записи без `id` ключ — номер записи с префиксом, которого у
        // настоящего `id` не бывает.
        final key = id.isNotEmpty ? id : '${String.fromCharCode(0)}$i';
        final policy = _obj(j['tag_policy']);
        folders.add(LxFolder(
          position: i,
          key: key,
          id: id,
          name: name,
          enabled: _enabledOf(j),
          tagPrefix: _prefixFromContract(policy?['prefix']),
        ));
        for (final rawNode in _list(j['nodes'])) {
          final node = _obj(rawNode);
          if (node == null) continue;
          final member = _folderMember10(node, name, key, warnings);
          if (member != null) servers.add(member);
        }
      case 'chain':
        final tag = _trimmed(j['tag']);
        // Безымянная цепочка не адресуема: пропуск молча, как в 0.x.
        if (tag.isEmpty) continue;
        _dropForeignSections(j, kind, warnings);
        known.add(tag);
        if (!takenChainTags.add(tag)) {
          warnings.add(LxBackupWarning(kWarnChainExists, tag));
          continue;
        }
        final links = <LxNodeLink>[
          for (final h in _list(j['hops']))
            if (_obj(h) case final hop?)
              LxNodeLink(
                folderId: _trimmed(hop['folder_id']),
                tag: _str(hop['tag']),
              ),
        ];
        chains.add(_chain10(j, tag, links, warnings));
        chainHops[tag] = links;
      default:
        // Корневые `auto`/`unsupported` union не выражает, незнакомый вид —
        // чужая сторона, ушедшая вперёд по схеме. Молча не теряется (П6).
        warnings.add(LxBackupWarning(
          kWarnSourceKindUnsupported,
          _source10Label(j),
          kind: kind,
        ));
    }
  }

  final rules = <CustomRule>[];
  for (final item in _list(decoded['rules'])) {
    final j = _obj(item);
    if (j == null) continue;
    final rule = _rule10(j, known, knownPresets, warnings);
    if (rule != null) rules.add(rule);
  }

  final vars = _parseVars(decoded, warnings);
  final routeFinal = _parseRouteFinal(decoded, knownOutbounds, known, warnings);
  final warp = _parseWarp(decoded, warnings);
  final dns = _dns10(decoded['dns'], knownPresets, warnings);

  final by = _obj(decoded['exported_by']) ?? const <String, dynamic>{};
  return LxBackupFile(
    version: kLxBackupFormat10,
    exportedByApp: _str(by['app']),
    exportedByVersion: _str(by['version']),
    exportedAt: _str(decoded['exported_at']),
    directions: parsedDirections.directions,
    directionPing: parsedDirections.ping,
    rules: sortRulesByAxis(rules),
    chains: chains,
    chainHops: chainHops,
    subscriptions: subscriptions,
    servers: servers,
    folders: folders,
    dns: dns,
    warp: warp,
    vars: vars,
    routeFinal: routeFinal,
    warnings: warnings,
  );
}

/// Секции у записи, которой они не положены (подписка, папка, цепочка,
/// `unsupported`): поле снимается целиком с `reason: not_allowed`. Пустой
/// набор предупреждения не даёт — терять в нём нечего.
void _dropForeignSections(
  Map<String, dynamic> j,
  String kind,
  List<LxBackupWarning> warnings,
) {
  final raw = _obj(j['sections']);
  if (raw == null) return;
  final dns = _obj(raw['dns']);
  final carriesRecords = _list(raw['rules']).isNotEmpty ||
      _list(dns?['servers']).isNotEmpty ||
      _list(dns?['rules']).isNotEmpty;
  if (!carriesRecords) return;
  warnings.add(LxBackupWarning(
    kWarnSectionRecordDropped,
    '${_source10Label(j)}: sections',
    kind: kind,
    reason: kSectionDropNotAllowed,
  ));
}

/// Секции узла `kind: server`: кодек записей и отбраковка по норме B3 с
/// причиной у каждой отброшенной записи.
NodeSections? _sections10(
  Object? raw,
  String nodeTag,
  List<LxBackupWarning> warnings,
) {
  final drops = <NodeSectionDrop>[];
  final sections = NodeSections.fromJson(raw, drops: drops);
  for (final d in drops) {
    warnings.add(LxBackupWarning(
      kWarnSectionRecordDropped,
      '$nodeTag: ${d.text}',
      kind: d.kind,
      reason: d.reason,
    ));
  }
  return sections;
}

/// Узел `kind: server` (корневой или член папки) → [LxServer].
///
/// Тело для дедупа и хранения берётся из ИСХОДНИКА (`origin.raw`), а
/// материализованное `body` — только у узла без исходника (BACKUP.md §9
/// п. 2). Исходник `json` и тело без исходника получают тег записи: у LxBox
/// имя узла читается из его JSON, а тег записи и есть идентичность. Текст
/// URI и WG-INI едет как есть: имя у share-ссылки в разных схемах лежит в
/// разных местах, и переписывать его импорт не берётся.
///
/// `detour` узла — ссылка на узел, через который дозваниваться; у LxBox это
/// личный detour узла, и едет он в обе стороны (§438).
LxServer? _server10(
  Map<String, dynamic> j,
  List<LxBackupWarning> warnings, {
  String folder = '',
  String folderRef = '',
  int position = 0,
}) {
  final tag = _trimmed(j['tag']);
  final origin = _obj(j['origin']);
  final raw = _str(origin?['raw']);
  var uri = '';
  Map<String, dynamic>? configJson;
  if (raw.trim().isNotEmpty) {
    final obj =
        _str(origin?['kind']) == 'json' ? _tryDecodeObject(raw.trim()) : null;
    if (obj != null) {
      configJson = {...obj, if (tag.isNotEmpty) 'tag': tag};
    } else {
      // `uri`, `wg_ini`, будущие виды и нечитаемый json — текст как есть.
      uri = raw;
    }
  } else if (_obj(j['body']) case final body?) {
    configJson = {
      if (tag.isNotEmpty) 'tag': tag,
      for (final e in body.entries)
        if (e.key != 'tag' && e.key != 'detour') e.key: e.value,
    };
  }
  if (uri.isEmpty && configJson == null) return null;

  final sectionsPresent = j.containsKey('sections');
  final detour = _obj(j['detour']);
  final detourTag = _str(detour?['tag']);
  return LxServer(
    detour: detourTag.isEmpty
        ? null
        : LxNodeLink(folderId: _trimmed(detour?['folder_id']), tag: detourTag),
    uri: uri,
    configJson: configJson,
    name: tag,
    enabled: _enabledOf(j),
    folder: folder,
    folderRef: folderRef,
    position: position,
    id: folderRef.isEmpty ? _trimmed(j['id']) : '',
    sections:
        sectionsPresent ? _sections10(j['sections'], tag, warnings) : null,
    sectionsPresent: sectionsPresent,
  );
}

/// Член папки 1.0. `server` — узел; `unsupported` с исходником — у LxBox
/// есть дом: нечитаемый член папки хранит текст и виден в списке (§234);
/// `chain`/`auto` папка LxBox не держит — [kWarnSourceKindUnsupported].
LxServer? _folderMember10(
  Map<String, dynamic> node,
  String folderName,
  String folderKey,
  List<LxBackupWarning> warnings,
) {
  final kind = _str(node['kind']);
  final tag = _trimmed(node['tag']);
  switch (kind) {
    case 'server':
      return _server10(
        node,
        warnings,
        folder: folderName,
        folderRef: folderKey,
      );
    case 'unsupported':
      final raw = _str(_obj(node['origin'])?['raw']);
      if (raw.trim().isNotEmpty) {
        _dropForeignSections(node, kind, warnings);
        return LxServer(
          uri: raw,
          name: tag,
          enabled: _enabledOf(node),
          folder: folderName,
          folderRef: folderKey,
        );
      }
  }
  warnings.add(LxBackupWarning(
    kWarnSourceKindUnsupported,
    '$folderName: ${tag.isEmpty ? kind : tag}',
    kind: kind,
  ));
  return null;
}

/// Подписка 1.0. Применяется то, у чего у LxBox есть дом: имя, `enabled`,
/// префикс `tag_policy`, интервал `update`, `disabled`, `identity`. Поля
/// лаунчера (`postfix`, `fold`/`fold_tag`, `detour`, `skip`, `max_nodes`,
/// `relays_in_directions`, `update.auto_refresh`) игнорируются молча
/// (BACKUP.md §1, колонка «Поддержка»).
LxSubscription _subscription10(
  Map<String, dynamic> j,
  int position,
  List<LxBackupWarning> warnings,
) {
  final policy = _obj(j['tag_policy']) ?? const <String, dynamic>{};
  final update = _obj(j['update']) ?? const <String, dynamic>{};
  final interval = update['interval_hours'];
  return LxSubscription(
    id: _trimmed(j['id']),
    url: _str(j['url']),
    label: _str(j['name']),
    enabled: _enabledOf(j),
    tagPrefix: _prefixFromContract(policy['prefix']),
    updateIntervalHours: interval is num ? interval.toInt() : null,
    disabled: _disabledFromJson(j['disabled']),
    identity: _identityFromJson(j['identity'], _source10Label(j), warnings),
    fullSettings: true,
    position: position,
  );
}

/// Ключи тела цепочки, которые применяет модель LxBox (плюс дискриминатор
/// `type`). Прочее — [kWarnUnknownField]: тело типизировано моделью, и
/// провезти незнакомый ключ ей некуда.
const Set<String> _chain10BodyKeys = {
  'type',
  'idle_timeout',
  'rewrite',
  'strip',
  'strip_evasion',
};

/// Цепочка 1.0: настройки маршрута из `body`, позиции — сырыми тегами (в
/// теги конфига их переводит [resolveBackupChainHops]).
SourceChain _chain10(
  Map<String, dynamic> j,
  String tag,
  List<LxNodeLink> hops,
  List<LxBackupWarning> warnings,
) {
  final body = _obj(j['body']) ?? const <String, dynamic>{};
  for (final key in body.keys.toList()..sort()) {
    if (!_chain10BodyKeys.contains(key)) {
      warnings.add(
          LxBackupWarning(kWarnUnknownField, 'sources[$tag].body.$key'));
    }
  }
  return SourceChain.fromJson({
    for (final e in body.entries)
      if (_chain10BodyKeys.contains(e.key)) e.key: e.value,
    'tag': tag,
    'enabled': _enabledOf(j),
    'hops': [for (final h in hops) h.tag],
  });
}

/// Правило 1.0 → правило LxBox через кодек записей.
///
/// `inline` с ключами тела, которых типизированное правило не держит
/// (`method: drop`, самостоятельный `action`, незнакомый матчер), переносится
/// видом json — телом целиком, без потерь: вырезать ключ значило бы изменить
/// смысл правила (норма B3). `rule_set` в теле (наборы едут `refs[]`) и
/// `srs` с незнакомым ключом дома не имеют — запись отбрасывается целиком с
/// [kWarnUnknownField].
CustomRule? _rule10(
  Map<String, dynamic> j,
  Set<String> known,
  Set<String> knownPresets,
  List<LxBackupWarning> warnings,
) {
  final kind = _str(j['kind']);
  final name = _str(j['name']);
  final ref = _str(j['ref']);
  final label = name.isNotEmpty ? name : (ref.isNotEmpty ? ref : kind);
  if (kind != 'inline' && kind != 'srs' && kind != 'preset') {
    // Вид `json` формата 0.12 в 1.0 снят (он был тем же inline).
    warnings.add(LxBackupWarning(kWarnUnknownField, 'rules[].kind=$kind'));
    return null;
  }
  final read = ruleFromRecord(j);
  final rule = read.value;
  if (rule == null) {
    warnings.add(
        LxBackupWarning(kWarnUnknownField, 'rules[$label]: ${read.dropped}'));
    return null;
  }

  if (rule is CustomRulePreset) {
    CustomRule out = rule;
    // У preset имени в записи нет (обязательно оно только у inline/srs):
    // правило зовётся своей ссылкой.
    if (out.name.isEmpty) out = out.withName(rule.presetId);
    if (knownPresets.isNotEmpty && !knownPresets.contains(rule.presetId)) {
      warnings.add(LxBackupWarning(kWarnUnknownPreset, rule.presetId));
      out = out.withEnabled(false);
    }
    return out;
  }

  final body = _obj(j['body']) ?? const <String, dynamic>{};
  var out = rule;
  if (read.unknownKeys.isNotEmpty) {
    if (kind != 'inline' || read.unknownKeys.contains('rule_set')) {
      warnings.add(LxBackupWarning(
        kWarnUnknownField,
        'rules[$label].body: ${read.unknownKeys.join(', ')}',
      ));
      return null;
    }
    out = CustomRuleJson(
      id: rule.id,
      name: rule.name,
      enabled: rule.enabled,
      orderNum: rule.orderNum,
      json: jsonEncode(body),
    );
    // `dns`/`resolve` — поля LxBox у типизированного правила; у правила вида
    // json им места нет, и молча они не теряются.
    for (final key in const ['dns', 'resolve']) {
      if (j[key] is Map && (j[key] as Map).isNotEmpty) {
        warnings.add(LxBackupWarning(kWarnUnknownField, 'rules[$label].$key'));
      }
    }
  }

  // Цель проверяется, только когда тело её называет: без `outbound` правило
  // метит в умолчание, у `action: reject` цели нет.
  final target = _str(body['outbound']);
  if (target.isNotEmpty &&
      known.isNotEmpty &&
      !_isKnownOutbound(target, known)) {
    warnings.add(LxBackupWarning(kWarnUnknownOutbound, '$label → $target'));
    out = out.withEnabled(false);
  }
  return out;
}

/// DNS-секция 1.0 → [LxDns] через кодек записей.
///
/// Серверы: `user` (тело без `tag`), `template` (ссылка тегом), `preset`
/// (ссылка `ref`, тега нет). Правила: `user` (тело с `server`) и `preset`.
/// Прочее — [kWarnDnsEntrySkipped], как у 0.x.
LxDns? _dns10(
  Object? raw,
  Set<String> knownPresets,
  List<LxBackupWarning> warnings,
) {
  final j = _obj(raw);
  if (j == null) return null;

  final servers = <LxDnsRef>[];
  for (final item in _list(j['servers'])) {
    final e = _obj(item);
    if (e == null) continue;
    final kind = _str(e['kind']);
    final read = (kind == 'user' || kind == 'template' || kind == 'preset')
        ? dnsServerFromRecord(e)
        : null;
    final server = read?.value;
    if (server == null) {
      warnings.add(LxBackupWarning(
        kWarnDnsEntrySkipped,
        'dns.servers: ${read?.dropped ?? 'kind=$kind'}',
      ));
      continue;
    }
    // preset — `ref` целиком (`<preset_id>:<tag>`): он и ключ слияния. Пресет,
    // которого в шаблоне этой стороны нет, применить нечем.
    final ref = _trimmed(e['ref']);
    final presetId = presetIdOfDnsServerRef(ref);
    if (server is DnsServerPreset &&
        presetId.isNotEmpty &&
        knownPresets.isNotEmpty &&
        !knownPresets.contains(presetId)) {
      warnings.add(LxBackupWarning(kWarnDnsEntrySkipped, 'dns.servers: $ref'));
      continue;
    }
    servers.add(switch (server) {
      DnsServerInline() => LxDnsRef(
          kind: 'user',
          name: server.tag,
          enabled: server.enabled,
          value: server.body,
        ),
      DnsServerPreset() => LxDnsRef(
          kind: 'preset',
          ref: ref.isNotEmpty ? ref : server.tag,
          enabled: server.enabled,
        ),
      DnsServerTemplate() =>
        LxDnsRef(kind: 'template', name: server.tag, enabled: server.enabled),
    });
  }

  final rules = <LxDnsRef>[];
  for (final item in _list(j['rules'])) {
    final e = _obj(item);
    if (e == null) continue;
    final kind = _str(e['kind']);
    final read =
        (kind == 'user' || kind == 'preset') ? dnsRuleFromRecord(e) : null;
    switch (read?.value) {
      case final DnsRuleInline rule:
        rules.add(LxDnsRef(
          kind: 'user',
          name: rule.name,
          enabled: rule.enabled,
          value: rule.rule,
        ));
      case final DnsRulePreset rule
          when knownPresets.isEmpty || knownPresets.contains(rule.presetId):
        rules.add(LxDnsRef(
          kind: 'preset',
          ref: rule.presetId,
          enabled: rule.enabled,
        ));
      case DnsRulePreset():
        warnings.add(LxBackupWarning(
          kWarnDnsEntrySkipped,
          'dns.rules: ${_str(e['ref'])}',
        ));
      default:
        warnings.add(LxBackupWarning(
          kWarnDnsEntrySkipped,
          'dns.rules: ${read?.dropped ?? 'kind=$kind'}',
        ));
    }
  }

  return LxDns(
    servers: servers,
    rules: rules,
    finalServer: _str(j['final']),
    strategy: _str(j['strategy']),
    defaultDomainResolver: _str(j['default_domain_resolver']),
  );
}

// ─── §438 — обход неизвестных ключей формата 1.0 ────────────────────────────
//
// Списки — таблица полей BACKUP.md §2 формата 1.0 (схема
// `backup.schema.json`), написанные руками по той же причине, что у 0.x:
// контракт — это документ, а не форма наших классов. Списки 0.x и 1.0
// разные: у 0.x правило несёт `match`/`outbound`, у 1.0 — `body`/`refs`.

const Set<String> _root10Keys = {
  'lx_backup',
  'exported_by',
  'exported_at',
  'sources',
  'directions',
  'rules',
  'dns',
  'vars',
  'route',
  'warp',
};

/// Общая часть узла (`$defs/node`): её несёт и корневая запись, и член папки.
const Set<String> _node10Keys = {
  'kind',
  'tag',
  'enabled',
  'origin',
  'body',
  'detour',
  'hops',
  'group',
  'service',
  'reason',
  'sections',
};

/// Запись `sources[]` любого вида: объединение ключей, как у лаунчера — ключ,
/// законный у одного вида, на записи другого предупреждения не даёт.
const Set<String> _source10Keys = {
  ..._node10Keys,
  'id',
  'name',
  'tag_policy',
  'nodes',
  'url',
  'identity',
  'relays_in_directions',
  'skip',
  'max_nodes',
  'update',
  'disabled',
  'fold',
  'fold_tag',
};

const Set<String> _origin10Keys = {'kind', 'raw', 'sub_url'};
const Set<String> _link10Keys = {'folder_id', 'tag'};
const Set<String> _tagPolicy10Keys = {'prefix', 'postfix'};
const Set<String> _update10Keys = {'interval_hours', 'auto_refresh'};
const Set<String> _group10Keys = {
  'group_type',
  'default',
  'members',
  'strategy',
};
const Set<String> _fold10Keys = {'mode', 'auto'};
const Set<String> _sections10Keys = {'rules', 'dns'};
const Set<String> _sectionsDns10Keys = {'servers', 'rules'};

const Set<String> _rule10Keys = {
  'kind',
  'name',
  'enabled',
  'num',
  'ref',
  'vars',
  'refs',
  'body',
  'id',
  'dns',
  'resolve',
};

const Set<String> _dns10Keys = {
  'strategy',
  'final',
  'default_domain_resolver',
  'servers',
  'rules',
};
const Set<String> _dnsServer10Keys = {'kind', 'tag', 'ref', 'enabled', 'body'};
const Set<String> _dnsRule10Keys = {
  'kind',
  'ref',
  'name',
  'id',
  'enabled',
  'body',
};

/// §438 — обход файла 1.0: те же два класса находок, что у [_scanUnknown]
/// (`extensions` одним warning'ом, прочее — полным путём). Внутрь `body` не
/// спускается: это объект sing-box, его ключи ведёт ядро (тело цепочки
/// проверяет её разбор). Внутрь `identity` — тоже нет: неприменённые ключи
/// называет [_identityFromJson] одним предупреждением.
List<LxBackupWarning> _scanUnknown10(Map<String, dynamic> root) {
  final sc = _UnknownScan();

  sc.object('', root, _root10Keys);
  sc.nested(root, 'exported_by', _exportedByKeys);
  sc.nested(root, 'route', _routeKeys);

  final dns = _obj(root['dns']);
  if (dns != null) {
    sc.object('dns', dns, _dns10Keys);
    sc.array(dns, 'dns.servers', 'servers', _dnsServer10Keys, 'tag', null);
    sc.array(dns, 'dns.rules', 'rules', _dnsRule10Keys, 'name', null);
  }

  void sourceBody(String where, Map<String, dynamic> item) {
    sc.nestedAt(item, where, 'origin', _origin10Keys);
    sc.nestedAt(item, where, 'detour', _link10Keys);
    sc.nestedAt(item, where, 'tag_policy', _tagPolicy10Keys);
    sc.nestedAt(item, where, 'update', _update10Keys);
    sc.array(item, '$where.hops', 'hops', _link10Keys, 'tag', null);
    final group = _obj(item['group']);
    if (group != null) {
      sc.object('$where.group', group, _group10Keys);
      sc.array(
          group, '$where.group.members', 'members', _link10Keys, 'tag', null);
    }
    final fold = _obj(item['fold']);
    if (fold != null) {
      sc.object('$where.fold', fold, _fold10Keys);
      sc.nestedAt(fold, '$where.fold', 'auto', _directionAutoKeys);
    }
    final sections = _obj(item['sections']);
    if (sections != null) {
      final at = '$where.sections';
      sc.object(at, sections, _sections10Keys);
      sc.array(sections, '$at.rules', 'rules', _rule10Keys, 'name', null);
      final sdns = _obj(sections['dns']);
      if (sdns != null) {
        sc.object('$at.dns', sdns, _sectionsDns10Keys);
        sc.array(
            sdns, '$at.dns.servers', 'servers', _dnsServer10Keys, 'tag', null);
        sc.array(sdns, '$at.dns.rules', 'rules', _dnsRule10Keys, 'name', null);
      }
    }
  }

  sc.array(root, 'sources', 'sources', _source10Keys, 'tag', (where, item) {
    sourceBody(where, item);
    sc.array(item, '$where.nodes', 'nodes', _node10Keys, 'tag', sourceBody);
  });
  sc.array(
    root,
    'directions',
    'directions',
    _directionKeys,
    null,
    sc.directionBody,
  );
  sc.array(root, 'rules', 'rules', _rule10Keys, 'name', null);
  sc.array(root, 'warp', 'warp', _warpKeys, null, null);

  return sc.warnings();
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

  /// §438 — `id` подписки в файле → `id` подписки здесь. Ссылки `hops[]` и
  /// `detour` на узел подписки идут по этой карте (BACKUP.md §6).
  Map<String, String> ids,

  /// §438 — `id` заведённой подписки → её место в файле: слияние узлов
  /// ставит новые источники всех видов в порядке файла.
  Map<String, int> added,
});

/// §438 — `id` записи файла для НОВОЙ записи: берётся, если он есть, не занят
/// и годится в идентификатор, иначе свежий (BACKUP.md §9 п. 8: два источника
/// с одним `id` дали бы двух владельцев одной адресации). Форма ограничена:
/// `id` приходит из чужого файла, а в состоянии он служит ключом.
String _adoptSourceId(String fileId, Set<String> taken) {
  final id = fileId.isNotEmpty &&
          _sourceIdShape.hasMatch(fileId) &&
          !taken.contains(fileId)
      ? fileId
      : newUuidV4();
  taken.add(id);
  return id;
}

final RegExp _sourceIdShape = RegExp(r'^[A-Za-z0-9_-]{1,64}$');

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
/// §438 — у записи формата 1.0 ([LxSubscription.fullSettings]) отсутствие
/// интервала обновления значит умолчание, а не «оставь своё»: формат несёт
/// настройки подписки целиком (BACKUP.md §9 п. 1). Новая подписка берёт `id`
/// из файла, если он свободен.
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
  final takenIds = <String>{for (final l in merged) l.id};
  final ids = <String, String>{};
  final added = <String, int>{};
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
        updateIntervalHours: sub.updateIntervalHours ??
            (sub.fullSettings ? _defaultUpdateIntervalHours : null),
        enabled: sub.enabled,
        // `identity` — слепок целиком: объекта в файле НЕТ значит «настройка
        // сброшена в дефолт», а не «оставь как было». Иначе состояние без
        // override'а не переносилось бы вовсе.
        identity: sub.identity,
        clearIdentity: sub.identity == null,
      );
      if (sub.id.isNotEmpty) ids[sub.id] = existing.id;
      applied++;
      continue;
    }

    merged.add(SubscriptionServers(
      id: _adoptSourceId(sub.id, takenIds),
      name: sub.label,
      enabled: sub.enabled,
      tagPrefix: sub.tagPrefix,
      detourPolicy: DetourPolicy.defaults,
      url: sub.url,
      updateIntervalHours:
          sub.updateIntervalHours ?? _defaultUpdateIntervalHours,
      // §401 (D-083) — per-source identity: чем подписка представляется
      // провайдеру. Провайдеры ВЕТВЯТ выдачу по UA, и без переноса та же
      // ссылка отдала бы на новой машине другой набор узлов.
      identity: sub.identity,
      disabledHashes: {
        for (final e in sub.disabled.entries) e.key: at(e.value),
      },
    ));
    byUrl[sub.url] = merged.length - 1;
    if (sub.id.isNotEmpty) ids[sub.id] = merged.last.id;
    added[merged.last.id] = sub.position;
    applied++;
  }

  return (
    lists: merged,
    byUrl: byUrl,
    applied: applied,
    ids: ids,
    added: added,
  );
}

/// Умолчание интервала обновления подписки (`SubscriptionServers`).
const int _defaultUpdateIntervalHours = 24;

/// §438 — адрес узла в списке источников: индекс источника и индекс члена
/// папки (`-1` — сам источник, корневой узел).
typedef BackupNodeRef = ({int list, int member});

/// Результат слияния одиночных узлов и папок ([mergeBackupServers]).
typedef BackupServerMerge = ({
  /// Списки источников после слияния (порядок локальных сохранён, новые — в
  /// хвосте, в порядке файла).
  List<ServerList> lists,

  /// Сколько записей файла реально применилось.
  int applied,

  /// §438 — `id` контейнера в файле → `id` здесь: папки этого слияния и
  /// подписки из [mergeBackupSubscriptions] (`sourceIds`). Совпавший
  /// контейнер держит локальный `id`, заведённый — `id` из файла (если
  /// свободен). По карте переводятся ссылки `hops[]`/`detour` (BACKUP.md §6).
  Map<String, String> folderIds,

  /// §438 — узлы, которые импорт принёс или узнал по телу: их секции идут в
  /// общую перенумерацию оси ([renumberBackupAxis]).
  List<BackupNodeRef> touched,
});

/// §406 (D-095) — КАНОН ТЕЛА узла для дедупа при импорте.
///
/// Идентичности, кроме тела, у одиночной записи `servers[]` нет: `id`
/// локальный и в файле его не существует, `node_tag` вычисляется из тела.
/// Значит вопрос «этот узел у меня уже стоит?» решается сравнением тел — и
/// сравнивать их посимвольно нельзя: одна и та же нода, пересобранная другим
/// сериализатором, даёт другую строку и второй раз доливается в список.
///
/// Форма канона:
///
///  * **URI** — всё от первого `#` отрезается, затем `trim()`. Фрагмент это
///    ИМЯ узла, а не его тело: `vless://…#Berlin` и `vless://…#Берлин` — один
///    и тот же сервер под двумя подписями, и заводить его дважды не за что.
///  * **JSON-объект** — из верхнего уровня удаляются `tag` и `detour` (форма
///    identity-хеша, контракт D-007: `tag` — то же имя, `detour` — способ
///    дозвона, а не узел), остаток рекурсивно сортируется по ключам
///    ([deepSortKeys]) и печатается компактно. Перестановка ключей и разный
///    отступ больше не заводят двойника.
///  * **Многострочный текст** (WG-INI) — `trim()` как есть: `#` там начинает
///    комментарий строки, и отрезать по нему нельзя (BACKUP.md §9 п. 2). До
///    §438 текст резался по первому `#`, и конфиги с комментарием в начале
///    сливались в один.
///  * **Прочее** — `trim()` как есть.
///
/// Одна и та же функция канонизирует и приехавшее тело, и локальный
/// `rawBody`: сравнение имеет смысл, только когда обе стороны приведены к
/// одной форме.
String canonicalNodeBody(String body) {
  final t = body.trim();
  if (t.startsWith('{')) {
    final map = _tryDecodeObject(t);
    if (map != null) {
      final stripped = Map<String, dynamic>.from(map)
        ..remove('tag')
        ..remove('detour');
      return jsonEncode(deepSortKeys(stripped));
    }
    return t;
  }
  if (t.contains('\n')) return t;
  final hash = t.indexOf('#');
  return hash < 0 ? t : t.substring(0, hash).trim();
}

/// §401 (D-08x) + §405 + §438 — слияние узлов и папок файла с локальными
/// источниками. Чистая функция: состояние читает и пишет вызывающий.
///
/// **Папки.** У 0.x папка — имя в поле `folder` записи `servers[]`: записи с
/// одинаковым именем становятся одной папкой, «одно имя = одна папка». У 1.0
/// папка — своя запись ([folders]) с `id`, и ключ слияния двухступенчатый
/// (BACKUP.md §9 п. 3): сперва папка с тем же `id` (та же папка, как бы её
/// ни переименовали), затем по имени как есть — но только среди папок,
/// существовавших ДО импорта. Папка, заведённая этим же импортом, по имени
/// не находится: иначе вторая папка-тёзка файла дописалась бы в первую.
/// Совпавшая папка держит свой `id` и имя, а настройки (`enabled`, префикс
/// тегов) берёт из файла; настройки папки 0.x не трогает — их там нет.
///
/// **Узлы.** Идентичность узла — его ТЕЛО, приведённое к канону
/// ([canonicalNodeBody]): корневые дедупятся против корневых, члены — в
/// пределах своей папки (один сервер в двух папках законен). §405 —
/// совпавшее по телу пропускается МОЛЧА и `applied` не растёт, иначе
/// повторный импорт одного файла удваивал бы список. Порядок членов —
/// порядок записей файла; новые встают в конец.
///
/// **Секции** (§438, BACKUP.md §9 п. 2): у совпавшего по телу узла поле
/// `sections` в файле есть → замещает локальные секции целиком (включая
/// пустые); поля нет → свои остаются.
BackupServerMerge mergeBackupServers(
  List<ServerList> lists,
  List<LxServer> incoming, {
  List<LxFolder> folders = const [],
  Map<String, String> sourceIds = const {},
  Map<String, int> addedSources = const {},
}) {
  final merged = lists.toList();
  final takenIds = <String>{for (final l in merged) l.id};
  var applied = 0;
  final touched = <BackupNodeRef>[];
  // Заведённые этим импортом источники → место в файле (подписки приходят
  // уже заведёнными из [mergeBackupSubscriptions]).
  final added = <String, int>{...addedSources};

  // Папки по обоим ключам: первая победившая. Имена папок, заведённых этим
  // импортом из записи 1.0, по имени не находятся.
  final folderById = <String, int>{};
  final folderByName = <String, int>{};
  for (var i = 0; i < merged.length; i++) {
    final l = merged[i];
    if (l is! FolderServers) continue;
    folderById.putIfAbsent(l.id, () => i);
    folderByName.putIfAbsent(l.name, () => i);
  }

  // Первый проход по папкам файла — сопоставление и `id` заводимых, ДО
  // вставки: ссылка `detour` вправе метить в папку, объявленную ниже узла, и
  // карта `id` должна быть полной к моменту разбора любого узла.
  final folderIds = <String, String>{};
  final matchedAt = <String, int>{};
  final plannedId = <String, String>{};
  final freshNames = <String>{};
  final prefixById = <String, String>{
    for (final l in merged)
      if (l is! UserServer) l.id: l.tagPrefix,
  };
  for (final f in folders) {
    int? at;
    if (f.id.isNotEmpty) at = folderById[f.id];
    if (at == null && !freshNames.contains(f.name)) at = folderByName[f.name];
    final String localId;
    if (at != null) {
      matchedAt[f.key] = at;
      localId = merged[at].id;
    } else {
      localId = _adoptSourceId(f.id, takenIds);
      plannedId[f.key] = localId;
      if (!folderByName.containsKey(f.name)) {
        folderByName[f.name] = -1; // заведётся этим импортом
        freshNames.add(f.name);
      }
    }
    prefixById[localId] = f.tagPrefix;
    if (f.id.isNotEmpty) folderIds[f.id] = localId;
  }

  // Карта контейнеров для ссылок: подписки (из их слияния) и папки файла.
  final linkIds = {...sourceIds, ...folderIds};
  String detourOf(LxServer srv) => srv.detour == null
      ? ''
      : _linkConfigTag(srv.detour!, prefixById, linkIds);

  final singleBodies = <String, int>{};
  for (var i = 0; i < merged.length; i++) {
    final l = merged[i];
    if (l is UserServer) {
      singleBodies.putIfAbsent(canonicalNodeBody(l.rawBody), () => i);
    }
  }

  // Второй проход — ОДИН, в порядке файла: папка, её члены, корневые узлы.
  final folderPosition = {for (final f in folders) f.key: f.position};
  final events = <(int, int, int, Object)>[
    for (var i = 0; i < folders.length; i++)
      (folders[i].position, 0, i, folders[i]),
    for (var i = 0; i < incoming.length; i++)
      (
        incoming[i].folderRef.isNotEmpty
            ? (folderPosition[incoming[i].folderRef] ?? incoming[i].position)
            : incoming[i].position,
        1,
        i,
        incoming[i],
      ),
  ]..sort((a, b) {
      if (a.$1 != b.$1) return a.$1.compareTo(b.$1);
      if (a.$2 != b.$2) return a.$2.compareTo(b.$2);
      return a.$3.compareTo(b.$3);
    });

  final folderAtKey = <String, int>{};
  for (final (position, _, _, item) in events) {
    if (item is LxFolder) {
      final at = matchedAt[item.key];
      if (at != null) {
        final local = merged[at] as FolderServers;
        if (local.enabled != item.enabled || local.tagPrefix != item.tagPrefix) {
          merged[at] =
              local.copyWith(enabled: item.enabled, tagPrefix: item.tagPrefix);
          applied++;
        }
        folderAtKey[item.key] = at;
      } else {
        merged.add(FolderServers(
          id: plannedId[item.key]!,
          name: item.name,
          enabled: item.enabled,
          tagPrefix: item.tagPrefix,
          detourPolicy: DetourPolicy.defaults,
        ));
        folderAtKey[item.key] = merged.length - 1;
        if (folderByName[item.name] == -1) {
          folderByName[item.name] = merged.length - 1;
        }
        added[merged.last.id] = position;
        applied++;
      }
      continue;
    }

    final srv = item as LxServer;
    final body = srv.uri.isNotEmpty
        ? srv.uri
        : (srv.configJson == null ? '' : jsonEncode(srv.configJson));
    if (body.isEmpty) continue;

    if (srv.folderRef.isNotEmpty) {
      // Член папки 1.0: папка обработана раньше своих членов.
      final at = folderAtKey[srv.folderRef];
      if (at == null) continue;
      applied +=
          _mergeFolderMember(merged, at, srv, body, detourOf(srv), touched);
      continue;
    }

    if (srv.folder.isEmpty) {
      final key = canonicalNodeBody(body);
      final hit = singleBodies[key];
      if (hit != null) {
        if (srv.sectionsPresent) {
          final local = merged[hit] as UserServer;
          merged[hit] = local.copyWith(
            sections: srv.sections,
            clearSections: srv.sections == null,
          );
          applied++;
        }
        touched.add((list: hit, member: -1));
        continue;
      }
      merged.add(UserServer(
        id: _adoptSourceId(srv.id, takenIds),
        name: srv.name,
        enabled: srv.enabled,
        tagPrefix: '',
        detourPolicy:
            DetourPolicy.defaults.copyWith(overrideDetour: detourOf(srv)),
        origin: UserSource.manual,
        createdAt: DateTime.now(),
        rawBody: body,
        sections: srv.sections,
      ));
      singleBodies[key] = merged.length - 1;
      touched.add((list: merged.length - 1, member: -1));
      added[merged.last.id] = position;
      applied++;
      continue;
    }

    // Член папки 0.x: папка — имя. Заведённая им же папка находится по имени
    // (иначе каждая запись с тем же `folder` заводила бы новую).
    var at = folderByName[srv.folder];
    if (at == null || at < 0) {
      merged.add(FolderServers(
        id: _adoptSourceId('', takenIds),
        name: srv.folder,
        enabled: true,
        tagPrefix: '',
        detourPolicy: DetourPolicy.defaults,
      ));
      at = merged.length - 1;
      folderByName[srv.folder] = at;
      added[merged.last.id] = position;
    }
    applied += _mergeFolderMember(merged, at, srv, body, '', touched);
  }

  // Новые источники стоят в хвосте списка (подписки — первыми, их завело
  // слияние подписок); хвост упорядочивается по месту в файле, стабильно.
  final firstNew = merged.indexWhere((l) => added.containsKey(l.id));
  if (firstNew >= 0) {
    final order = [for (var i = firstNew; i < merged.length; i++) i]
      ..sort((a, b) {
        final byPos = added[merged[a].id]!.compareTo(added[merged[b].id]!);
        return byPos != 0 ? byPos : a.compareTo(b);
      });
    final remap = <int, int>{
      for (var k = 0; k < order.length; k++) order[k]: firstNew + k,
    };
    final tail = [for (final i in order) merged[i]];
    merged.replaceRange(firstNew, merged.length, tail);
    for (var t = 0; t < touched.length; t++) {
      final moved = remap[touched[t].list];
      if (moved != null) touched[t] = (list: moved, member: touched[t].member);
    }
  }

  return (
    lists: merged,
    applied: applied,
    folderIds: linkIds,
    touched: touched,
  );
}

/// Член папки [folderAt]: дедуп по канону тела в пределах этой папки, новые
/// в конец. Возвращает, сколько применилось (0 — узнан без секций файла).
int _mergeFolderMember(
  List<ServerList> merged,
  int folderAt,
  LxServer srv,
  String body,
  String detour,
  List<BackupNodeRef> touched,
) {
  final folder = merged[folderAt] as FolderServers;
  final canon = canonicalNodeBody(body);
  final hit = folder.members.indexWhere((m) => canonicalNodeBody(m.raw) == canon);
  if (hit >= 0) {
    touched.add((list: folderAt, member: hit));
    if (!srv.sectionsPresent) return 0;
    final members = folder.members.toList();
    members[hit] = members[hit].copyWith(
      sections: srv.sections,
      clearSections: srv.sections == null,
    );
    merged[folderAt] = folder.copyWith(members: members);
    return 1;
  }
  merged[folderAt] = folder.copyWith(members: [
    ...folder.members,
    FolderMember(
      raw: body,
      enabled: srv.enabled,
      detour: detour,
      sections: srv.sections,
    ),
  ]);
  touched.add((list: folderAt, member: folder.members.length));
  return 1;
}

/// §438 — позиции цепочек формата 1.0 → теги конфига LxBox.
///
/// Хоп 1.0 — ссылка `{folder_id?, tag}` с сырым тегом (BACKUP.md §4, §6), у
/// LxBox позиция — тег конфига. `folder_id` сперва переводится по карте
/// [folderIds] ([mergeBackupServers]), затем тег получает префикс найденного
/// контейнера — папки или подписки. Контейнера нет (ни в файле, ни здесь) —
/// хоп ввозится сырым тегом как есть: недостижимая позиция разбирается на
/// сборке (`chain_hop_missing`), а не импортом. У файла 0.x карты хопов нет,
/// и цепочки возвращаются как есть.
List<SourceChain> resolveBackupChainHops(
  LxBackupFile file,
  List<ServerList> lists,
  Map<String, String> folderIds,
) {
  if (file.chainHops.isEmpty) return file.chains;
  final prefixById = <String, String>{
    for (final l in lists)
      if (l is! UserServer) l.id: l.tagPrefix,
  };
  String hopTag(LxNodeLink link) => _linkConfigTag(link, prefixById, folderIds);

  return [
    for (final c in file.chains)
      if (file.chainHops[c.tag] case final links?)
        c.copyWith(hops: [for (final l in links) hopTag(l)])
      else
        c,
  ];
}

/// §438 — ссылка `{folder_id?, tag}` → тег конфига LxBox: префикс
/// контейнера (папки или подписки), найденного по карте [ids], плюс сырой
/// тег. Контейнера нет — сырой тег как есть (ссылка ввозится, недостижимую
/// цель разбирает сборка). [prefixById] — префиксы тегов контейнеров по
/// локальному `id`.
String _linkConfigTag(
  LxNodeLink link,
  Map<String, String> prefixById,
  Map<String, String> ids,
) {
  if (link.folderId.isEmpty) return link.tag;
  final prefix = prefixById[ids[link.folderId] ?? link.folderId];
  if (prefix == null) return link.tag;
  return TagResolver.displayTag(prefix, link.tag);
}

/// §438 — ось порядка импорта (BACKUP.md §9 п. 7, `NODE_SECTIONS.md` §5):
/// корневые правила [rules] и правила секций узлов [touched] на ОДНОЙ оси.
///
/// Номера у LxBox — свои, и относительный порядок обязан сохраниться; при
/// этом ось у сторон одна по раскладке шаблона (голова 0, пресеты 950–990,
/// пользовательская зона 1000–1100, широкие перехватчики 1110–1150), и
/// LxBox номер из файла сохраняет. Порядок правил от этого не меняется: он и
/// задан номерами, а при равных корневое правило стоит раньше узлового, как у
/// сборки. Перенумерация подряд от 1000 (так делает лаунчер) сохранила бы
/// порядок самого импорта, но у LxBox сломала бы то, что идёт после:
/// правило, добавленное руками, встаёт по `nextUserRuleNum` за максимум
/// пользовательской зоны — за бывшие перехватчики 1110+, — а пресет,
/// включённый позже со своим номером из шаблона (950–990), — перед бывшей
/// головой `traffic-processing`, и `sniff` перестаёт быть первым правилом.
/// v2.23.2 номера файла сохранял.
///
/// Неразмеченные корневые встают в хвост оси, в порядке файла: без номера
/// разметка при загрузке поставила бы их поверх размеченных. Правила секций
/// без номера остаются без него — сборка ставит их на 945.
///
/// Возвращает корневые правила в порядке оси; номера проставляются в тех же
/// объектах (как во всём §370).
List<CustomRule> renumberBackupAxis(
  List<CustomRule> rules,
  List<ServerList> lists,
  List<BackupNodeRef> touched,
) {
  var last = -1;
  void see(int? n) {
    if (n != null && n > last) last = n;
  }

  for (final r in rules) {
    see(r.orderNum);
  }
  final seen = <(int, int)>{};
  for (final ref in touched) {
    if (!seen.add((ref.list, ref.member))) continue;
    if (ref.list < 0 || ref.list >= lists.length) continue;
    final owner = lists[ref.list];
    final NodeSections? sections;
    if (ref.member < 0) {
      sections = owner is UserServer ? owner.sections : null;
    } else if (owner is FolderServers && ref.member < owner.members.length) {
      sections = owner.members[ref.member].sections;
    } else {
      sections = null;
    }
    for (final r in sections?.rules ?? const <CustomRule>[]) {
      see(r.orderNum ?? kNodeRuleDefaultNum);
    }
  }

  var next = last < 0 ? kDefaultRuleNum : last + 1;
  for (final r in rules) {
    r.orderNum ??= next++;
  }
  return sortRulesByAxis(rules);
}
