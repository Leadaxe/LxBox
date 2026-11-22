part of '../lx_backup.dart';

/// LX Backup, стадия 4: декодер семейства 0.x (`lx_backup: 1`) — разбор записей,
/// наборы допустимых ключей 0.x, правила 0.x.

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
  final mixins = _parseMixins(decoded, warnings);
  final nativePrefs = _parseNativePrefs(decoded, warnings);
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
    rulesDeclared: decoded.containsKey('rules'),
    chains: chains,
    subscriptions: subscriptions,
    servers: servers,
    dns: parsedVars.dns,
    warp: warp,
    mixins: mixins,
    nativePrefs: nativePrefs,
    vars: parsedVars.vars,
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
  'mixins', // §704
  'native_prefs', // §707 итер. 9 (контракт 1.1.158)
};


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
  // `fold` 0.x не читается (контракт 1.1.79 §76): чужой ключ с предупреждением.
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
  // §594 — `label` цепочки объявлен в схеме, но у цепочки одно имя — тег:
  // ключ знаем (без предупреждения), в модель не читаем и не пишем.
  'label',
  'enabled',
  'chain',
  'exclude_from_global',
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
  sc.array(root, 'mixins', 'mixins', _mixinKeys, 'name', null); // §704

  return sc.warnings();
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
      return ref.isEmpty ? null : DnsRulePreset(presetId: ref);
    default:
      return name.isEmpty
          ? null
          : DnsRuleTemplate(name: name, enabled: enabled);
  }
}



/// §393 C9 — каноническая запись `chains[]` → мобильная [SourceChain].
///
/// Достижимость `hops` здесь НЕ проверяется: хоп — чаще всего узел подписки,
/// которого до её обновления не существует, и рубеж валидации у обеих сторон
/// один — сборка конфига (`chain_hop_missing`). Эталон —
/// `core/backup/import.go:importChain`.
///
/// §594 — `label` у цепочки упразднён: ключ игнорируется молча, без
/// [kWarnLabelDropped], — имя цепочки её тег.
SourceChain _chainFromCanon(Map<String, dynamic> j, String tag) {
  final canon =
      (j['chain'] as Map?)?.cast<String, dynamic>() ??
      const <String, dynamic>{};
  // Канон разбирается кодеком цепочки: второй разбор тех же полей разошёлся
  // бы с ним на первой же правке (трёхзначный `strip_evasion`, порядок
  // каталога `strip`, `null` внутри `rewrite`). Позиции 0.12 — строки.
  final enabled = j['enabled'];
  return chainFromRecord({
    'kind': kSourceKindChain,
    'tag': tag,
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
      return CustomRuleTree.flat(
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
      return CustomRuleTree.flat(
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
