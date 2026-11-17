part of '../lx_backup.dart';

/// LX Backup, стадия 5: декодер формата 1.0 (`lx_backup: 2`) — разбор записей,
/// наборы допустимых ключей 1.0, `_scanUnknown10`.

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
  final chainPositions = <String, int>{};
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
        chainPositions[tag] = i;
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
  final mixins = _parseMixins(decoded, warnings);
  final nativePrefs = _parseNativePrefs(decoded, warnings);
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
    rulesDeclared: decoded.containsKey('rules'),
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
    warnings: warnings,
  );
}

/// §575 — секции у записи ЛЮБОГО вида (сервер, член папки, подписка, папка,
/// цепочка, `auto`, `unsupported`): поле снимается целиком с
/// `reason: not_allowed`, одно предупреждение на запись (контракт 1.1.85).
/// Пустой набор предупреждения не даёт — терять в нём нечего. Само поле
/// дальше не читается: у сервера и члена папки его снимает [_server10] до
/// кодека, прочим видам кодек его не читает.
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
    reason: kSectionDropReasonNotAllowed,
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
/// Поле `sections` снимается до кодека ([_dropForeignSections], §575).
/// `detour` — ссылка файла как есть: тег конфига из неё
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
  _dropForeignSections(j, _str(j['kind']), warnings);
  if (j.containsKey('sections')) j = {...j}..remove('sections');
  final tag = _trimmed(j['tag']);
  final origin = _obj(j['origin']);
  final hasOrigin = _str(origin?['raw']).trim().isNotEmpty;
  final fileId = folder == null ? _trimmed(j['id']) : '';
  final read = sourceFromRecord(
    _sourceForCodec(
      folder == null ? BackupRecord.server : BackupRecord.folderNode,
      // Пустой исходник читается как его отсутствие: тело берётся из `body`.
      hasOrigin ? j : ({...j}..remove('origin')),
      fileId,
      override: const {'kind': kSourceKindServer},
    ),
  );
  final node = read.value;
  if (node is! UserServer) return null;
  final raw = node.rawBody;
  if (raw.trim().isEmpty) return null;

  var uri = '';
  Map<String, dynamic>? configJson;
  // §722 — тег записи ложится в голое тело JSON-диалекта (`tag` у sing-box
  // и Xray). Документ (§11 п.6: при чтении не обрезается), массив, ссылка,
  // `.conf` и нечитаемый JSON — текст как есть.
  final dialect = node.dialect;
  final obj = dialect.isJson ? _tryDecodeObject(raw.trim()) : null;
  final bare = obj != null &&
      obj[dialect == SourceDialect.singbox ? 'type' : 'protocol'] is String;
  if (bare) {
    configJson = {...obj, if (tag.isNotEmpty) 'tag': tag};
  } else {
    uri = raw;
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
    dialect: dialect,
    name: tag,
    enabled: node.enabled,
    warnings: storedWarningsFromJson(j['warnings']),
    folder: folder?.name ?? '',
    folderRef: folder?.key ?? '',
    position: position,
    id: fileId,
    skipTailscalePresets: node.skipTailscalePresets,
    allowLocal: node.allowLocal,
    allowLan: node.allowLan,
    allowGateway: node.allowGateway,
    ownRoutes: node.ownRoutes,
    disableTaildropCommands: node.disableTaildropCommands,
    disableTaildropAutosave: node.disableTaildropAutosave,
    stateDirId: node.stateDirId,
    tls: _carries(folder == null ? BackupRecord.server : BackupRecord.folderNode,
            j, 'tls')
        ? node.tls
        : null,
  );
}

/// Член папки 1.0. `server` — узел; `unsupported` с исходником — у LxBox
/// есть дом: нечитаемый член папки хранит текст и виден в списке (§234);
/// `auto` — узел автовыбора кодеком хранения (§439 N2, род `selector` —
/// как записан, §565); `chain` папка LxBox не держит —
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
      return LxServer(
        autoGroup: group,
        name: group.tag,
        enabled: read.member.enabled,
        // Контракт 1.1.66 — записи группы читатель кладёт как есть.
        warnings: read.member.warnings,
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
    tls: carries('tls') ? sub.tls : null,
    replace: sub.replace,
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
    replace: folder.replace,
    tls: carries('tls') ? folder.tls : null,
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
    // §681 — отсутствие ключа и пустой массив различаются: пустой каталог
    // источника снимать нечего, нет ключа — переходная ветка.
    templateCatalog: j.containsKey('template_catalog')
        ? [
            for (final t in _list(j['template_catalog']))
              if (t is String && t.trim().isNotEmpty) t.trim(),
          ]
        : null,
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
  'mixins', // §704
  'native_prefs', // §707 итер. 9 (контракт 1.1.158)
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
  // §578 — «пропустить пресеты» узла: старый ключ, только терпимое чтение.
  'skip_presets',
  // §656 (контракт 1.1.126) — поля записи узла; пишется только true.
  'skip_tailscale_presets',
  'allow_local',
  'allow_lan',
  'allow_gateway',
  'own_routes',
  // §707 итер. 9 (контракт 1.1.159) — Taildrop узла, знак «выключено»; пишется только true.
  'disable_taildrop_commands',
  'disable_taildrop_autosave',
  // §707 (контракт 1.1.160): `state_dir_id` переносится как есть;
  // `taildrop_double_copy` — поле лаунчера, молча пропускается.
  'state_dir_id',
  'taildrop_double_copy',
  // Фича 478 — вердикт на члене папки. Ключ известен обходу, чтобы старый
  // файл с `core_rejected` не давал `backup_unknown_field`; содержимое
  // срезает санитизация §489.
  'warnings',
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
  // Фича 565 фаза B (§74) — свёртка в группу. Прежние `fold`/`fold_tag` по
  // решению владельца 26.09.2026 не читаются: чужие ключи с предупреждением.
  'replace',
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
  'template_catalog',
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
  sc.nested(root, 'native_prefs', NativePrefsKeys.all); // §707 итер. 9

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
    final replace = _obj(item['replace']);
    if (replace != null) {
      sc.object('$where.replace', replace, kReplaceRecordKeys);
      sc.nestedAt(replace, '$where.replace', 'auto', _directionAutoKeys);
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
  sc.array(root, 'mixins', 'mixins', _mixinKeys, 'name', null); // §704

  return sc.warnings();
}
