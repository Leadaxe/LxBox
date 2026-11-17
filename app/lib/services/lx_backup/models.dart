part of '../lx_backup.dart';

/// LX Backup, стадия 2: промежуточные модели файла (`LxSubscription`, `LxServer`,
/// `LxFolder`, `LxDns`, `LxBackupFile`, `LxBackupExport`) и предупреждения.

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
    this.replace,
    this.tls,
  });

  /// §636 — TLS-политика источника: едет, только если контракт объявил поле
  /// (Л2); `null` — у новой подписки пусто, у совпавшей своя остаётся.
  final TlsPolicy? tls;

  /// Фича 565 фаза B (§74) — свёртка подписки в группу. Поле контракта: у
  /// файла 1.0 ([fullSettings]) отсутствие объекта значит «не свёрнута»; у
  /// 0.x `null` — свою настройку совпавшая подписка держит.
  final SourceReplace? replace;

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

  /// Фича 478 / PARSING_PRINCIPLES §9.4 — вердикт ядра оверлеем тем же ключом, что и
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
    this.skipTailscalePresets = false,
    this.allowLocal = false,
    this.allowLan = false,
    this.allowGateway = false,
    this.ownRoutes = false,
    this.disableTaildropCommands = false,
    this.disableTaildropAutosave = false,
    this.stateDirId = '',
    this.detour,
    this.position = 0,
    this.autoGroup,
    this.detourPolicy,
    this.tagPrefix,
    this.tls,
    this.dialect,
  });

  /// §722 — вид источника узла 1.0 (`origin.kind` после чтения записи, со
  /// старого `json` — миграция). `null` — вход 0.x: вид определит движок на
  /// входе текста.
  final SourceDialect? dialect;

  /// §636 — узловая TLS-политика (корневой сервер и член папки): едет, только
  /// если контракт объявил поле (Л2); совпавший узел держит свою.
  final TlsPolicy? tls;

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

  /// §578/§656 — поля записи узла `skip_tailscale_presets` (старый ключ
  /// `skip_presets` читается терпимо), `allow_local`, `allow_lan`,
  /// `allow_gateway` (пишутся только `true`). Совпавший по телу узел
  /// получает `true` из файла; отсутствие поля своё не сбрасывает.
  final bool skipTailscalePresets;
  final bool allowLocal;
  final bool allowLan;
  final bool allowGateway;

  /// `own_routes` (пресет `tunnel-routes`), те же правила.
  final bool ownRoutes;

  /// §707 итер. 9 (контракт 1.1.159) — `disable_taildrop_commands` /
  /// `disable_taildrop_autosave`, те же правила, что у полей выше.
  final bool disableTaildropCommands;
  final bool disableTaildropAutosave;

  /// §707 (контракт 1.1.160) — `state_dir_id` записи файла как есть (пусто —
  /// поля нет). Только перенос: совпавший узел держит своё, новый с занятым
  /// именем получает другое ([mergeBackupServers]).
  final String stateDirId;

  /// §656 — флаги записи файла поверх своих: только `true` (слияние
  /// совпавшего узла). Все поля уже стоят — null.
  ({
    bool skip,
    bool local,
    bool lan,
    bool gateway,
    bool ownRoutes,
    bool commandsOff,
    bool autosaveOff
  })? flagsOver({
    required bool skip,
    required bool local,
    required bool lan,
    required bool gateway,
    required bool ownRoutes,
    required bool commandsOff,
    required bool autosaveOff,
  }) {
    final r = (
      skip: skip || skipTailscalePresets,
      local: local || allowLocal,
      lan: lan || allowLan,
      gateway: gateway || allowGateway,
      ownRoutes: ownRoutes || this.ownRoutes,
      commandsOff: commandsOff || disableTaildropCommands,
      autosaveOff: autosaveOff || disableTaildropAutosave,
    );
    return r ==
            (
              skip: skip,
              local: local,
              lan: lan,
              gateway: gateway,
              ownRoutes: ownRoutes,
              commandsOff: commandsOff,
              autosaveOff: autosaveOff
            )
        ? null
        : r;
  }

  /// Имя записи: `node_tag` схемы, а не подпись. У канона имени, кроме тега,
  /// нет (SPEC 112), и `label` старого файла становится им только когда
  /// `node_tag` отсутствует (§401, D-082).
  final String name;

  final bool enabled;

  /// Фича 478 / PARSING_PRINCIPLES §9.4 — вердикт ядра рядом с [enabled]: ручной сервер и
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
/// префикс `tag_policy`, общий `detour` и свёртка `replace` (фича 565 фаза B).
/// `postfix` — поле лаунчера (колонка «Поддержка» BACKUP.md §2).
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
    this.replace,
    this.tls,
  });

  /// §636 — TLS-политика папки: как у [LxSubscription.tls].
  final TlsPolicy? tls;

  /// Фича 565 фаза B (§74) — свёртка папки в группу; `null` — не свёрнута
  /// (поле контракта: запись 1.0 несёт папку целиком).
  final SourceReplace? replace;

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
    this.templateCatalog,
  });

  /// §681 (контракт 1.1.135, D-139) — `dns.template_catalog`: теги
  /// `dns_options.servers` шаблона источника на момент экспорта. `null` —
  /// поля в файле нет (файл до 1.1.135, переходная ветка BACKUP.md §9 п. 5).
  final List<String>? templateCatalog;

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
    this.chainPositions = const {},
    this.dns,
    this.warp = const [],
    this.rulesDeclared = true,
    this.mixins = const [],
    this.nativePrefs = const {},
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

  /// §640 (контракт 1.1.116) — ключ `rules` есть в корне файла, пусть и `[]`.
  /// `false` — файл о правилах молчит, и импорт правила приёмника не трогает
  /// (BACKUP.md §9 п. 7); [rules] тогда пуст.
  final bool rulesDeclared;

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

  /// §511 m2 — место цепочки в `sources[]` файла 1.0 (тег → индекс записи),
  /// та же шкала, что [LxSubscription.position]: импорт по ней ставит
  /// цепочки между источниками, как в файле. У 0.x пусто.
  final Map<String, int> chainPositions;

  /// §393 B9 — секция DNS; `null` = в файле её не было.
  final LxDns? dns;

  /// §393 B8 — записи `warp[]` в канонической форме схемы (дискриминатор
  /// `type: wg|masque`). Разбор в нативные модели — на стороне применения:
  /// парсер не должен знать про storage.
  final List<Map<String, dynamic>> warp;

  /// §704 — миксины итогового конфига в порядке файла, с новыми `id`
  /// (в файле `id` нет). Совпадение с миксином приёмника по телу снимает
  /// план импорта.
  final List<Mixin> mixins;

  /// §707 итер. 9 (контракт 1.1.158, D-141) — секция `native_prefs`
  /// (настройки телефона): только известные ключи с типом схемы. Импорт
  /// применяет присланные ключи; отсутствие ключа своё значение не трогает.
  final Map<String, Object> nativePrefs;

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
        rulesDeclared: rulesDeclared,
        chains: chains,
        chainHops: chainHops,
        chainPositions: chainPositions,
        subscriptions: subscriptions,
        servers: servers,
        folders: folders,
        dns: dns,
        warp: warp,
        mixins: mixins,
        nativePrefs: nativePrefs,
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
