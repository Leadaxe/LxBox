part of '../lx_backup.dart';

/// LX Backup, стадия 3: экспорт состояния в файл формата 1.0 (`buildLxBackup`).

/// Собирает LX Backup формата 1.0 (`lx_backup: 3`, §757) из настроек LxBox.
///
/// §439 — файл = срез хранения плюс тонкий слой (BACKUP.md §1). Записи
/// `sources[]` (подписки, одиночные узлы, папки и цепочки в порядке списка
/// источников) и `rules[]` пишет кодек хранения (`models/codec/`); поля LxBox
/// срезает таблица `lx_backup_slice.dart`. Тонкий слой — `directions[]`,
/// переносимые `vars`, `route.final`, `warp[]` — той же формы, что в 0.12.
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
  /// Порядок `sources[]` файла: ключи `id:<uuid>` и `chain:<tag>`.
  /// Нет — [lists], затем [chains].
  List<String>? sourceKeys,
  String? routeFinal,
  Map<String, dynamic>? dns,
  List<Map<String, dynamic>> warp = const [],
  RecordVarDecls recordVars = RecordVarDecls.none,
  List<Mixin> mixins = const [],
  Map<String, dynamic> nativePrefs = const {},
}) async {
  var appVersion = '';
  try {
    final info = await PackageInfo.fromPlatform();
    appVersion = '${info.version}+${info.buildNumber}';
  } catch (_) {
    // В тестовом окружении PackageInfo недоступен — версия не критична.
  }

  final warnings = <LxBackupWarning>[];
  final sources = _exportSources(
    lists: lists,
    chains: chains,
    sourceKeys: sourceKeys,
    warnings: warnings,
  );

  // §643 — `internal` в бэкап не экспортируется (у правил-пресетов ключи
  // снимает normalizePresetRulesVars ниже).
  final portableVars = <String, String>{
    for (final e in vars.entries)
      if (kLxPortableVars.contains(e.key) &&
          !recordVars.internalGlobals.contains(e.key))
        e.key: e.value,
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
    // §640 (контракт 1.1.116) — ключ пишется ВСЕГДА, пусть `[]`: файл
    // описывает всю настройку (§1), и импорт отличает «правил нет» от
    // «файл о правилах молчит» (BACKUP.md §9 п. 7).
    'rules': ruleRecords,
    if (dns != null && dns.isNotEmpty) 'dns': dns,
    if (portableVars.isNotEmpty) 'vars': portableVars,
    if (routeFinal != null && routeFinal.isNotEmpty)
      'route': {'final': routeFinal},
    // §393 B8 — регистрации WARP: без них «Add WARP» на новой машине заводит
    // лишнюю device-запись в Cloudflare вместо переноса существующей.
    if (warp.isNotEmpty) 'warp': warp,
    // §704 — миксины итогового конфига, без `id`. Наша секция: лаунчеру —
    // запрос объявить ключ терпимым в `backup.schema.json`.
    if (mixins.isNotEmpty)
      'mixins': [for (final m in mixins) m.toBackupJson()],
    // §707 итер. 9 (контракт 1.1.158) — настройки телефона, все ключи секции.
    if (nativePrefs.isNotEmpty)
      'native_prefs': {
        for (final k in NativePrefsKeys.all)
          if (nativePrefs[k] != null) k: nativePrefs[k],
      },
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
List<Map<String, dynamic>> _exportSources({
  required List<ServerList> lists,
  required List<SourceChain> chains,
  required List<String>? sourceKeys,
  required List<LxBackupWarning> warnings,
}) {
  Map<String, dynamic>? ofList(ServerList list) =>
      _exportSource(list, warnings);
  Map<String, dynamic>? ofChain(SourceChain c) => exportBackupRecord(
        BackupRecord.chain,
        chainToRecord(c),
        c.tag,
        warnings,
      );
  if (sourceKeys == null) {
    return [
      for (final list in lists) ?ofList(list),
      for (final c in chains) ?ofChain(c),
    ];
  }
  final listByKey = {for (final l in lists) 'id:${l.id}': l};
  final chainByKey = {for (final c in chains) 'chain:${c.tag}': c};
  final seen = <String>{};
  final out = <Map<String, dynamic>>[];
  void takeList(String k, ServerList l) {
    final rec = ofList(l);
    if (rec != null) out.add(rec);
    seen.add(k);
  }

  void takeChain(String k, SourceChain c) {
    final rec = ofChain(c);
    if (rec != null) out.add(rec);
    seen.add(k);
  }

  for (final k in sourceKeys) {
    final l = listByKey[k];
    if (l != null) {
      takeList(k, l);
      continue;
    }
    final c = chainByKey[k];
    if (c != null) takeChain(k, c);
  }
  for (final e in listByKey.entries) {
    if (!seen.contains(e.key)) takeList(e.key, e.value);
  }
  for (final e in chainByKey.entries) {
    if (!seen.contains(e.key)) takeChain(e.key, e.value);
  }
  return out;
}

Map<String, dynamic>? _exportSource(
  ServerList list,
  List<LxBackupWarning> warnings,
) {
  final kind = switch (list) {
    SubscriptionServers() => BackupRecord.subscription,
    UserServer() => BackupRecord.server,
    FolderServers() => BackupRecord.folder,
  };
  final stored = sanitizeCoreRejectInBackupRecord(sourceToRecord(list), kind,
      forExport: true);
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
  // §722 — `body` (форма sing-box) — только у голого тела вида `singbox`;
  // Xray-тело — чужой диалект, его форму sing-box даёт перевод.
  if (origin is! Map || origin['kind'] != SourceDialect.singbox.code) {
    return node;
  }
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
