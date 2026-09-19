/// LX Backup v1 — переносимый формат обмена настройками с десктопным
/// лаунчером (SPEC 103, фаза 4). Подробности — в docstring ниже.
library;

import 'dart:convert';

import 'package:package_info_plus/package_info_plus.dart';

import '../config/consts.dart';
import '../models/auto_select.dart';
import '../models/codec/auto_group_record.dart';
import '../models/codec/chain_record.dart';
import '../models/codec/node_link_record.dart';
import '../models/codec/source_record.dart';
import '../models/core_reject_verdict.dart';
import '../models/custom_rule.dart';
import '../models/direction.dart';
import '../models/dns_ref.dart';
import '../models/import_rule.dart';
import '../models/node_link.dart';
import '../models/node_sections.dart';
import '../models/node_spec.dart' show AutoSelectSpec, NodeSpec;
import '../models/parser_config.dart' show kUserRuleNumStart;
import '../models/record_codec.dart';
import '../models/server_list.dart';
import '../models/source_chain.dart';
import 'core_reject/core_reject_backup.dart';
import 'lx_backup_slice.dart';
import 'node_link_address.dart';
import 'node_hash.dart' show deepSortKeys;
import 'parser/body_decoder.dart';
import 'parser/parse_all.dart';
import 'parser/uri_utils.dart' show newUuidV4;
import 'record_vars.dart';
import 'storage_migration/legacy_autogroup.dart';
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

/// §441 (SPEC 129 §5.6) — причины [kWarnVarSkipped] ([LxBackupWarning.reason]).
///
/// [kVarSkippedNotPortable] — корневая переменная вне реестра переносимых;
/// [kVarSkippedUndeclared] — имя в `vars` записи (`dns:<tag>` |
/// `preset:<ref>`), которого шаблон приёмника у носителя не объявил (Н2);
/// [kVarSkippedSuperseded] — корневое `dns_<tag>_<var>` при записи сервера со
/// своими `vars` (Н8); [kVarSkippedNoRecord] — корневое `dns_<tag>_<var>`,
/// а записи сервера с этим тегом в файле нет (Н8).
const String kVarSkippedNotPortable = 'not_portable';
const String kVarSkippedUndeclared = 'undeclared';
const String kVarSkippedSuperseded = 'superseded';
const String kVarSkippedNoRecord = 'no_record';

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
/// (BACKUP.md §3). Правило при этом цель находит — тег совпадает: он есть у
/// приёмника и входит в список известных целей ([lxImportKnownTargets]).
const String kWarnDirectionExists = 'backup_direction_exists';

/// §393 C9 — тег приехавшей цепочки уже занят на этой стороне (SPEC 110,
/// схема v1.2).
///
/// Тот же принцип, что у [kWarnDirectionExists], и та же причина предъявлять
/// его ВСЕГДА: у цепочки нет стабильного id, идентичность несёт только тег.
/// Молчаливое «своя победила» скрыло бы случай СЛУЧАЙНЫХ ТЁЗОК — двух
/// несвязанных маршрутов, одинаково названных на разных устройствах
/// (BACKUP.md §2). Приехавшая запись не применяется, своя остаётся; правило,
/// метящее в цепочку, цель находит — тег есть у приёмника, — она просто
/// чужая.
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
/// незнакомый `kind`, а у LxBox ещё члены папки `chain` — цепочка здесь
/// только корневой источник. Член папки `auto` — узел автовыбора (§439 N2).
/// [LxBackupWarning.kind] — вид записи. Запись не применяется.
const String kWarnSourceKindUnsupported = 'backup_source_kind_unsupported';

/// Контракт 1.0.1 — провайдерская группа (`kind: auto`) приехала в форме,
/// которую сторона не выражает, и ввезена упрощённой. Detail — тег группы,
/// [LxBackupWarning.reason] — что не выразилось. У LxBox — `selector`: группа
/// становится urltest, `default` отбрасывается ([kGroupDegradedSelector]).
const String kWarnGroupDegraded = 'backup_group_degraded';

/// Причина [kWarnGroupDegraded] у LxBox: selector читается urltest'ом.
const String kGroupDegradedSelector = 'selector→urltest, default dropped';

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

/// Зарезервированные литералы (BACKUP.md §3): существуют всегда, объявлять не
/// нужно. Служебные теги шаблона (`direct-out`, тег блокировки, outbound'ы и
/// endpoint'ы `config`) сюда не входят: их называет шаблон приёмника
/// ([lxImportKnownTargets], `systemTags`).
const Set<String> _reservedOutbounds = {
  'direct',
  'block',
  'reject',
  'drop',
  'dns-out',
};

/// D-117 — служебные теги приёмника, когда шаблона нет (корпус, разбор без
/// состояния): прямой канал и тег блокировки LxBox. У приёмника с шаблоном их
/// называет сам шаблон.
const Set<String> kLxImportDefaultSystemTags = {
  kDirectOutboundTag,
  kBlockOutboundTag,
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
    this.nodeWarnings = const {},
    this.identity,
    this.id = '',
    this.fullSettings = false,
    this.position = 0,
    this.detour,
    this.detourPolicy,
    this.importRules,
    this.importRulesEnabled,
    this.onUpdateAction,
  });

  /// §439 — общий `detour` подписки файла 1.0 (BACKUP.md §9 п. 1): ссылка как
  /// есть, тег конфига из неё получает слияние узлов ([mergeBackupServers]).
  /// У 0.x `null` и [fullSettings] ложно: своя ссылка остаётся.
  final NodeLink? detour;

  /// §439 Л2 — настройки LxBox записи 1.0, которые контракт объявил
  /// (`declared` в `lx_backup_slice.dart`) и которые в записи есть. `null` —
  /// поля в файле нет (сторона его не носит или контракт не объявил): у
  /// совпавшей подписки остаётся своё, у новой — умолчание.
  /// [detourPolicy] — флаги без ссылки: ссылка едет [detour].
  final DetourPolicy? detourPolicy;
  final List<ImportRule>? importRules;
  final bool? importRulesEnabled;
  final SubscriptionOnUpdateAction? onUpdateAction;

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

  /// Фича 478 / CANON §9.4 — вердикт ядра оверлеем тем же ключом, что и
  /// [disabled]: без него узел приехал бы выключенным без объяснения.
  /// Форма — `{identity: [{code, params}]}`, как в записи хранения.
  final Map<String, List<StoredWarning>> nodeWarnings;

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
    this.warnings = const [],
    this.folder = '',
    this.folderRef = '',
    this.id = '',
    this.sections,
    this.sectionsPresent = false,
    this.detour,
    this.position = 0,
    this.autoGroup,
    this.detourPolicy,
    this.tagPrefix,
  });

  /// §439 N2 — член папки 1.0 `kind: auto`: узел автовыбора со ссылками файла
  /// как есть (член `{tag}` уже поднят до пары с [folderRef]). Адрес здесь
  /// составу даёт слияние ([mergeBackupServers]). Текста у такого члена нет.
  final AutoSelectSpec? autoGroup;

  /// §439 Л2 — объявленные контрактом настройки LxBox корневого узла 1.0
  /// (флаги `detour_policy`, префикс `tag_policy`); `null` — поля в файле нет,
  /// см. [LxSubscription.detourPolicy]. У членов папки их нет.
  final DetourPolicy? detourPolicy;
  final String? tagPrefix;

  /// §438 — место корневой записи в `sources[]` файла 1.0 (см.
  /// [LxSubscription.position]); член папки идёт местом своей папки.
  final int position;

  /// §438 — личный detour узла 1.0 (`detour{folder_id?, tag}`): у LxBox это
  /// `overrideDetour` одиночного сервера и `detour` члена папки. Тег конфига
  /// из ссылки получает слияние ([mergeBackupServers]).
  final NodeLink? detour;

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

  /// Фича 478 / CANON §9.4 — вердикт ядра рядом с [enabled]: ручной сервер и
  /// член папки несут его списком записей `{code, params}`.
  final List<StoredWarning> warnings;

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
/// Применяются настройки, у которых в модели LxBox есть дом: `enabled`,
/// префикс `tag_policy` и общий `detour`. `postfix`, `fold`/`fold_tag` — поля
/// лаунчера (колонка «Поддержка» BACKUP.md §2), игнорируются молча.
class LxFolder {
  const LxFolder({
    required this.key,
    this.id = '',
    required this.name,
    this.enabled = true,
    this.tagPrefix = '',
    this.position = 0,
    this.detour,
    this.detourPolicy,
    this.pingUrl,
    this.pingTimeoutMs,
  });

  /// §439 — общий `detour` папки (BACKUP.md §9 п. 3): ссылка файла как есть.
  final NodeLink? detour;

  /// §439 Л2 — объявленные контрактом настройки LxBox папки 1.0 (флаги
  /// `detour_policy`, `ping_url`, `ping_timeout_ms`); `null` — поля в файле
  /// нет, см. [LxSubscription.detourPolicy].
  final DetourPolicy? detourPolicy;
  final String? pingUrl;
  final int? pingTimeoutMs;

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

/// §393 B9 — секция `dns` файла моделями DNS: записи 1.0 читает кодек
/// (`codec/dns_record.dart`), записи 0.12 — декодер 0.x.
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

  final List<DnsServerRef> servers;
  final List<DnsRuleRef> rules;

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
  final Map<String, List<NodeLink>> chainHops;

  /// §393 B9 — секция DNS; `null` = в файле её не было.
  final LxDns? dns;

  /// §393 B8 — записи `warp[]` в канонической форме схемы (дискриминатор
  /// `type: wg|masque`). Разбор в нативные модели — на стороне применения:
  /// парсер не должен знать про storage.
  final List<Map<String, dynamic>> warp;

  final Map<String, String> vars;

  /// `route.final` файла. У [decodeLxBackup] — как в файле; после
  /// [gateLxBackupTargets] — только известная цель, иначе `null`.
  final String? routeFinal;

  final List<LxBackupWarning> warnings;

  /// §441 — тот же файл с другими правилами и/или отчётом (план импорта
  /// дописывает предупреждения слияния DNS и нормализации пресетов).
  LxBackupFile copyWith({
    List<CustomRule>? rules,
    List<LxBackupWarning>? warnings,
  }) =>
      LxBackupFile(
        version: version,
        exportedByApp: exportedByApp,
        exportedByVersion: exportedByVersion,
        exportedAt: exportedAt,
        directions: directions,
        directionPing: directionPing,
        rules: rules ?? this.rules,
        chains: chains,
        chainHops: chainHops,
        subscriptions: subscriptions,
        servers: servers,
        folders: folders,
        dns: dns,
        warp: warp,
        vars: vars,
        routeFinal: routeFinal,
        warnings: warnings ?? this.warnings,
      );
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
/// §439 — файл = срез хранения плюс тонкий слой (BACKUP.md §1). Записи
/// `sources[]` (подписки, одиночные узлы и папки в порядке списка источников,
/// следом цепочки — так они лежат хвостом `sources[]` хранения) и `rules[]`
/// пишет кодек хранения (`models/codec/`); поля LxBox срезает таблица
/// `lx_backup_slice.dart`. Тонкий слой — `directions[]`, переносимые `vars`,
/// `route.final`, `warp[]` — той же формы, что в 0.12.
///
/// [directions] — Направления в порядке списка (§393 B2): они цели правил, и
/// без них правило приезжало бы на чужую машину выключенным.
///
/// [directionPing] — §409, бюджеты теста узла по тегу Направления
/// (`ping_options.groups`, §040). Пишутся только заданные половины.
///
/// [dns] — секция `dns` в форме файла (`dnsToBackup`); [warp] — записи
/// регистраций WG/MASQUE (§393 B8) уже в каноне схемы.
///
/// Ссылки на узлы (`hops[]` цепочки, `detour` источника и узла) едут так, как
/// лежат в записи хранения. Пока модели держат финальный тег строкой, это
/// корневая ссылка `{tag}`; ссылку без `folder_id` на член папки лаунчер
/// нормализует на импорте (BACKUP.md §6, ответ Л1).
///
/// Предупреждения: срезанные настройки LxBox — [kWarnLocalOnlyDropped], одно
/// на сущность (П6).
///
/// [recordVars] — §441, объявления шаблона этой стороны: `vars`
/// правил-пресетов нормализуются молча (SPEC 129 Н2–Н4). Секцию [dns]
/// нормализует `dnsToBackup` тем же набором.
Future<LxBackupExport> buildLxBackup({
  required List<ServerList> lists,
  required List<CustomRule> rules,
  required Map<String, String> vars,
  List<Direction> directions = const [],
  Map<String, LxDirectionPing> directionPing = const {},
  List<SourceChain> chains = const [],
  String? routeFinal,
  Map<String, dynamic>? dns,
  List<Map<String, dynamic>> warp = const [],
  RecordVarDecls recordVars = RecordVarDecls.none,
}) async {
  var appVersion = '';
  try {
    final info = await PackageInfo.fromPlatform();
    appVersion = '${info.version}+${info.buildNumber}';
  } catch (_) {
    // В тестовом окружении PackageInfo недоступен — версия не критична.
  }

  final warnings = <LxBackupWarning>[];
  final sources = <Map<String, dynamic>>[
    for (final list in lists) ?_exportSource(list, warnings),
    for (final c in chains)
      ?exportBackupRecord(BackupRecord.chain, chainToRecord(c), c.tag, warnings),
  ];

  final portableVars = <String, String>{
    for (final e in vars.entries)
      if (kLxPortableVars.contains(e.key)) e.key: e.value,
  };

  final ruleRecords = <Map<String, dynamic>>[];
  for (final r in normalizePresetRulesVars(rules, recordVars)) {
    final stored = ruleToRecord(r);
    // Правило вида json, чей текст объектом не разбирается: тела у записи
    // нет, и в 1.0 ей дома нет (массивы хранение уже разложило, §439 В2).
    if (r is CustomRuleJson && stored['body'] == null) {
      _noteLocalOnly(warnings, r.name, const ['json']);
      continue;
    }
    final record =
        exportBackupRecord(BackupRecord.rule, stored, r.name, warnings);
    if (record != null) ruleRecords.add(record);
  }

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
    if (dns != null && dns.isNotEmpty) 'dns': dns,
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

/// §439 — запись хранения → запись файла по таблице среза; срезанные
/// настройки, отличные от умолчания, называются одним
/// [kWarnLocalOnlyDropped] на [entity]. `null` — вид записи в 1.0 не пишется.
Map<String, dynamic>? exportBackupRecord(
  BackupRecord kind,
  Map<String, dynamic> stored,
  String entity,
  List<LxBackupWarning> warnings,
) {
  final slice = sliceBackupRecord(kind, stored);
  _noteLocalOnly(warnings, entity, slice.dropped);
  return slice.record;
}

/// Источник → запись `sources[]` файла: запись хранения, срез и `body`
/// узлов с JSON-исходником.
Map<String, dynamic>? _exportSource(
  ServerList list,
  List<LxBackupWarning> warnings,
) {
  final kind = switch (list) {
    SubscriptionServers() => BackupRecord.subscription,
    UserServer() => BackupRecord.server,
    FolderServers() => BackupRecord.folder,
  };
  final stored = sanitizeCoreRejectInBackupRecord(sourceToRecord(list), kind);
  final entity = switch (list) {
    SubscriptionServers s => s.name.isEmpty ? s.url : s.name,
    UserServer u =>
      _str(stored['tag']).isEmpty ? u.id : _str(stored['tag']),
    FolderServers f => f.name,
  };
  final record = exportBackupRecord(kind, stored, entity, warnings);
  if (record == null) return null;
  return switch (kind) {
    BackupRecord.server => _withJsonBody(record),
    BackupRecord.folder => {
        for (final e in record.entries)
          e.key: e.key == 'nodes' && e.value is List
              ? [
                  for (final n in e.value as List)
                    // Член без текста — пустая строка папки: переносить
                    // нечего (хранение держит его `unsupported` без исходника).
                    // Член-группа текста не имеет и едет записью (§439 N2).
                    if (n is Map &&
                        (n['kind'] == kNodeKindAuto || _hasSourceText(n)))
                      _withJsonBody(n.cast<String, dynamic>()),
                ]
              : e.value,
      },
    _ => record,
  };
}

bool _hasSourceText(Map<dynamic, dynamic> node) {
  final origin = node['origin'];
  return origin is Map && _str(origin['raw']).trim().isNotEmpty;
}

/// §439 §4.1 — узел с JSON-исходником из одного outbound несёт и `body`:
/// объект sing-box без `tag` и `detour` (BACKUP.md §2), сразу за `origin`.
/// Материализованное тело URI/WG-INI не пишется: принимающая сторона берёт
/// исходник (BACKUP.md §9 п. 2), а второй эмиттер тел разошёлся бы со
/// сборкой. Истина узла — текст (В1).
Map<String, dynamic> _withJsonBody(Map<String, dynamic> node) {
  final origin = node['origin'];
  if (origin is! Map || origin['kind'] != 'json') return node;
  final obj = _tryDecodeObject(_str(origin['raw']).trim());
  if (obj == null ||
      obj['type'] is! String ||
      obj.containsKey('outbounds') ||
      obj.containsKey('endpoints')) {
    return node;
  }
  return {
    for (final e in node.entries) ...{
      e.key: e.value,
      if (e.key == 'origin')
        'body': {
          for (final b in obj.entries)
            if (b.key != 'tag' && b.key != 'detour') b.key: b.value,
        },
    },
  };
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

/// Разбирает LX Backup и сверяет цели правил и `route.final` без состояния
/// приёмника: известные цели — [knownOutbounds] плюс то, что приехало файлом
/// ([lxImportKnownTargets]). Импорт в приложение идёт не сюда, а через план
/// `planLxBackupImport` (`lx_backup_import.dart`): там список считается после
/// слияния, с узлами и шаблоном приёмника (D-117).
///
/// [knownOutbounds] — имена, которые приёмник знает сам (они же заняты для
/// Направлений файла); пустой набор при файле без целей означает «проверять
/// нечем» — тогда ссылки не режутся.
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
  RecordVarDecls recordVars = RecordVarDecls.none,
}) {
  final file = decodeLxBackup(
    raw,
    takenTags: knownOutbounds,
    knownPresets: knownPresets,
    knownChains: knownChains,
    recordVars: recordVars,
  );
  return gateLxBackupTargets(
    file,
    lxImportKnownTargets(
      directions: file.directions,
      chainTags: {for (final c in file.chains) c.tag},
      receiverTargets: {...knownOutbounds, ...knownChains},
    ),
  );
}

/// Декодер LX Backup без проверки целей: записи файла в промежуточную форму,
/// пресет вне шаблона — выключен. Цели правил и `route.final` сверяет
/// [gateLxBackupTargets] одним списком после слияния (BACKUP.md §3, D-117):
/// до слияния декодер не знает ни узлов результата, ни шаблона приёмника.
///
/// [takenTags] — теги, занятые у приёмника: Направление файла под таким тегом
/// не применяется (`backup_direction_exists`).
///
/// [recordVars] — §441, объявления переменных записей шаблона приёмника:
/// корневые `dns_<tag>_<var>` переносятся в записи серверов файла (Н8),
/// template-сервер DNS с тегом, которого шаблон не объявил, не ввозится
/// ([kWarnDnsEntrySkipped]). [RecordVarDecls.none] — шаблона нет: корневые
/// имена идут общим правилом `vars`, теги серверов не сверяются.
LxBackupFile decodeLxBackup(
  String raw, {
  Set<String> takenTags = const {},
  Set<String> knownPresets = const {},
  Set<String> knownChains = const {},
  RecordVarDecls recordVars = RecordVarDecls.none,
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
      takenTags: takenTags,
      knownPresets: knownPresets,
      knownChains: knownChains,
      recordVars: recordVars,
    );
  }
  return _parse0x(
    decoded,
    version,
    takenTags: takenTags,
    knownPresets: knownPresets,
    knownChains: knownChains,
    recordVars: recordVars,
  );
}

/// Декодер семейства 0.x (`lx_backup: 1`).
LxBackupFile _parse0x(
  Map<String, dynamic> decoded,
  int version, {
  required Set<String> takenTags,
  required Set<String> knownPresets,
  required Set<String> knownChains,
  required RecordVarDecls recordVars,
}) {
  // §401 — default-deny на ВСЮ глубину файла, а не только на корень:
  // вложенный уровень — самое удобное место спрятать чужое поле. Упразднённый
  // `extensions` при этом отделён от прочего незнакомого: он не «лишний
  // ключ», а карман с произвольным содержимым (эталон —
  // `core/backup/file.go:scanUnknown`).
  final warnings = _scanUnknown(decoded);

  final directions = _parseDirections(decoded, takenTags, warnings);

  // §393 C9 — цепочки (SPEC 110, схема v1.2): ПОСЛЕ Направлений (позиция
  // может ссылаться на Направление). Порядок записей файла сохраняется как
  // есть.
  //
  // Занятый тег — тот же код-путь, что и дубль ВНУТРИ файла: набор
  // `takenChainTags` общий, поэтому first-wins по порядку файла, а вторая
  // запись с тем же тегом получает `backup_chain_exists` наравне с тёзкой
  // локальной цепочки.
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
    if (!takenChainTags.add(tag)) {
      warnings.add(LxBackupWarning(kWarnChainExists, tag));
      continue;
    }
    chains.add(_chainFromCanon(j, tag));
  }

  final rules = <CustomRule>[
    for (final item in (decoded['rules'] as List? ?? const []))
      if (item is Map)
        ..._ruleFromJson(
          item.cast<String, dynamic>(),
          knownPresets,
          warnings,
        ),
  ];

  // Порядок разбора секций = порядок предупреждений в превью: переменные,
  // `warp[]`, затем записи источников и DNS; цели правил и `route.final`
  // дописывает в конец [gateLxBackupTargets].
  //
  // §441 — DNS читается раньше переменных (Н8 переносит корневые
  // `dns_<tag>_<var>` в записи серверов файла), но его предупреждения встают
  // на прежнее место — после записей источников.
  final dnsWarnings = <LxBackupWarning>[];
  final dnsRaw = _dnsFromJson(
    (decoded['dns'] as Map?)?.cast<String, dynamic>(),
    dnsWarnings,
    recordVars,
  );
  final parsedVars =
      _parseVars(decoded, warnings, dns: dnsRaw, recordVars: recordVars);
  final routeFinal = _parseRouteFinal(decoded);
  final warp = _parseWarp(decoded, warnings);
  final subscriptions = [
    for (final s in (decoded['subscriptions'] as List? ?? const []))
      if (s is Map) _subscriptionFromJson(s.cast<String, dynamic>(), warnings),
  ];
  final servers = _legacyAutogroups0x([
    for (final s in (decoded['servers'] as List? ?? const []))
      if (s is Map) _serverFromJson(s.cast<String, dynamic>(), warnings),
  ], warnings);
  warnings.addAll(dnsWarnings);

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
    subscriptions: subscriptions,
    servers: servers,
    dns: parsedVars.dns,
    warp: warp,
    vars: parsedVars.vars,
    routeFinal: routeFinal,
    warnings: warnings,
  );
}

/// Направления файла и то, что они дают остальному разбору.
typedef _ParsedDirections = ({
  List<Direction> directions,
  Map<String, LxDirectionPing> ping,
});

/// §393 B1 — Направления файла. Форма `directions[]` у 0.x и 1.0 одна (тонкий
/// слой, BACKUP.md §1), поэтому и разбор один. Их теги — известные цели
/// правил (BACKUP.md §3): список считает [lxImportKnownTargets] после слияния.
///
/// Занятый тег — не ошибка файла: у пользователя под этим именем своё
/// Направление со своими настройками. Приехавшее не применяется (warning),
/// но цель под этим тегом у приёмника есть — правило её находит.
_ParsedDirections _parseDirections(
  Map<String, dynamic> decoded,
  Set<String> takenTags,
  List<LxBackupWarning> warnings,
) {
  final directions = <Direction>[];
  // §409 — бюджеты теста узла применённых Направлений (`ping_options.groups`).
  final directionPing = <String, LxDirectionPing>{};
  // §406 (D-095) — занятость тега определяется ТОЧНЫМ совпадением, как при
  // создании Направления руками (`directionTagConflict`). `VPN-DE` при живом
  // `vpn-de` — не тёзка, а второе Направление: для ядра это два разных
  // outbound'а, и объявлять одно из них «уже существующим» значило бы молча
  // потерять приехавшую запись.
  final taken = <String>{
    for (final t in takenTags) t.trim(),
  };
  final items = decoded['directions'];
  for (final item in (items is List ? items : const [])) {
    if (item is! Map) continue;
    final j = item.cast<String, dynamic>();
    final rawTag = j['tag'];
    final tag = rawTag is String ? rawTag.trim() : '';
    if (tag.isEmpty) continue; // без тега Направление не адресуемо
    if (!taken.add(tag)) {
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
  );
}

/// `vars` — только переносимые имена (обе формы одинаковы).
///
/// §441 (SPEC 129 Н8) — корневое имя вне реестра разрешается против
/// объявлений шаблона приёмника ([rootDnsVarTarget]: объявленные пары
/// `(tag, var)`, выигрывает самый длинный тег) и переносится в запись
/// template-сервера ФАЙЛА до слияния:
///
///  * кандидата нет — [kVarSkippedNotPortable], как раньше;
///  * у записи в файле свои непустые `vars` — побеждает запись,
///    [kVarSkippedSuperseded];
///  * запись есть, `vars` пуст — значение уходит в `vars` записи (Н2–Н4 —
///    на слиянии, против шаблона приёмника);
///  * записи с этим тегом в файле нет — [kVarSkippedNoRecord].
///
/// Правило одно на файлы 1.0 и 0.x. «Пуст» — `vars` записи, как прочитан
/// файл: два корневых имени одного сервера переносятся оба. Пустое значение
/// переносить нечего (Н3).
({Map<String, String> vars, LxDns? dns}) _parseVars(
  Map<String, dynamic> decoded,
  List<LxBackupWarning> warnings, {
  LxDns? dns,
  RecordVarDecls recordVars = RecordVarDecls.none,
}) {
  final vars = <String, String>{};
  final raw = decoded['vars'];
  final rawVars = raw is Map ? raw.cast<String, dynamic>() : const {};
  final servers = dns?.servers.toList();
  // Теги template-записей файла со своими `vars` — как прочитан файл.
  final ownVars = <String>{
    for (final s in servers ?? const <DnsServerRef>[])
      if (s is DnsServerTemplate && s.varValues.isNotEmpty) s.tag,
  };
  var lifted = false;
  for (final key in rawVars.keys.toList()..sort()) {
    if (kLxPortableVars.contains(key)) {
      vars[key] = '${rawVars[key]}';
      continue;
    }
    final target = rootDnsVarTarget(key, recordVars);
    if (target == null) {
      warnings.add(LxBackupWarning(kWarnVarSkipped, key,
          reason: kVarSkippedNotPortable));
      continue;
    }
    final at = servers == null
        ? -1
        : servers.indexWhere(
            (s) => s is DnsServerTemplate && s.tag == target.tag);
    if (at < 0) {
      warnings.add(LxBackupWarning(kWarnVarSkipped, key,
          reason: kVarSkippedNoRecord));
      continue;
    }
    if (ownVars.contains(target.tag)) {
      warnings.add(LxBackupWarning(kWarnVarSkipped, key,
          reason: kVarSkippedSuperseded));
      continue;
    }
    final value = rawVars[key];
    final text = value == null ? '' : '$value'.trim();
    if (text.isEmpty) continue;
    final record = servers![at] as DnsServerTemplate;
    servers[at] = record.copyWith(
        varValues: {...record.varValues, target.varName: text});
    lifted = true;
  }
  return (
    vars: vars,
    dns: !lifted || dns == null
        ? dns
        : LxDns(
            servers: servers!,
            rules: dns.rules,
            finalServer: dns.finalServer,
            strategy: dns.strategy,
            defaultDomainResolver: dns.defaultDomainResolver,
          ),
  );
}

/// `route.final` файла как есть. Применяется только при известной цели
/// (BACKUP.md §3) — сверяет [gateLxBackupTargets] после слияния.
String? _parseRouteFinal(Map<String, dynamic> decoded) {
  final route = decoded['route'];
  final finalTag = route is Map ? route['final'] : null;
  if (finalTag is! String || finalTag.isEmpty) return null;
  return finalTag;
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
  'warnings',
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

  /// §441 (Л5) — `vars` DNS-сервера 1.0 — поле только `kind: template`. У
  /// `user` и `preset` ключ не применяется (кодек его не читает) и называется
  /// как незнакомый. Запись чужого вида отбрасывает [_dns10] целиком — её
  /// ключи не называются.
  void dnsServer10Body(String where, Map<String, dynamic> item) {
    final kind = item['kind'];
    if ((kind == 'user' || kind == 'preset') && item.containsKey('vars')) {
      _note(where, 'vars');
    }
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
  j = sanitizeCoreRejectInBackupRecord(j, BackupRecord.subscription);
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
    nodeWarnings: storedWarningsMapFromJson(j['warnings']),
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

  _noteIdentityDropped(
    [
      for (final k in j.keys)
        if (!_identityAppliedKeys.contains(k)) k,
    ],
    where,
    warnings,
  );

  return SubscriptionIdentityOverride(
    userAgent: (j['user_agent'] as String?) ?? '',
    sendHwid: (j['send_hwid'] as bool?) ?? false,
    hwid: (j['hwid'] as String?) ?? '',
    deviceOs: (j['device_os'] as String?) ?? '',
    verOs: (j['ver_os'] as String?) ?? '',
    deviceModel: (j['device_model'] as String?) ?? '',
  );
}

/// Неприменённые ключи `identity` — ОДНИМ [kWarnSourceIdentityDropped] на
/// подписку: сначала ключи схемы в её порядке, затем чужие по алфавиту, чтобы
/// два импорта одного файла давали один и тот же перечень. Общий для входов
/// 0.x и 1.0.
void _noteIdentityDropped(
  Iterable<String> keys,
  String where,
  List<LxBackupWarning> warnings,
) {
  final set = keys.toSet();
  final ordered = [
    for (final k in _identityKeyOrder)
      if (set.contains(k)) k,
    ...(set.where((k) => !_identityKeyOrder.contains(k)).toList()..sort()),
  ];
  if (ordered.isEmpty) return;
  warnings.add(LxBackupWarning(
    kWarnSourceIdentityDropped,
    '$where: ${ordered.join(', ')}',
  ));
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

/// §439 N2 — член папки 0.x с текстом `autogroup://…` → узел автовыбора тем
/// же путём, что миграция хранения (`legacy_autogroup.dart`): разбор текста
/// снят, и без перевода член лёг бы нечитаемым рядом с группой. Явный состав —
/// ключи `protocol|server|port|credential` — сопоставляется с членами той же
/// папки файла и становится ссылками `{tag}` на их имена (`node_tag`); адрес
/// здесь им даёт слияние ([mergeBackupServers]). Член, который не нашёлся
/// или неоднозначен, снимается с [kWarnGroupDegraded]. Нечитаемый текст
/// остаётся членом как есть.
List<LxServer> _legacyAutogroups0x(
  List<LxServer> servers,
  List<LxBackupWarning> warnings,
) {
  if (!servers.any((s) => s.folder.isNotEmpty && isLegacyAutogroupText(s.uri))) {
    return servers;
  }
  final byFolder = <String, List<int>>{};
  for (var i = 0; i < servers.length; i++) {
    final folder = servers[i].folder;
    if (folder.isNotEmpty) (byFolder[folder] ??= []).add(i);
  }
  final out = servers.toList();
  byFolder.forEach((folder, indexes) {
    final members = [for (final i in indexes) servers[i]];
    final nodes = <NodeSpec?>[
      for (final m in members)
        isLegacyAutogroupText(m.uri) ? null : FolderMember(raw: _body0x(m)).node,
    ];
    for (var k = 0; k < members.length; k++) {
      final m = members[k];
      if (!isLegacyAutogroupText(m.uri)) continue;
      final read = legacyAutogroupSpec(
        m.uri,
        nodes: nodes,
        enabledAt: (i) => members[i].enabled,
        linkOf: (i, tag) =>
            NodeLink(tag: members[i].name.isNotEmpty ? members[i].name : tag),
      );
      if (read == null) continue;
      for (final problem in read.dropped) {
        warnings.add(LxBackupWarning(
          kWarnGroupDegraded,
          read.group.tag,
          reason: 'member $problem, dropped',
        ));
      }
      out[indexes[k]] = LxServer(
        autoGroup: read.group,
        name: read.group.tag,
        enabled: m.enabled,
        folder: folder,
        position: m.position,
      );
    }
  });
  return out;
}

/// Текст записи 0.x для разбора члена: URI или `config_json` строкой.
String _body0x(LxServer s) => s.uri.isNotEmpty
    ? s.uri
    : (s.configJson == null ? '' : jsonEncode(s.configJson));

/// §393 B9 — секция `dns` файла 0.12 → модели DNS.
///
/// Канон знает три происхождения (`template|preset|user`), модель LxBox —
/// своё имя пользовательской записи (`inline`) и ещё `srs` у правил.
///
/// §401 — запись, которой в каноне места нет, ОТБРАСЫВАЕТСЯ с
/// [kWarnDnsEntrySkipped], а не хранится сырой до следующего экспорта: карман
/// провоза упразднён (П3), и держать её в состоянии значило бы завести
/// состояние-призрак, которого пользователь не видит. Ссылка без адреса и
/// пользовательская запись без тела применить нечем — пропуск молча, как
/// всегда делало слияние 0.x.
LxDns? _dnsFromJson(
  Map<String, dynamic>? j,
  List<LxBackupWarning> warnings,
  RecordVarDecls recordVars,
) {
  if (j == null) return null;

  final servers = <DnsServerRef>[];
  for (final item in (j['servers'] as List? ?? const [])) {
    if (item is! Map) continue;
    final e = item.cast<String, dynamic>();
    final kind = (e['kind'] as String?) ?? '';
    if (!_dns0xKinds.contains(kind)) {
      warnings.add(
        LxBackupWarning(kWarnDnsEntrySkipped, 'dns.servers: kind=${e['kind']}'),
      );
      continue;
    }
    final server = _dnsServer0x(e, kind);
    if (server == null) continue;
    if (!_templateServerDeclared(server, recordVars)) {
      warnings.add(LxBackupWarning(
          kWarnDnsEntrySkipped, 'dns.servers: template:${server.tag}'));
      continue;
    }
    servers.add(server);
  }

  final rules = <DnsRuleRef>[];
  for (final item in (j['rules'] as List? ?? const [])) {
    if (item is! Map) continue;
    final e = item.cast<String, dynamic>();
    final kind = (e['kind'] as String?) ?? '';
    if (!_dns0xKinds.contains(kind)) {
      warnings.add(
        LxBackupWarning(kWarnDnsEntrySkipped, 'dns.rules: kind=${e['kind']}'),
      );
      continue;
    }
    if (_dnsRule0x(e, kind) case final rule?) rules.add(rule);
  }

  return LxDns(
    servers: servers,
    rules: rules,
    finalServer: (j['final'] as String?) ?? '',
    strategy: (j['strategy'] as String?) ?? '',
  );
}

/// Виды DNS-записи канона 0.12.
const Set<String> _dns0xKinds = {'template', 'preset', 'user'};

/// Запись `dns.servers[]` 0.12 (`name`, `ref`, `value`) → модель. preset
/// адресуется `ref` = `<preset_id>:<tag>`, а у старых файлов — именем; ссылка
/// делится по ПЕРВОМУ `:`.
DnsServerRef? _dnsServer0x(Map<String, dynamic> e, String kind) {
  final name = _str(e['name']);
  final enabled = e['enabled'] is bool ? e['enabled'] as bool : true;
  switch (kind) {
    case 'user':
      final value = e['value'];
      if (name.isEmpty || value is! Map) return null;
      return DnsServerInline(
        enabled: enabled,
        tag: name,
        body: {...value.cast<String, dynamic>()}..remove('tag'),
      );
    case 'preset':
      final ref = _str(e['ref']).isNotEmpty ? _str(e['ref']) : name;
      final at = ref.indexOf(':');
      final tag = at < 0 ? ref : ref.substring(at + 1);
      if (tag.isEmpty) return null;
      return DnsServerPreset(
        enabled: enabled,
        tag: tag,
        presetId: at < 0 ? '' : ref.substring(0, at),
      );
    default:
      if (name.isEmpty) return null;
      // §441 — `vars` ссылки 0.12 (`DNSRef.Vars`): значения переменных
      // template-сервера, как у записи 1.0.
      final vars = e['vars'];
      return DnsServerTemplate(
        enabled: enabled,
        tag: name,
        varValues: vars is Map
            ? {
                for (final v in vars.entries)
                  if (v.value != null) v.key.toString(): v.value.toString(),
              }
            : const {},
      );
  }
}

/// §441 (SPEC 129 §5.2) — template-сервер DNS, которого шаблон приёмника не
/// объявил, не ввозится: собрать его тело не из чего. Шаблона нет
/// ([RecordVarDecls.none]) — сверять не с чем, запись идёт как есть.
bool _templateServerDeclared(DnsServerRef server, RecordVarDecls recordVars) =>
    server is! DnsServerTemplate ||
    recordVars.dnsServers.isEmpty ||
    recordVars.dnsServers.containsKey(server.tag);

/// Запись `dns.rules[]` 0.12 → модель: `user` — тело `value`, `preset` —
/// `ref`, `template` — имя.
DnsRuleRef? _dnsRule0x(Map<String, dynamic> e, String kind) {
  final name = _str(e['name']);
  final enabled = e['enabled'] is bool ? e['enabled'] as bool : true;
  switch (kind) {
    case 'user':
      final value = e['value'];
      if (value is! Map) return null;
      return DnsRuleInline(
        name: name,
        rule: value.cast<String, dynamic>(),
        enabled: enabled,
      );
    case 'preset':
      final ref = _str(e['ref']);
      return ref.isEmpty ? null : DnsRulePreset(presetId: ref, enabled: enabled);
    default:
      return name.isEmpty
          ? null
          : DnsRuleTemplate(name: name, enabled: enabled);
  }
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
  // Канон разбирается кодеком цепочки: второй разбор тех же полей разошёлся
  // бы с ним на первой же правке (трёхзначный `strip_evasion`, порядок
  // каталога `strip`, `null` внутри `rewrite`). Позиции 0.12 — строки.
  final label = j['label'];
  final enabled = j['enabled'];
  return chainFromRecord({
    'kind': kSourceKindChain,
    'tag': tag,
    if (label is String) 'label': label,
    // Отсутствие ключа = true (`enabled.default` схемы). В ожиданиях корпуса
    // ключа нет вовсе, и читать его отсутствие как false значило бы
    // импортировать выключенными все цепочки лаунчера.
    if (enabled is bool) 'enabled': enabled,
    'body': {
      for (final e in canon.entries)
        if (e.key != 'hops') e.key: e.value,
    },
    'hops': [
      for (final h in (canon['hops'] is List ? canon['hops'] as List : const []))
        if (h is String) h,
    ],
  }).value!;
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
  return _reservedOutbounds.contains(t) || known.contains(t);
}

/// §441 (SPEC 129 Н9) — известна ли цель [tag] списку [known]
/// ([lxImportKnownTargets]) с зарезервированными литералами: та же проверка,
/// что у целей правил, для маршрута DNS-серверов.
bool lxIsKnownImportTarget(String tag, Set<String> known) =>
    _isKnownOutbound(tag, known);

/// D-117 — корневые имена результата импорта (BACKUP.md §3, NODE_LINK §8):
/// служебные теги шаблона приёмника ([systemTags]; без шаблона —
/// [kLxImportDefaultSystemTags]), теги Направлений и `-auto` тех, у кого есть
/// автовыбор, теги цепочек. Свёрток у LxBox нет.
///
/// [directions] и [chainTags] — то, что окажется у приёмника после слияния:
/// его собственные записи и приехавшие, прошедшие гейт тегов. Запись файла,
/// отсеянная гейтом, целью не становится: её тег либо уже есть у приёмника,
/// либо служебный и Направлению не положен.
///
/// Это часть списка известных целей ([lxImportKnownTargets]), которая
/// известна ДО слияния узлов: её получает подъём ссылок
/// ([mergeBackupServers], `rootNames`), а корневые узлы результата он
/// добавляет сам тем же [lxImportRootNodeTags].
Set<String> lxImportRootNames({
  Iterable<Direction> directions = const [],
  Iterable<String> chainTags = const [],
  Set<String> systemTags = const {},
}) {
  final names = <String>{};
  void add(String tag) {
    final t = tag.trim();
    if (t.isNotEmpty) names.add(t);
  }

  (systemTags.isEmpty ? kLxImportDefaultSystemTags : systemTags).forEach(add);
  for (final d in directions) {
    if (d.tag.trim().isEmpty) continue;
    add(d.tag);
    // Двойник эмитится только у Направления с автовыбором
    // (`build_config.dart`, `emitAuto`): цель без него — ссылка в никуда.
    if (d.auto != null) add(d.autoTag);
  }
  chainTags.forEach(add);
  return names;
}

/// Теги корневых узлов [lists] — одиночных серверов, под которыми узел
/// эмитится (префикс сервера + тег узла, [containerFinalForm]).
Set<String> lxImportRootNodeTags(List<ServerList> lists) => {
      for (final l in lists)
        if (l is UserServer)
          // Сервер, заведённый этим импортом, узлов ещё не разобрал: они в тексте.
          for (final n in l.nodes.isNotEmpty ? l.nodes : _nodesOf(l.rawBody))
            if (n.tag.isNotEmpty) containerFinalForm(l, n.tag),
    };

/// D-117 — ЕДИНСТВЕННЫЙ список известных целей импорта (BACKUP.md §3): цели
/// правил (`backup_unknown_outbound`), `route.final`
/// (`backup_final_dropped`) и корневые имена подъёма ссылок.
///
/// Считается ПОСЛЕ слияния, по тому, что окажется у приёмника:
/// [lxImportRootNames] (служебные теги шаблона, Направления и их `-auto`,
/// цепочки), корневые узлы результата [lists], имена, которые приёмник знает
/// сам ([receiverTargets]), и зарезервированные литералы.
///
/// Раньше списков было два: экран строил его из хранения приёмника ДО
/// слияния, декодер дописывал теги файла, и ни один не видел `-auto`,
/// корневых узлов файла и служебных тегов шаблона — импорт в пустое состояние
/// выключал правила на цели, приехавшие этим же файлом.
///
/// `null` — «проверять нечем»: ни шаблона, ни Направлений, ни цепочек, ни
/// узлов, ни имён приёмника. Тогда цели не режутся — выключить всё подряд
/// хуже, чем импортировать как есть; умолчания служебных тегов такой список не
/// открывают.
Set<String>? lxImportKnownTargets({
  Iterable<Direction> directions = const [],
  Iterable<String> chainTags = const [],
  List<ServerList> lists = const [],
  Set<String> systemTags = const {},
  Set<String> receiverTargets = const {},
}) {
  final rootNodes = lxImportRootNodeTags(lists);
  final receiver = {
    for (final t in receiverTargets)
      if (t.trim().isNotEmpty) t.trim(),
  };
  if (systemTags.isEmpty &&
      directions.every((d) => d.tag.trim().isEmpty) &&
      chainTags.every((t) => t.trim().isEmpty) &&
      rootNodes.isEmpty &&
      receiver.isEmpty) {
    return null;
  }
  return {
    ..._reservedOutbounds,
    ...lxImportRootNames(
      directions: directions,
      chainTags: chainTags,
      systemTags: systemTags,
    ),
    ...rootNodes,
    ...receiver,
  };
}

/// Цель правила так, как её называет файл: `outbound` правила inline/srs
/// (`reject` у отказа), `outbound` тела правила вида json. У пресета цели
/// нет — она из шаблона. Пустая строка — цели нет, проверять нечего.
String _ruleTarget(CustomRule r) => switch (r) {
      CustomRuleInline(:final outbound) => outbound,
      CustomRuleSrs(:final outbound) => outbound,
      CustomRulePreset() => '',
      CustomRuleJson(:final json) => switch (_tryDecodeObject(json.trim())) {
          {'outbound': final String o} => o,
          _ => '',
        },
    };

/// D-117 — цели правил и `route.final` файла против списка известных целей
/// [known] ([lxImportKnownTargets]). Один проход на оба формата файла.
///
/// Правило с целью, которой нет, приезжает ВЫКЛЮЧЕННЫМ с
/// [kWarnUnknownOutbound], а не теряется: включённое правило с несуществующей
/// целью роняет конфиг ядра целиком. `route.final` в никуда не применяется
/// ([kWarnFinalDropped]): маршрут по умолчанию уводил бы весь трафик в
/// несуществующий outbound. `known == null` — проверять нечем, файл как есть.
///
/// Возвращает новый [LxBackupFile]: правила в том же порядке, предупреждения
/// дописаны в конец отчёта в порядке правил.
LxBackupFile gateLxBackupTargets(LxBackupFile file, Set<String>? known) {
  if (known == null) return file;
  final warnings = [...file.warnings];
  final rules = <CustomRule>[];
  for (final r in file.rules) {
    final target = _ruleTarget(r);
    if (target.isEmpty || _isKnownOutbound(target, known)) {
      rules.add(r);
      continue;
    }
    warnings.add(LxBackupWarning(kWarnUnknownOutbound,
        '${r.name.isEmpty ? r.kind.name : r.name} → $target'));
    rules.add(r.withEnabled(false));
  }
  var routeFinal = file.routeFinal;
  if (routeFinal != null &&
      routeFinal.isNotEmpty &&
      !_isKnownOutbound(routeFinal, known)) {
    warnings.add(LxBackupWarning(kWarnFinalDropped, routeFinal));
    routeFinal = null;
  }
  return LxBackupFile(
    version: file.version,
    exportedByApp: file.exportedByApp,
    exportedByVersion: file.exportedByVersion,
    exportedAt: file.exportedAt,
    directions: file.directions,
    directionPing: file.directionPing,
    rules: rules,
    chains: file.chains,
    chainHops: file.chainHops,
    subscriptions: file.subscriptions,
    servers: file.servers,
    folders: file.folders,
    dns: file.dns,
    warp: file.warp,
    vars: file.vars,
    routeFinal: routeFinal,
    warnings: warnings,
  );
}

/// Запись схемы → правила LxBox (вид `json` — по записи на тело, D-111).
///
/// Цель здесь не сверяется: ссылку в никуда выключает [gateLxBackupTargets]
/// после слияния.
List<CustomRule> _ruleFromJson(
  Map<String, dynamic> j,
  Set<String> knownPresets,
  List<LxBackupWarning> warnings,
) {
  final kindName = (j['kind'] as String?) ?? '';
  final name = (j['name'] as String?) ?? '';
  if (kindName == 'json') {
    return _jsonRule0x(j, name, warnings);
  }
  final enabled = (j['enabled'] as bool?) ?? true;
  final rawNum = j['num'];
  final orderNum = rawNum is num ? rawNum.toInt() : null;
  final outbound = (j['outbound'] as String?) ?? '';

  final rule = _ruleBodyFromJson(
    j,
    kindName,
    name,
    enabled,
    orderNum,
    outbound,
    knownPresets,
    warnings,
  );
  return rule == null ? const [] : [rule];
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
      // `vars` схемы — значения переменных пресета (`varsValues` модели).
      final vars = j['vars'];
      return CustomRulePreset(
        name: name,
        enabled: enabled,
        orderNum: orderNum,
        presetId: ref,
        varsValues: vars is Map
            ? {
                for (final e in vars.entries)
                  if (e.key is String)
                    e.key as String: e.value?.toString() ?? '',
              }
            : const {},
      );

    case 'srs':
      return CustomRuleSrs(
        name: name,
        enabled: enabled,
        orderNum: orderNum,
        // `ref` — первый набор; ## 12 — `refs` главнее `ref`.
        srsUrl: _str(j['ref']),
        srsUrls: _strList(j['refs']),
        outbound: outbound,
        dns: RuleDns.fromJson(j['dns']),
        resolve: RuleResolve.fromJson(j['resolve']),
      );

    default:
      warnings.add(
        LxBackupWarning(kWarnUnknownField, 'rules[].kind=$kindName'),
      );
      return null;
  }
}

/// §439 (D-111) — сырое правило `kind: json` формата 0.x: тело в `match`,
/// объект или массив тел. Процедура одна с записью 1.0 ([_splitRuleBodies]);
/// каждая часть — правило вида json с телом как есть (у LxBox это запись
/// `inline` + `verbatim`, сборка кладёт тело в конфиг без переписи). Тело не
/// объект и не массив — запись отбрасывается с [kWarnUnknownField].
List<CustomRule> _jsonRule0x(
  Map<String, dynamic> j,
  String name,
  List<LxBackupWarning> warnings,
) {
  final match = j['match'];
  if (match is! Map && match is! List) {
    warnings.add(
      LxBackupWarning(kWarnUnknownField, 'rules[].kind=json: $name'),
    );
    return const [];
  }
  final record = <String, dynamic>{
    'kind': 'inline',
    'name': name,
    if (j['enabled'] is bool) 'enabled': j['enabled'],
    if (j['num'] is num) 'num': j['num'],
    'verbatim': true,
  };
  return [
    for (final part in _splitRuleBodies(
        record, match is Map ? [match] : match, 'rules[$name].match', warnings))
      ?ruleFromRecord(part).value,
  ];
}

List<String> _strList(Object? v) {
  if (v is List) return [for (final e in v) '$e'];
  return const [];
}

// ---------------------------------------------------------------------------
// §438/§439 — декодер формата 1.0 (`lx_backup: 2`).
//
// Записи файла 1.0 — записи состояния, и разбирает их кодек хранения
// (`models/codec/`): источники — `sourceFromRecord`, цепочки —
// `chainFromRecord`, правила и DNS — свои кодеки записей. Поля LxBox, которых
// контракт не объявил, сняты до кодека (`stripUndeclaredBackupFields`): их
// назвал обход неизвестных ключей. Итог — те же промежуточные записи, что даёт
// декодер 0.x ([LxSubscription], [LxServer], [LxFolder], [SourceChain],
// [CustomRule], [LxDns]), слияние дальше одно на оба формата.
//
// Разбор терпим к типам: ключ чужого типа не роняет файл (П6), а читается
// как отсутствующий.
// ---------------------------------------------------------------------------

String _str(Object? v) => v is String ? v : '';

String _trimmed(Object? v) => v is String ? v.trim() : '';

Map<String, dynamic>? _obj(Object? v) =>
    v is Map ? v.cast<String, dynamic>() : null;

List<Object?> _list(Object? v) => v is List ? v : const [];

/// `id` для кодека у записи файла без `id`: кодек хранения без него запись не
/// читает, а импорт такую запись принимает (новой записи `id` выдаст слияние).
const String _kNoFileId = '\u0000';

/// Ссылка `{folder_id?, tag}` файла; пустой тег — ссылки нет.
NodeLink? _link10(Object? raw) {
  final link = nodeLinkFromRecord(raw);
  return link == null || link.tag.isEmpty ? null : link;
}

/// Как назвать запись `sources[]` пользователю: адрес подписки, иначе имя,
/// иначе тег (эталон — `source10Label` лаунчера).
String _source10Label(Map<String, dynamic> j) {
  final url = _trimmed(j['url']);
  if (url.isNotEmpty) return url;
  final name = _trimmed(j['name']);
  if (name.isNotEmpty) return name;
  return _trimmed(j['tag']);
}

/// Запись источника для кодека хранения: без не объявленных контрактом полей
/// LxBox и с `id` (см. [_kNoFileId]).
Map<String, dynamic> _sourceForCodec(
  BackupRecord kind,
  Map<String, dynamic> j,
  String fileId, {
  Map<String, dynamic> override = const {},
}) =>
    {
      ...stripUndeclaredBackupFields(kind, j),
      ...override,
      'id': fileId.isEmpty ? _kNoFileId : fileId,
    };

/// §439 Л2 — есть ли в записи файла поле LxBox, которое контракт объявил:
/// только такое поле применяется, его отсутствие оставляет значение
/// приёмника. Необъявленное снято до кодека и не применяется никогда.
bool _carries(BackupRecord kind, Map<String, dynamic> j, String key) =>
    j.containsKey(key) && declaredBackupKeys(kind).contains(key);

/// Флаги политики detour без ссылки (ссылка едет полем `detour`).
DetourPolicy _flagsOf(DetourPolicy p) => p.copyWith(overrideDetour: NodeLink.none);

LxBackupFile _parse10(
  Map<String, dynamic> decoded, {
  required Set<String> takenTags,
  required Set<String> knownPresets,
  required Set<String> knownChains,
  required RecordVarDecls recordVars,
}) {
  final warnings = _scanUnknown10(decoded);

  final parsedDirections = _parseDirections(decoded, takenTags, warnings);

  final subscriptions = <LxSubscription>[];
  final servers = <LxServer>[];
  final folders = <LxFolder>[];
  final chains = <SourceChain>[];
  final chainHops = <String, List<NodeLink>>{};
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
        final folder = _folder10(j, i);
        folders.add(folder);
        for (final rawNode in _list(j['nodes'])) {
          final node = _obj(rawNode);
          if (node == null) continue;
          final member = _folderMember10(node, folder, warnings);
          if (member != null) servers.add(member);
        }
      case 'chain':
        final tag = _trimmed(j['tag']);
        // Безымянная цепочка не адресуема: пропуск молча, как в 0.x.
        if (tag.isEmpty) continue;
        _dropForeignSections(j, kind, warnings);
        if (!takenChainTags.add(tag)) {
          warnings.add(LxBackupWarning(kWarnChainExists, tag));
          continue;
        }
        final chain = _chain10(j, tag, warnings);
        if (chain == null) continue;
        chains.add(chain.chain);
        chainHops[tag] = chain.hops;
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

  final rules = <CustomRule>[
    for (final item in _list(decoded['rules']))
      if (_obj(item) case final j?) ..._rule10(j, knownPresets, warnings),
  ];

  // §441 — DNS раньше переменных (Н8), предупреждения — на прежнем месте.
  final dnsWarnings = <LxBackupWarning>[];
  final dnsRaw =
      _dns10(decoded['dns'], knownPresets, dnsWarnings, recordVars);
  final parsedVars =
      _parseVars(decoded, warnings, dns: dnsRaw, recordVars: recordVars);
  final vars = parsedVars.vars;
  final routeFinal = _parseRouteFinal(decoded);
  final warp = _parseWarp(decoded, warnings);
  warnings.addAll(dnsWarnings);
  final dns = parsedVars.dns;

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

/// Узел `kind: server` (корневой или член папки) → [LxServer] кодеком
/// хранения.
///
/// Тело для дедупа и хранения — ИСХОДНИК (`origin.raw`), материализованное
/// `body` — только у узла без исходника (BACKUP.md §9 п. 2). Исходник `json`
/// и тело без исходника получают тег записи: у LxBox имя узла читается из его
/// JSON, а тег записи и есть идентичность. Текст URI и WG-INI едет как есть:
/// имя у share-ссылки в разных схемах лежит в разных местах, и переписывать
/// его импорт не берётся.
///
/// Секции узла читает кодек; отбраковка по норме B3 называется с причиной у
/// каждой записи. `detour` — ссылка файла как есть: тег конфига из неё
/// получает слияние по карте контейнеров ([mergeBackupServers]).
LxServer? _server10(
  Map<String, dynamic> j,
  List<LxBackupWarning> warnings, {
  LxFolder? folder,
  int position = 0,
}) {
  j = sanitizeCoreRejectInBackupRecord(
    j,
    folder == null ? BackupRecord.server : BackupRecord.folderNode,
  );
  final tag = _trimmed(j['tag']);
  final origin = _obj(j['origin']);
  final hasOrigin = _str(origin?['raw']).trim().isNotEmpty;
  final drops = <NodeSectionDrop>[];
  final fileId = folder == null ? _trimmed(j['id']) : '';
  final read = sourceFromRecord(
    _sourceForCodec(
      folder == null ? BackupRecord.server : BackupRecord.folderNode,
      // Пустой исходник читается как его отсутствие: тело берётся из `body`.
      hasOrigin ? j : ({...j}..remove('origin')),
      fileId,
      override: const {'kind': kSourceKindServer},
    ),
    sectionDrops: drops,
  );
  final node = read.value;
  if (node is! UserServer) return null;
  final raw = node.rawBody;
  if (raw.trim().isEmpty) return null;

  var uri = '';
  Map<String, dynamic>? configJson;
  final obj = hasOrigin && _str(origin?['kind']) != 'json'
      ? null
      : _tryDecodeObject(raw.trim());
  if (obj != null) {
    configJson = {...obj, if (tag.isNotEmpty) 'tag': tag};
  } else {
    // `uri`, `wg_ini`, будущие виды и нечитаемый json — текст как есть.
    uri = raw;
  }

  for (final d in drops) {
    warnings.add(LxBackupWarning(
      kWarnSectionRecordDropped,
      '$tag: ${d.text}',
      kind: d.kind,
      reason: d.reason,
    ));
  }
  final root = folder == null;
  return LxServer(
    detour: _link10(j['detour']),
    detourPolicy: root && _carries(BackupRecord.server, j, 'detour_policy')
        ? _flagsOf(node.detourPolicy)
        : null,
    tagPrefix: root && _carries(BackupRecord.server, j, 'tag_policy')
        ? node.tagPrefix
        : null,
    uri: uri,
    configJson: configJson,
    name: tag,
    enabled: node.enabled,
    warnings: storedWarningsFromJson(j['warnings']),
    folder: folder?.name ?? '',
    folderRef: folder?.key ?? '',
    position: position,
    id: fileId,
    sections: node.sections,
    sectionsPresent: j.containsKey('sections'),
  );
}

/// Член папки 1.0. `server` — узел; `unsupported` с исходником — у LxBox
/// есть дом: нечитаемый член папки хранит текст и виден в списке (§234);
/// `auto` — узел автовыбора кодеком хранения (§439 N2, `selector` читается
/// urltest'ом с [kWarnGroupDegraded]); `chain` папка LxBox не держит —
/// [kWarnSourceKindUnsupported].
LxServer? _folderMember10(
  Map<String, dynamic> node,
  LxFolder folder,
  List<LxBackupWarning> warnings,
) {
  final kind = _str(node['kind']);
  final tag = _trimmed(node['tag']);
  switch (kind) {
    case 'server':
      return _server10(node, warnings, folder: folder);
    case kNodeKindAuto:
      _dropForeignSections(node, kind, warnings);
      final read = autoGroupMemberFromRecord(
        stripUndeclaredBackupFields(BackupRecord.folderNode, node),
        folderId: folder.key,
        where: '${folder.name}: $tag',
      );
      final group = read.member.node! as AutoSelectSpec;
      if (read.fromSelector) {
        warnings.add(LxBackupWarning(
          kWarnGroupDegraded,
          group.tag,
          reason: kGroupDegradedSelector,
        ));
      }
      return LxServer(
        autoGroup: group,
        name: group.tag,
        enabled: read.member.enabled,
        folder: folder.name,
        folderRef: folder.key,
      );
    case 'unsupported':
      final raw = _str(_obj(node['origin'])?['raw']);
      if (raw.trim().isNotEmpty) {
        _dropForeignSections(node, kind, warnings);
        return LxServer(
          uri: raw,
          name: tag,
          enabled: node['enabled'] is bool ? node['enabled'] as bool : true,
          folder: folder.name,
          folderRef: folder.key,
        );
      }
  }
  warnings.add(LxBackupWarning(
    kWarnSourceKindUnsupported,
    '${folder.name}: ${tag.isEmpty ? kind : tag}',
    kind: kind,
  ));
  return null;
}

/// Подписка 1.0 кодеком хранения. Применяется то, у чего у LxBox есть дом:
/// имя, `enabled`, префикс `tag_policy`, интервал `update`, `disabled`,
/// `identity`, `detour`. Поля лаунчера (`postfix`, `fold`/`fold_tag`, `skip`,
/// `max_nodes`, `relays_in_directions`, `update.auto_refresh`) игнорируются
/// молча (BACKUP.md §1, колонка «Поддержка»).
LxSubscription _subscription10(
  Map<String, dynamic> j,
  int position,
  List<LxBackupWarning> warnings,
) {
  j = sanitizeCoreRejectInBackupRecord(j, BackupRecord.subscription);
  final fileId = _trimmed(j['id']);
  final read = sourceFromRecord(
      _sourceForCodec(BackupRecord.subscription, j, fileId));
  final sub = read.value! as SubscriptionServers;
  bool carries(String key) => _carries(BackupRecord.subscription, j, key);
  _noteIdentityDropped(
    [
      for (final k in read.unknownKeys)
        if (k.startsWith('identity.')) k.substring('identity.'.length),
    ],
    _source10Label(j),
    warnings,
  );
  return LxSubscription(
    id: fileId,
    url: sub.url,
    label: sub.name,
    enabled: sub.enabled,
    tagPrefix: sub.tagPrefix,
    updateIntervalHours: sub.updateIntervalHours,
    disabled: {
      for (final e in sub.disabledHashes.entries)
        e.key: e.value.millisecondsSinceEpoch ~/ 1000,
    },
    nodeWarnings: sub.nodeWarnings,
    identity: sub.identity,
    detour: _link10(j['detour']),
    detourPolicy: carries('detour_policy') ? _flagsOf(sub.detourPolicy) : null,
    importRules: carries('import_rules') ? sub.importRules : null,
    importRulesEnabled:
        carries('import_rules_enabled') ? sub.importRulesEnabled : null,
    onUpdateAction: carries('on_update_action') ? sub.onUpdateAction : null,
    fullSettings: true,
    position: position,
  );
}

/// Папка 1.0 кодеком хранения: `id`, имя, `enabled`, префикс `tag_policy`,
/// общий `detour`. Состав разбирается узлами ([_folderMember10]).
LxFolder _folder10(Map<String, dynamic> j, int position) {
  final fileId = _trimmed(j['id']);
  final read = sourceFromRecord(_sourceForCodec(
    BackupRecord.folder,
    j,
    fileId,
    override: const {'nodes': <Object?>[]},
  ));
  final folder = read.value! as FolderServers;
  bool carries(String key) => _carries(BackupRecord.folder, j, key);
  return LxFolder(
    position: position,
    // Члены ссылаются на папку ключом, а не именем: в файле бывают тёзки.
    // У записи без `id` ключ — номер записи с префиксом, которого у
    // настоящего `id` не бывает.
    key: fileId.isNotEmpty ? fileId : '\u0000$position',
    id: fileId,
    // Имя папки сравнивается как есть (BACKUP.md §9 п. 3): без подрезки.
    name: folder.name,
    enabled: folder.enabled,
    tagPrefix: folder.tagPrefix,
    detour: _link10(j['detour']),
    detourPolicy: carries('detour_policy') ? _flagsOf(folder.detourPolicy) : null,
    pingUrl: carries('ping_url') ? folder.pingUrl : null,
    pingTimeoutMs: carries('ping_timeout_ms') ? folder.pingTimeoutMs : null,
  );
}

/// Цепочка 1.0 кодеком хранения: настройки маршрута из `body`, позиции —
/// ссылками файла (в теги конфига их переводит [resolveBackupChainHops]).
/// Ключ тела, которого модель не держит, — [kWarnUnknownField]: тело
/// типизировано моделью, и провезти его некуда.
({SourceChain chain, List<NodeLink> hops})? _chain10(
  Map<String, dynamic> j,
  String tag,
  List<LxBackupWarning> warnings,
) {
  final read = chainFromRecord(
    {...stripUndeclaredBackupFields(BackupRecord.chain, j), 'tag': tag},
  );
  final chain = read.value;
  if (chain == null) return null;
  for (final key in read.unknownKeys) {
    if (key.startsWith('body.')) {
      warnings.add(LxBackupWarning(kWarnUnknownField, 'sources[$tag].$key'));
    }
  }
  return (
    chain: chain,
    hops: [
      for (final h in _list(j['hops'])) ?nodeLinkFromRecord(h),
    ],
  );
}

/// §439 (D-111, BACKUP.md §2 «Одно правило — одно тело») — запись правила,
/// у которой на месте тела ([body]) массив, раскладывается на записи по
/// элементу-объекту в порядке массива, как если бы массив был развёрнут в
/// файле подряд: имена `name`, `name #2`… по порядку получившихся записей
/// (безымянная остаётся безымянной), `enabled` общий, `id` только у первой.
/// `num` общий: номера файла LxBox сохраняет ([renumberBackupAxis]), и
/// стабильная сортировка оси держит части подряд на месте исходной записи.
///
/// Элемент не объект — [kWarnUnknownField] ([where] называет место), прочие
/// части идут. Пустой массив — запись отбрасывается тем же кодом. Не массив —
/// запись как есть.
List<Map<String, dynamic>> _splitRuleBodies(
  Map<String, dynamic> record,
  Object? body,
  String where,
  List<LxBackupWarning> warnings,
) {
  if (body is! List) return [record];
  final name = _str(record['name']);
  final parts = <Map<String, dynamic>>[];
  for (var i = 0; i < body.length; i++) {
    final item = body[i];
    if (item is! Map) {
      warnings.add(
          LxBackupWarning(kWarnUnknownField, '$where[$i]: not an object'));
      continue;
    }
    parts.add({
      for (final e in record.entries)
        if (e.key != 'id' || parts.isEmpty) e.key: e.value,
      'name': parts.isEmpty || name.isEmpty ? name : '$name #${parts.length + 1}',
      'body': item.cast<String, dynamic>(),
    });
  }
  if (body.isEmpty) {
    warnings.add(LxBackupWarning(kWarnUnknownField, '$where: empty array'));
  }
  return parts;
}

/// Правило 1.0 → правила LxBox через кодек записей (массив тел — D-111).
///
/// `inline` с ключами тела, которых типизированное правило не держит
/// (`method: drop`, самостоятельный `action`, незнакомый матчер), переносится
/// видом json — телом целиком, без потерь: вырезать ключ значило бы изменить
/// смысл правила (норма B3). `rule_set` в теле (наборы едут `refs[]`) и
/// `srs` с незнакомым ключом дома не имеют — запись отбрасывается целиком с
/// [kWarnUnknownField].
List<CustomRule> _rule10(
  Map<String, dynamic> j,
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
    return const [];
  }
  final record = stripUndeclaredBackupFields(BackupRecord.rule, j);
  return [
    for (final part in _splitRuleBodies(
        record, record['body'], 'rules[$label].body', warnings))
      ?_ruleRecord10(part, kind, knownPresets, warnings),
  ];
}

CustomRule? _ruleRecord10(
  Map<String, dynamic> j,
  String kind,
  Set<String> knownPresets,
  List<LxBackupWarning> warnings,
) {
  final name = _str(j['name']);
  final ref = _str(j['ref']);
  final label = name.isNotEmpty ? name : (ref.isNotEmpty ? ref : kind);
  final read = ruleFromRecord(j, unknownAsVerbatim: true);
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

  if (read.unknownKeys.isNotEmpty) {
    if (kind != 'inline' || read.unknownKeys.contains('rule_set')) {
      warnings.add(LxBackupWarning(
        kWarnUnknownField,
        'rules[$label].body: ${read.unknownKeys.join(', ')}',
      ));
      return null;
    }
    // `dns`/`resolve` — поля LxBox у типизированного правила; у правила вида
    // json им места нет, и молча они не теряются.
    for (final key in const ['dns', 'resolve']) {
      if (j[key] is Map && (j[key] as Map).isNotEmpty) {
        warnings.add(LxBackupWarning(kWarnUnknownField, 'rules[$label].$key'));
      }
    }
  }
  return rule;
}

/// DNS-секция 1.0 → [LxDns] кодеком записей.
///
/// Серверы: `user` (тело без `tag`), `template` (ссылка тегом), `preset`
/// (ссылка `ref`, тега нет). Правила: `user` (тело с `server`) и `preset`.
/// Прочее — [kWarnDnsEntrySkipped], как у 0.x. Ключи, которых таблица среза
/// не знает, сняты до кодека; `vars` и `description` сервера объявлены
/// контрактом и читаются. §441 — template-сервер с тегом, которого шаблон
/// приёмника не объявил, — тоже [kWarnDnsEntrySkipped].
LxDns? _dns10(
  Object? raw,
  Set<String> knownPresets,
  List<LxBackupWarning> warnings,
  RecordVarDecls recordVars,
) {
  final j = _obj(raw);
  if (j == null) return null;

  final servers = <DnsServerRef>[];
  for (final item in _list(j['servers'])) {
    final e = _obj(item);
    if (e == null) continue;
    final kind = _str(e['kind']);
    final read = (kind == 'user' || kind == 'template' || kind == 'preset')
        ? dnsServerFromRecord(
            stripUndeclaredBackupFields(BackupRecord.dnsServer, e))
        : null;
    final server = read?.value;
    if (server == null) {
      warnings.add(LxBackupWarning(
        kWarnDnsEntrySkipped,
        'dns.servers: ${read?.dropped ?? 'kind=$kind'}',
      ));
      continue;
    }
    // Пресет, которого в шаблоне этой стороны нет, применить нечем.
    if (server is DnsServerPreset &&
        server.presetId.isNotEmpty &&
        knownPresets.isNotEmpty &&
        !knownPresets.contains(server.presetId)) {
      warnings.add(LxBackupWarning(
          kWarnDnsEntrySkipped, 'dns.servers: ${_trimmed(e['ref'])}'));
      continue;
    }
    if (!_templateServerDeclared(server, recordVars)) {
      warnings.add(LxBackupWarning(
          kWarnDnsEntrySkipped, 'dns.servers: template:${server.tag}'));
      continue;
    }
    servers.add(server);
  }

  final rules = <DnsRuleRef>[];
  for (final item in _list(j['rules'])) {
    final e = _obj(item);
    if (e == null) continue;
    final kind = _str(e['kind']);
    // Виды LxBox (`srs`, `template`) читаются, только когда контракт их
    // объявит (таблица среза).
    final readable = kind == 'user' ||
        kind == 'preset' ||
        ((kind == 'srs' || kind == 'template') &&
            backupKindTravels(BackupRecord.dnsRule, kind));
    final read = readable
        ? dnsRuleFromRecord(stripUndeclaredBackupFields(BackupRecord.dnsRule, e))
        : null;
    switch (read?.value) {
      case final DnsRulePreset rule
          when knownPresets.isNotEmpty && !knownPresets.contains(rule.presetId):
        warnings.add(LxBackupWarning(
          kWarnDnsEntrySkipped,
          'dns.rules: ${_str(e['ref'])}',
        ));
      case final DnsRuleRef rule:
        rules.add(rule);
      case null:
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
// §439 — к ним добавляются поля LxBox, объявленные контрактом (флаг Л2 таблицы
// среза `lx_backup_slice.dart`).

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
  'warnings',
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
  // Поля стороны LxBox (контракт 1.0.1).
  'members_rule',
  'pool_badge',
};
const Set<String> _membersRule10Keys = {'include', 'exclude'};
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

  final sourceKeys = {
    ..._source10Keys,
    ...declaredBackupKeys(BackupRecord.subscription),
    ...declaredBackupKeys(BackupRecord.server),
    ...declaredBackupKeys(BackupRecord.folder),
    ...declaredBackupKeys(BackupRecord.chain),
  };
  final nodeKeys = {
    ..._node10Keys,
    ...declaredBackupKeys(BackupRecord.folderNode),
  };
  final ruleKeys = {..._rule10Keys, ...declaredBackupKeys(BackupRecord.rule)};
  final dnsServerKeys = {
    ..._dnsServer10Keys,
    ...declaredBackupKeys(BackupRecord.dnsServer),
  };
  final dnsRuleKeys = {
    ..._dnsRule10Keys,
    ...declaredBackupKeys(BackupRecord.dnsRule),
  };

  sc.object('', root, _root10Keys);
  sc.nested(root, 'exported_by', _exportedByKeys);
  sc.nested(root, 'route', _routeKeys);

  final dns = _obj(root['dns']);
  if (dns != null) {
    sc.object('dns', dns, _dns10Keys);
    sc.array(dns, 'dns.servers', 'servers', dnsServerKeys, 'tag',
        sc.dnsServer10Body);
    sc.array(dns, 'dns.rules', 'rules', dnsRuleKeys, 'name', null);
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
      sc.nestedAt(group, '$where.group', 'strategy', _directionAutoKeys);
      sc.nestedAt(group, '$where.group', 'members_rule', _membersRule10Keys);
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
      sc.array(sections, '$at.rules', 'rules', ruleKeys, 'name', null);
      final sdns = _obj(sections['dns']);
      if (sdns != null) {
        sc.object('$at.dns', sdns, _sectionsDns10Keys);
        sc.array(sdns, '$at.dns.servers', 'servers', dnsServerKeys, 'tag',
            sc.dnsServer10Body);
        sc.array(sdns, '$at.dns.rules', 'rules', dnsRuleKeys, 'name', null);
      }
    }
  }

  sc.array(root, 'sources', 'sources', sourceKeys, 'tag', (where, item) {
    sourceBody(where, item);
    sc.array(item, '$where.nodes', 'nodes', nodeKeys, 'tag', sourceBody);
  });
  sc.array(
    root,
    'directions',
    'directions',
    _directionKeys,
    null,
    sc.directionBody,
  );
  sc.array(root, 'rules', 'rules', ruleKeys, 'name', null);
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

  /// §439 — `id` подписки здесь → общий `detour` из файла 1.0 (`null` — снять
  /// свой). Тег конфига из ссылки получает слияние узлов, когда известна карта
  /// контейнеров ([mergeBackupServers], `sourceDetours`). Подписок 0.x в
  /// карте нет: их ссылка остаётся своей.
  Map<String, NodeLink?> detours,
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
  final detours = <String, NodeLink?>{};
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
        // §439 Л2 — объявленные настройки LxBox: приехали — применяются, нет
        // в файле — свои (сторона их не носит). Ссылку detour ставит слияние
        // узлов по [detours].
        detourPolicy: sub.detourPolicy?.copyWith(
            overrideDetour: existing.detourPolicy.overrideDetour),
        importRules: sub.importRules,
        importRulesEnabled: sub.importRulesEnabled,
        onUpdateAction: sub.onUpdateAction,
      );
      if (sub.id.isNotEmpty) ids[sub.id] = existing.id;
      if (sub.fullSettings) detours[existing.id] = sub.detour;
      applied++;
      continue;
    }

    merged.add(SubscriptionServers(
      id: _adoptSourceId(sub.id, takenIds),
      name: sub.label,
      enabled: sub.enabled,
      tagPrefix: sub.tagPrefix,
      detourPolicy: sub.detourPolicy ?? DetourPolicy.defaults,
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
      nodeWarnings: sub.nodeWarnings,
      importRules: sub.importRules ?? const [],
      importRulesEnabled: sub.importRulesEnabled ?? true,
      onUpdateAction: sub.onUpdateAction ?? SubscriptionOnUpdateAction.rebuild,
    ));
    byUrl[sub.url] = merged.length - 1;
    if (sub.id.isNotEmpty) ids[sub.id] = merged.last.id;
    if (sub.detour != null) detours[merged.last.id] = sub.detour;
    added[merged.last.id] = sub.position;
    applied++;
  }

  return (
    lists: merged,
    byUrl: byUrl,
    applied: applied,
    ids: ids,
    added: added,
    detours: detours,
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

  /// §439 — ссылка файла → адрес здесь (NODE_LINK §7.2, §7.3): `folder_id`
  /// по карте контейнеров и тег, под которым лёг член; `{tag}` на члена
  /// контейнера — пара, если кандидат один (сперва среди узлов файла, затем
  /// среди узлов приёмника). [legacy] — файл 0.x: тег сверяется и с сырым
  /// тегом члена. Позиции цепочек переводит [resolveBackupChainHops].
  BackupLinkMapper linkOf,
});

/// §439 — перевод ссылки файла в адрес здесь ([BackupServerMerge.linkOf]).
typedef BackupLinkMapper = NodeLink Function(NodeLink link, {bool legacy});

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
///
/// **Общий `detour` контейнера** (§439, BACKUP.md §9 пп. 1, 3): у папки 1.0
/// берётся из её записи, у подписки — из [sourceDetours]
/// ([mergeBackupSubscriptions]); тег конфига — по той же карте контейнеров,
/// что у ссылок узлов. Флаги политики detour, `ping_*` папки и префикс
/// одиночного узла — настройки LxBox: пока контракт их не объявил (Л2), в файл
/// они не едут и остаются своими; объявленные применяются, когда приехали.
BackupServerMerge mergeBackupServers(
  List<ServerList> lists,
  List<LxServer> incoming, {
  List<LxFolder> folders = const [],
  Map<String, String> sourceIds = const {},
  Map<String, int> addedSources = const {},
  Map<String, NodeLink?> sourceDetours = const {},
  Set<String> rootNames = const {},
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
    if (f.id.isNotEmpty) folderIds[f.id] = localId;
  }

  // Карта контейнеров для ссылок: подписки (из их слияния) и папки файла.
  final linkIds = {...sourceIds, ...folderIds};

  // §439 — ссылки файла ставятся ПОСЛЕ слияния (NODE_LINK §7.2, §7.3): карта
  // папок, места, куда легли члены, и корень результата известны только
  // тогда. [count] — изменение ссылки считается применённым (у совпавшей
  // папки, чьи прочие настройки не изменились).
  final pendingLinks =
      <({int at, int member, NodeLink? link, bool count})>[];
  for (var i = 0; i < merged.length; i++) {
    final l = merged[i];
    if (l is! SubscriptionServers || !sourceDetours.containsKey(l.id)) continue;
    pendingLinks
        .add((at: i, member: -1, link: sourceDetours[l.id], count: false));
  }

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
  // §439 N2 — куда легли члены папок файла (тег в файле → тег здесь) и
  // группы, чей состав переводится в адреса здесь после всех членов.
  final landings = <(int, String), String>{};
  final autoGroups = <_BackupAutoGroup>[];
  for (final (position, _, _, item) in events) {
    if (item is LxFolder) {
      final at = matchedAt[item.key];
      if (at != null) {
        final local = merged[at] as FolderServers;
        final policy = (item.detourPolicy ?? local.detourPolicy)
            .copyWith(overrideDetour: local.detourPolicy.overrideDetour);
        final pingUrl = item.pingUrl ?? local.pingUrl;
        final pingTimeoutMs = item.pingTimeoutMs ?? local.pingTimeoutMs;
        final changed = local.enabled != item.enabled ||
            local.tagPrefix != item.tagPrefix ||
            local.detourPolicy != policy ||
            local.pingUrl != pingUrl ||
            local.pingTimeoutMs != pingTimeoutMs;
        if (changed) {
          merged[at] = local.copyWith(
            enabled: item.enabled,
            tagPrefix: item.tagPrefix,
            detourPolicy: policy,
            pingUrl: pingUrl,
            pingTimeoutMs: pingTimeoutMs,
          );
          applied++;
        }
        pendingLinks
            .add((at: at, member: -1, link: item.detour, count: !changed));
        folderAtKey[item.key] = at;
      } else {
        merged.add(FolderServers(
          id: plannedId[item.key]!,
          name: item.name,
          enabled: item.enabled,
          tagPrefix: item.tagPrefix,
          detourPolicy: item.detourPolicy ?? DetourPolicy.defaults,
          pingUrl: item.pingUrl,
          pingTimeoutMs: item.pingTimeoutMs,
        ));
        pendingLinks.add((
          at: merged.length - 1,
          member: -1,
          link: item.detour,
          count: false,
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
    if (srv.autoGroup != null) {
      final at = srv.folderRef.isNotEmpty
          ? folderAtKey[srv.folderRef]
          : _folder0xAt(merged, srv, folderByName, takenIds, added, position);
      if (at == null) continue;
      applied += _mergeFolderAutoGroup(merged, at, srv, autoGroups);
      continue;
    }
    final body = srv.uri.isNotEmpty
        ? srv.uri
        : (srv.configJson == null ? '' : jsonEncode(srv.configJson));
    if (body.isEmpty) continue;

    if (srv.folderRef.isNotEmpty) {
      // Член папки 1.0: папка обработана раньше своих членов.
      final at = folderAtKey[srv.folderRef];
      if (at == null) continue;
      final count = (merged[at] as FolderServers).members.length;
      applied += _mergeFolderMember(
          merged, at, srv, body, NodeLink.none, touched,
          landings: landings);
      if ((merged[at] as FolderServers).members.length > count) {
        pendingLinks
            .add((at: at, member: count, link: srv.detour, count: false));
      }
      continue;
    }

    if (srv.folder.isEmpty) {
      final key = canonicalNodeBody(body);
      final hit = singleBodies[key];
      if (hit != null) {
        final local = merged[hit] as UserServer;
        // §439 Л2 — объявленные настройки LxBox узла: как секции, поле есть —
        // замещает, нет — своё остаётся. Ссылку detour совпавший узел держит.
        final flags = srv.detourPolicy
            ?.copyWith(overrideDetour: local.detourPolicy.overrideDetour);
        final side = (flags != null && flags != local.detourPolicy) ||
            (srv.tagPrefix != null && srv.tagPrefix != local.tagPrefix);
        if (srv.sectionsPresent || side) {
          merged[hit] = local.copyWith(
            sections: srv.sectionsPresent ? srv.sections : null,
            clearSections: srv.sectionsPresent && srv.sections == null,
            detourPolicy: flags,
            tagPrefix: srv.tagPrefix,
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
        tagPrefix: srv.tagPrefix ?? '',
        detourPolicy: srv.detourPolicy ?? DetourPolicy.defaults,
        origin: UserSource.manual,
        rawBody: body,
        // Фича 478 — прочие warnings записи; вердикт страховки срезан (§489).
        warnings: srv.warnings,
        sections: srv.sections,
      ));
      pendingLinks.add((
        at: merged.length - 1,
        member: -1,
        link: srv.detour,
        count: false,
      ));
      singleBodies[key] = merged.length - 1;
      touched.add((list: merged.length - 1, member: -1));
      added[merged.last.id] = position;
      applied++;
      continue;
    }

    // Член папки 0.x: папка — имя.
    final at =
        _folder0xAt(merged, srv, folderByName, takenIds, added, position);
    applied += _mergeFolderMember(merged, at, srv, body, NodeLink.none, touched,
        landings: landings);
  }

  applied += _bindBackupAutoGroups(merged, autoGroups, linkIds, landings);

  final linkOf = _backupLinkMapper(
    merged: merged,
    incoming: incoming,
    folders: folders,
    folderAtKey: folderAtKey,
    folderByName: folderByName,
    ids: linkIds,
    landings: landings,
    rootNames: rootNames,
  );
  for (final p in pendingLinks) {
    final l = merged[p.at];
    final link = p.link == null ? NodeLink.none : linkOf(p.link!, at: p.at);
    if (p.member < 0) {
      if (l.detourPolicy.overrideDetour == link) continue;
      final policy = l.detourPolicy.copyWith(overrideDetour: link);
      merged[p.at] = switch (l) {
        SubscriptionServers s => s.copyWith(detourPolicy: policy),
        UserServer u => u.copyWith(detourPolicy: policy),
        FolderServers f => f.copyWith(detourPolicy: policy),
      };
      if (p.count) applied++;
    } else if (l is FolderServers && p.member < l.members.length) {
      if (l.members[p.member].detour == link) continue;
      merged[p.at] = l.copyWith(
        members: l.members.toList()
          ..[p.member] = l.members[p.member].copyWith(detour: link),
      );
    }
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
    linkOf: (NodeLink link, {bool legacy = false}) =>
        linkOf(link, legacy: legacy),
  );
}

/// §439 — перевод ссылок файла в адреса здесь (NODE_LINK §7.2, §7.3), общий
/// для detour узлов и контейнеров и позиций цепочек.
///
/// - Пара с `folder_id` папки файла → `id` папки здесь и тег, под которым
///   лёг член ([landings]); S3 — финальный тег группы этой папки вместо
///   сырого при единственном кандидате. Прочий контейнер — по карте [ids],
///   нет в карте — как есть (разбирает сборка).
/// - `{tag}`, занятый корнем результата (одиночный сервер здесь, [rootNames]:
///   Направления, цепочки, служебные теги), не трогается.
/// - S1 — носитель в папке [at], тег — сырой тег члена этой папки (файла или
///   здесь): пара.
/// - Иначе тег сверяется с финальной формой «префикс + тег» членов папок
///   ФАЙЛА (у файла 0.x — и с сырым тегом), и только если там такого имени
///   нет — с членами контейнеров приёмника. Кандидат ровно один — пара;
///   несколько или ни одного — ссылка как есть, без предупреждения.
NodeLink Function(NodeLink link, {int? at, bool legacy}) _backupLinkMapper({
  required List<ServerList> merged,
  required List<LxServer> incoming,
  required List<LxFolder> folders,
  required Map<String, int> folderAtKey,
  required Map<String, int> folderByName,
  required Map<String, String> ids,
  required Map<(int, String), String> landings,
  required Set<String> rootNames,
}) {
  final atByFileId = <String, int>{
    for (final f in folders)
      if (f.id.isNotEmpty && folderAtKey[f.key] != null)
        f.id: folderAtKey[f.key]!,
  };
  final folderByKey = {for (final f in folders) f.key: f};
  // Корень результата — тот же список известных целей, что у правил и
  // `route.final` (D-117): объявленные имена плюс корневые узлы слияния.
  final rootTaken = <String>{...rootNames, ...lxImportRootNodeTags(merged)};

  // Члены папок файла: финальная форма и сырой тег → адреса здесь.
  final fileFinal = <String, Set<NodeLink>>{};
  final fileRaw = <String, Set<NodeLink>>{};
  final fileRawAt = <int, Set<String>>{};
  void addFile(int at, String prefix, String name) {
    if (name.isEmpty || at < 0 || at >= merged.length) return;
    final here =
        NodeLink(folderId: merged[at].id, tag: landings[(at, name)] ?? name);
    for (final form in _fileFinalForms(prefix, name)) {
      (fileFinal[form] ??= {}).add(here);
    }
    (fileRaw[name] ??= {}).add(here);
    (fileRawAt[at] ??= {}).add(name);
  }

  for (final srv in incoming) {
    final name = srv.autoGroup?.tag ?? srv.name;
    if (srv.folderRef.isNotEmpty) {
      final f = folderByKey[srv.folderRef];
      final at = folderAtKey[srv.folderRef];
      if (f != null && at != null) addFile(at, f.tagPrefix, name);
    } else if (srv.folder.isNotEmpty) {
      final at = folderByName[srv.folder];
      if (at != null) addFile(at, '', name);
    }
  }

  // Члены контейнеров приёмника (узлы подписок в хранении не лежат).
  final hereFinal = <String, Set<NodeLink>>{};
  final hereRaw = <String, Set<NodeLink>>{};
  for (final l in merged) {
    if (l is UserServer) continue;
    containerRawTags(l).forEach((_, raw) {
      final here = NodeLink(folderId: l.id, tag: raw);
      (hereFinal[containerFinalForm(l, raw)] ??= {}).add(here);
      (hereRaw[raw] ??= {}).add(here);
    });
  }

  return (NodeLink link, {int? at, bool legacy = false}) {
    if (link.isEmpty) return link;
    if (!link.isRoot) {
      final fileAt = atByFileId[link.folderId];
      if (fileAt != null) {
        final folder = merged[fileAt];
        final landed = landings[(fileAt, link.tag)];
        if (landed != null) return NodeLink(folderId: folder.id, tag: landed);
        final raw = containerRawTags(folder);
        final groupForms = <String, List<String>>{};
        raw.forEach((node, tag) {
          if (node.isGroup) {
            for (final form in _fileFinalForms(folder.tagPrefix, tag)) {
              (groupForms[form] ??= []).add(tag);
            }
          }
        });
        return lowerGroupFinalLink(
          NodeLink(folderId: folder.id, tag: link.tag),
          folder.id,
          raw.values.toSet(),
          groupForms,
        );
      }
      final local = ids[link.folderId];
      return local == null ? link : NodeLink(folderId: local, tag: link.tag);
    }
    final t = link.tag;
    if (rootTaken.contains(t)) return link;
    // S1 — сосед по папке носителя.
    if (at != null && at >= 0 && at < merged.length) {
      final carrier = merged[at];
      if (carrier is FolderServers) {
        if (fileRawAt[at]?.contains(t) ?? false) {
          return NodeLink(
              folderId: carrier.id, tag: landings[(at, t)] ?? t);
        }
        final lifted =
            liftSiblingLink(link, carrier.id, containerRawTagSet(carrier));
        if (!lifted.isRoot) return lifted;
      }
    }
    Set<NodeLink> hits(
      Map<String, Set<NodeLink>> byFinal,
      Map<String, Set<NodeLink>> byRaw,
    ) =>
        {...?byFinal[t], if (legacy) ...?byRaw[t]};
    final fromFile = hits(fileFinal, fileRaw);
    if (fromFile.isNotEmpty) {
      return fromFile.length == 1 ? fromFile.single : link;
    }
    final fromHere = hits(hereFinal, hereRaw);
    return fromHere.length == 1 ? fromHere.single : link;
  };
}

/// Узлы текста одиночного сервера; не разобрался — пусто.
List<NodeSpec> _nodesOf(String raw) {
  if (raw.trim().isEmpty) return const [];
  try {
    return parseAll(decode(raw));
  } catch (_) {
    return const [];
  }
}

/// Финальные формы тега [raw] члена папки файла с префиксом модели [prefix]
/// для сопоставления ссылок файла (NODE_LINK §7.3, S3): форма LxBox
/// «префикс, пробел, тег» и форма контракта «префикс + тег» — у префикса
/// файла без хвостового пробела (`"d:"`) финальный тег стороны-экспортёра
/// `d:G`, а модель LxBox хранит `d:` и показывает `d: G` (§439 п. 9).
Set<String> _fileFinalForms(String prefix, String raw) => {
      TagResolver.displayTag(prefix, raw),
      if (prefix.isNotEmpty) '$prefix$raw',
    };

/// Член папки [folderAt]: дедуп по канону тела в пределах этой папки, новые
/// в конец. Возвращает, сколько применилось (0 — узнан без секций файла).
int _mergeFolderMember(
  List<ServerList> merged,
  int folderAt,
  LxServer srv,
  String body,
  NodeLink detour,
  List<BackupNodeRef> touched, {
  Map<(int, String), String>? landings,
}) {
  final folder = merged[folderAt] as FolderServers;
  final canon = canonicalNodeBody(body);
  final hit = folder.members.indexWhere((m) => canonicalNodeBody(m.raw) == canon);
  if (hit >= 0) {
    final here = folder.members[hit].node?.tag ?? '';
    if (srv.name.isNotEmpty && here.isNotEmpty) {
      landings?[(folderAt, srv.name)] = here;
    }
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
  final member = FolderMember(
    raw: body,
    enabled: srv.enabled,
    // Фича 478 — прочие warnings записи; вердикт страховки срезан (§489).
    warnings: srv.warnings,
    detour: detour,
    sections: srv.sections,
  );
  final here = member.node?.tag ?? '';
  if (srv.name.isNotEmpty && here.isNotEmpty) {
    landings?[(folderAt, srv.name)] = here;
  }
  merged[folderAt] = folder.copyWith(members: [...folder.members, member]);
  touched.add((list: folderAt, member: folder.members.length));
  return 1;
}

/// Папка члена 0.x [srv] по имени; заведённая им же папка находится по
/// имени (иначе каждая запись с тем же `folder` заводила бы новую).
int _folder0xAt(
  List<ServerList> merged,
  LxServer srv,
  Map<String, int> folderByName,
  Set<String> takenIds,
  Map<String, int> added,
  int position,
) {
  final at = folderByName[srv.folder];
  if (at != null && at >= 0) return at;
  merged.add(FolderServers(
    id: _adoptSourceId('', takenIds),
    name: srv.folder,
    enabled: true,
    tagPrefix: '',
    detourPolicy: DetourPolicy.defaults,
  ));
  folderByName[srv.folder] = merged.length - 1;
  added[merged.last.id] = position;
  return merged.length - 1;
}

/// §439 N2 — член-группа файла, ждущий перевода состава в адреса здесь.
typedef _BackupAutoGroup = ({
  int folderAt,
  int member,
  LxServer srv,
  bool fresh,
});

/// Член-группа папки [folderAt]. Ссылочный член без тела ключуется тегом
/// (BACKUP.md §9 п. 3): группа с тем же тегом в папке — та же группа, её
/// значение берётся из файла; иначе новая встаёт в конец. Состав переводит
/// [_bindBackupAutoGroups]. Возвращает, сколько применилось сейчас.
int _mergeFolderAutoGroup(
  List<ServerList> merged,
  int folderAt,
  LxServer srv,
  List<_BackupAutoGroup> pending,
) {
  final folder = merged[folderAt] as FolderServers;
  final group = srv.autoGroup!;
  final hit = folder.members.indexWhere(
      (m) => m.node is AutoSelectSpec && m.node!.tag == group.tag);
  if (hit >= 0) {
    pending.add((folderAt: folderAt, member: hit, srv: srv, fresh: false));
    return 0;
  }
  merged[folderAt] = folder.copyWith(members: [
    ...folder.members,
    FolderMember.auto(group, enabled: srv.enabled),
  ]);
  pending.add((
    folderAt: folderAt,
    member: folder.members.length,
    srv: srv,
    fresh: true,
  ));
  return 1;
}

/// §439 N2, NODE_LINK §7.2 — состав групп файла → адреса здесь: член своей
/// папки файла получает `id` папки здесь и тег, под которым член лёг
/// ([landings]); член чужого контейнера — `id` по карте [ids] (нет в карте —
/// как есть, разбирает сборка). Совпавшая группа, чьё значение не
/// изменилось, не считается применённой.
int _bindBackupAutoGroups(
  List<ServerList> merged,
  List<_BackupAutoGroup> pending,
  Map<String, String> ids,
  Map<(int, String), String> landings,
) {
  var applied = 0;
  for (final p in pending) {
    final folder = merged[p.folderAt] as FolderServers;
    var group = p.srv.autoGroup!;
    final membership = group.membership;
    if (membership is ExplicitMembers) {
      group = group.copyWith(
        membership: ExplicitMembers([
          for (final l in membership.members)
            if (l.isRoot || l.folderId == p.srv.folderRef)
              NodeLink(
                folderId: folder.id,
                tag: landings[(p.folderAt, l.tag)] ?? l.tag,
              )
            else
              NodeLink(folderId: ids[l.folderId] ?? l.folderId, tag: l.tag),
        ]),
      );
    }
    final member = FolderMember.auto(group, enabled: p.srv.enabled);
    if (folder.members[p.member] == member) continue;
    merged[p.folderAt] = folder.copyWith(
      members: folder.members.toList()..[p.member] = member,
    );
    if (!p.fresh) applied++;
  }
  return applied;
}

/// §439 — позиции цепочек файла → ссылки здесь.
///
/// Хоп 1.0 — ссылка `{folder_id?, tag}` с сырым тегом (BACKUP.md §4, §6):
/// `folder_id` переводится по карте контейнеров, тег — туда, куда лёг член,
/// `{tag}` на члена контейнера поднимается до пары ([BackupServerMerge.linkOf],
/// NODE_LINK §7.3). Позиция 0.x — строка (финальный или сырой тег), читается
/// корневой ссылкой и поднимается тем же правилом с проверкой сырого тега.
/// Без [linkOf] переводится только `folder_id` по [folderIds]. Контейнера нет
/// ни в файле, ни здесь — ссылка ввозится как есть: недостижимую позицию
/// разбирает сборка (`chain_hop_missing`), а не импорт.
List<SourceChain> resolveBackupChainHops(
  LxBackupFile file,
  List<ServerList> lists,
  Map<String, String> folderIds, {
  BackupLinkMapper? linkOf,
}) {
  NodeLink map(NodeLink link, {required bool legacy}) => linkOf != null
      ? linkOf(link, legacy: legacy)
      : _remapLink(link, folderIds);

  return [
    for (final c in file.chains)
      if (file.chainHops[c.tag] case final links?)
        c.copyWith(hops: [for (final l in links) map(l, legacy: false)])
      else if (linkOf != null)
        c.copyWith(hops: [for (final l in c.hops) map(l, legacy: true)])
      else
        c,
  ];
}

/// §439 — `folder_id` ссылки файла → `id` контейнера здесь по карте [ids].
NodeLink _remapLink(NodeLink link, Map<String, String> ids) {
  if (link.isRoot) return link;
  final local = ids[link.folderId];
  return local == null ? link : NodeLink(folderId: local, tag: link.tag);
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
/// Крайние случаи (BACKUP.md §9 п. 7, форма лаунчера `5cbcc436`):
///
///  * **ни одно корневое правило не размечено** — номера не проставляются
///    вовсе, правила возвращаются как есть. Разметку даёт загрузка
///    (`markRuleOrder`): пресету — номер шаблона (голова 0, 950–990 …),
///    остальным — подряд от [kUserRuleNumStart]. Номера от 1000 всем подряд
///    поставили бы пресеты-перехватчики и голову `traffic-processing` за
///    пользовательскими правилами;
///  * **размечены не все** — неразмеченные корневые встают в хвост оси в
///    порядке файла (без номера разметка при загрузке поставила бы их поверх
///    размеченных), но не ниже [kUserRuleNumStart]: хвост файла с номерами
///    шаблона не уводит правило пользователя в зону пресетов.
///
/// Правила секций без номера остаются без него — сборка ставит их на 945.
///
/// Возвращает корневые правила в порядке оси; номера проставляются в тех же
/// объектах (как во всём §370).
List<CustomRule> renumberBackupAxis(
  List<CustomRule> rules,
  List<ServerList> lists,
  List<BackupNodeRef> touched,
) {
  if (rules.every((r) => r.orderNum == null)) return rules;

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

  var next = last + 1 < kUserRuleNumStart ? kUserRuleNumStart : last + 1;
  for (final r in rules) {
    r.orderNum ??= next++;
  }
  return sortRulesByAxis(rules);
}
