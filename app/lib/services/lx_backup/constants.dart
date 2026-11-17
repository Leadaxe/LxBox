part of '../lx_backup.dart';

/// LX Backup, стадия 1: константы формата, коды предупреждений, переносимые
/// переменные и зарезервированные исходящие.

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
/// а записи сервера с этим тегом в файле нет (Н8); [kVarSkippedInternal]
/// (§643, контракт 1.1.119, D-132) — имя объявлено носителем (или корневой
/// переменной шаблона) с `wizard_ui: internal`: его пишет только сборка.
const String kVarSkippedNotPortable = 'not_portable';
const String kVarSkippedUndeclared = 'undeclared';
const String kVarSkippedSuperseded = 'superseded';
const String kVarSkippedNoRecord = 'no_record';
const String kVarSkippedInternal = 'internal';

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

/// §681 (контракт 1.1.135, D-139, BACKUP.md §9 п. 5) — шаблонный DNS-сервер,
/// который источник знал (тег в `dns.template_catalog`) и удалил, у приёмника
/// НЕ снят: его держит ссылка состояния после импорта. detail —
/// `template:<tag> used_by=<ссылка>`, ссылка — первая по словарю
/// (`final`, `default_domain_resolver`, `dns_rule:<server>`, `rule:<name>`,
/// `group:<tag>`, `server:<tag>`, `preset:<id>`, `required`).
const String kWarnDnsEntryKept = 'backup_dns_entry_kept';

/// §681 — `dns.final` / `dns.default_domain_resolver` файла после импорта
/// указывает на тег вне списка приёмника или выключенный: сброшен на
/// умолчание шаблона приёмника. detail — `<field>=<значение файла>`.
const String kWarnDnsResolverReset = 'backup_dns_resolver_reset';

/// §681 — приехавшая сервер-группа без единого члена из списка приёмника
/// ввезена выключенной. detail — тег группы.
const String kWarnDnsGroupEmpty = 'backup_dns_group_empty';

/// §393 B8 — запись `warp[]` не разобралась (нет дискриминатора `type`,
/// нет ключа регистрации). Аккаунт без приватного ключа не собирает узел,
/// поэтому применять нечего.
const String kWarnWarpSkipped = 'backup_warp_skipped';

/// §438/§575 — поле `sections` записи файла снято целиком: секции узла
/// упразднены (контракт 1.1.85). [LxBackupWarning.kind] — вид записи,
/// [LxBackupWarning.reason] — всегда [kSectionDropReasonNotAllowed].
const String kWarnSectionRecordDropped = 'backup_section_record_dropped';

/// §575 — единственная причина [kWarnSectionRecordDropped] (контракт 1.1.85:
/// прежние `kind` / `rule_set` / `unknown_key` отменены вместе с секциями).
const String kSectionDropReasonNotAllowed = 'not_allowed';

/// §438 — запись `sources[]` вида, которому на этой стороне нет места:
/// корневые `auto`/`unsupported` (union 1.0 их не выражает, BACKUP.md §2),
/// незнакомый `kind`, а у LxBox ещё члены папки `chain` — цепочка здесь
/// только корневой источник. Член папки `auto` — узел автовыбора (§439 N2).
/// [LxBackupWarning.kind] — вид записи. Запись не применяется.
const String kWarnSourceKindUnsupported = 'backup_source_kind_unsupported';

/// Контракт 1.0.1 — провайдерская группа (`kind: auto`) приехала в форме,
/// которую сторона не выражает, и ввезена упрощённой. Detail — тег группы,
/// [LxBackupWarning.reason] — что не выразилось. §565 — `selector` LxBox
/// исполняет, упрощения рода больше нет; код остаётся за членами старых
/// autogroup-текстов, которые не нашлись.
const String kWarnGroupDegraded = 'backup_group_degraded';

/// §640 (контракт 1.1.116, BACKUP.md §9 п. 7) — файл нёс ключ `rules` (пусть
/// `[]`), и правила приёмника замещены правилами файла целиком. Detail —
/// `rules: <count>`, число снятых правил приёмника (параметр реестра
/// `count`); код ставится
/// только при `count > 0`. Файл без ключа `rules` правил не трогает и кода не
/// даёт: «ключа нет» и `rules: []` — разные файлы.
const String kWarnRulesReplaced = 'backup_rules_replaced';

/// Переносимые имена переменных — зеркало `registry/vars.json` (portable=true).
///
/// Сверяется с реестром тестом: разъехавшийся список означает, что бэкап либо
/// теряет настройку, либо тащит на чужую машину значение, которое там значит
/// другое (пути, интерфейсы, платформенные флаги).
const Set<String> kLxPortableVars = {
  'auto_detect_interface',
  'dns_cache_capacity',
  'dns_default_domain_resolver',
  'dns_final',
  'dns_optimistic',
  // §643 (контракт 1.1.119, TEMPLATE_LANG §6.9) — едет в `vars` бэкапа, как
  // `dns_optimistic`; секция `dns.default_domain_resolver` — строка-тег.
  'dns_resolver_no_stale',
  'dns_store_cache',
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
