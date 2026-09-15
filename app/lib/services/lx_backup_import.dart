/// Импорт LX Backup в приложение: план слияния и его запись (слой 5, спека
/// §439 §2.5).
///
/// План — чистая функция файла и снимка приёмника ([planLxBackupImport]):
/// тот же код считает превью импорта на экране, запись после подтверждения,
/// раннер корпуса и golden-обвязку хранения. Сервис
/// ([LxBackupImportService]) читает снимок из хранения и пишет план штатными
/// сейверами.
///
/// D-117 (BACKUP.md §3) — известные цели импорта считает ПЛАН, одним списком
/// после слияния ([lxImportKnownTargets]): экран и прочие потребители его не
/// собирают.
///
/// §441 (SPEC 129 контракта) — план знает объявления переменных записей
/// шаблона приёмника ([LxImportReceiver.recordVars]): корневые
/// `dns_<tag>_<var>` переносит в записи серверов декодер (Н8), слияние DNS
/// накладывает `vars` по именам (§5.2), нормализует их и `vars` пресетов
/// (Н2–Н4) и выключает DNS-сервер с неизвестной целью маршрута (Н9). Всё это
/// считается в плане: превью показывает те же предупреждения, что запишет
/// импорт.
library;

import '../models/custom_rule.dart';
import '../models/direction.dart';
import '../models/parser_config.dart';
import '../models/server_list.dart';
import '../models/source_chain.dart';
import 'builder/rule_order.dart' show pinRequiredRuleNums;
import 'direction_mutations.dart';
import 'dns/dns_backup.dart';
import 'lx_backup.dart';
import 'record_vars.dart';
import 'settings_storage.dart';
import 'template_loader.dart';
import 'warp/warp_backup.dart';

/// Снимок приёмника, который читает слияние.
class LxImportReceiver {
  const LxImportReceiver({
    this.lists = const [],
    this.directions = const [],
    this.chains = const [],
    this.systemTags = const {},
    this.selectableRules = const [],
    this.receiverTargets = const {},
    this.dns = const LxDns(),
    this.recordVars = RecordVarDecls.none,
  });

  /// Источники приёмника в порядке списка.
  final List<ServerList> lists;

  /// Направления приёмника в порядке списка.
  final List<Direction> directions;

  /// Цепочки приёмника в порядке списка.
  final List<SourceChain> chains;

  /// Служебные теги шаблона приёмника ([templateSystemTags]). Пусто — шаблона
  /// нет, действуют [kLxImportDefaultSystemTags].
  final Set<String> systemTags;

  /// Пресеты шаблона приёмника: чужой пресет приезжает выключенным, а
  /// несортируемый встаёт на номер шаблона (BACKUP.md §9 п. 7). Пусто —
  /// шаблона нет, пресеты не проверяются.
  final List<SelectableRule> selectableRules;

  /// Прочие имена, которые приёмник знает сам: известные цели и занятые теги
  /// Направлений. У приложения пусто — всё названо полями выше; раннер
  /// корпуса передаёт сюда цели своей сцены.
  final Set<String> receiverTargets;

  /// §441 — DNS приёмника до импорта: записи серверов и правил и три
  /// скаляра (`dns_final`, `dns_strategy`, `dns_default_domain_resolver`).
  final LxDns dns;

  /// §441 — объявления переменных записей шаблона приёмника (SPEC 129 Н2,
  /// Н4, Н8). [RecordVarDecls.none] — шаблона нет, нормализации нет.
  final RecordVarDecls recordVars;
}

/// План импорта: разобранный файл и всё, что импорт запишет.
class LxImportPlan {
  const LxImportPlan({
    required this.raw,
    required this.file,
    required this.knownTargets,
    required this.directions,
    required this.appliedDirections,
    required this.directionPing,
    required this.listsBefore,
    required this.lists,
    required this.appliedSources,
    required this.touched,
    required this.chains,
    required this.appliedChains,
    required this.rules,
    this.dns,
  });

  /// Текст файла: запись пересчитывает план по свежему приёмнику.
  final String raw;

  /// Файл после сверки целей: правила с неизвестной целью выключены,
  /// `route.final` в никуда снят, `warnings` — полный отчёт импорта.
  final LxBackupFile file;

  /// Известные цели импорта (D-117); `null` — проверять было нечем.
  final Set<String>? knownTargets;

  /// Направления после слияния: приёмника и приехавшие, в конце списка.
  final List<Direction> directions;

  /// Сколько Направлений файла создано.
  final int appliedDirections;

  /// §409 — бюджеты теста узла созданных Направлений.
  final Map<String, LxDirectionPing> directionPing;

  /// Источники приёмника до импорта.
  final List<ServerList> listsBefore;

  /// Источники после слияния.
  final List<ServerList> lists;

  /// Сколько источников и узлов применено слиянием.
  final int appliedSources;

  /// Узлы, пришедшие или узнанные этим импортом (ось правил узлов).
  final List<BackupNodeRef> touched;

  /// Цепочки после слияния: приёмника и приехавшие, в конце списка.
  final List<SourceChain> chains;

  /// Сколько цепочек файла создано.
  final int appliedChains;

  /// Корневые правила на оси порядка (полная замена, BACKUP.md §9 п. 7).
  final List<CustomRule> rules;

  /// §393 B9 + §441 — DNS после слияния; `null` — секции DNS в файле нет.
  final DnsBackupApply? dns;
}

/// Итог записи плана: для строки результата на экране.
typedef LxImportResult = ({
  LxBackupFile file,
  int appliedDirections,
  int appliedChains,
  int appliedSettings,
});

/// Служебные теги шаблона (BACKUP.md §3): outbound'ы и endpoint'ы `config`
/// и теги `magic_nodes` (прямой канал и блокировка).
Set<String> templateSystemTags(WizardTemplate template) {
  final tags = <String>{};
  void addTags(Object? list) {
    if (list is! List) return;
    for (final o in list) {
      final tag = o is Map ? o['tag'] : null;
      if (tag is String && tag.trim().isNotEmpty) tags.add(tag.trim());
    }
  }

  addTags(template.config['outbounds']);
  addTags(template.config['endpoints']);
  for (final node in template.groupTemplates.magicNodes.values) {
    final tag = node.tag;
    if (tag != null && tag.trim().isNotEmpty) tags.add(tag.trim());
  }
  return tags;
}

/// План импорта файла [raw] в приёмник [receiver]. Чистая функция.
///
/// Порядок — порядок записи (BACKUP.md §9): Направления, источники, цепочки,
/// правила. Известные цели считаются после слияния источников, по тому, что
/// окажется у приёмника (D-117, [lxImportKnownTargets]); тот же набор —
/// корневые имена подъёма ссылок.
///
/// Бросает [FormatException] на файле, который не LX Backup.
LxImportPlan planLxBackupImport(String raw, LxImportReceiver receiver) {
  final chainTagsBefore = {for (final c in receiver.chains) c.tag};
  final decoded = decodeLxBackup(
    raw,
    takenTags: {
      ...receiver.receiverTargets,
      for (final d in receiver.directions) d.tag,
      ...chainTagsBefore,
    }..removeWhere((t) => t.isEmpty),
    knownPresets: {for (final p in receiver.selectableRules) p.presetId},
    recordVars: receiver.recordVars,
    // Merge цепочек идёт по СВОЕМУ пространству имён: `backup_chain_exists`
    // отвечает на вопрос «своя цепочка под этим тегом уже есть», а не «тег
    // вообще занят» (тёзку-Направление отсеет гейт ниже).
    knownChains: chainTagsBefore,
  );

  // §393 B5 — Направления ПЕРВЫМИ, до правил: приехавшее правило метит в
  // цель, которой на этой стороне ещё нет. Список не перезаписывается, а
  // дополняется в конец: инвариант «vpn-1 всегда есть» держится на этом, а
  // `include[]` приехавших (ссылки только вверх) остаётся осмысленным.
  // Парсер отсеял прямые тёзки; служебные и тёзки чужих `<tag>-auto` отсеивает
  // этот гейт — единственный на пути `bulkReplace`, который валидации не
  // делает.
  final directions = receiver.directions.toList();
  final usedDirectionTags = [for (final d in directions) d.tag];
  final directionPing = <String, LxDirectionPing>{};
  var appliedDirections = 0;
  for (final d in decoded.directions) {
    if (directionTagConflict(d.tag, usedDirectionTags) != null) continue;
    directions.add(d);
    usedDirectionTags.add(d.tag);
    appliedDirections++;
    // §409 — бюджет едет только с СОЗДАННЫМ Направлением.
    final ping = decoded.directionPing[d.tag];
    if (ping != null) directionPing[d.tag] = ping;
  }

  // §393 C9 — цепочки после Направлений: тот же гейт тегов, общий список
  // тегов цепочек и Направлений ловит коллизию outbound'ов, от которой ядро
  // отвергает конфиг целиком. Гейт смотрит только на тег, поэтому решается
  // до слияния источников; позиции переводятся после.
  final usedChainTags = <String>[
    ...chainTagsBefore,
    ...usedDirectionTags,
  ];
  final acceptedChainTags = <String>{};
  for (final c in decoded.chains) {
    if (directionTagConflict(c.tag, usedChainTags) != null) continue;
    usedChainTags.add(c.tag);
    acceptedChainTags.add(c.tag);
  }
  final chainTags = {...chainTagsBefore, ...acceptedChainTags};

  // §438 — источники ДО цепочек и правил: позиции цепочек переводятся по
  // карте папок слияния, правила узлов встают на общую ось с корневыми.
  final subMerge = mergeBackupSubscriptions(receiver.lists, decoded.subscriptions);
  final srvMerge = mergeBackupServers(
    subMerge.lists,
    decoded.servers,
    folders: decoded.folders,
    sourceIds: subMerge.ids,
    addedSources: subMerge.added,
    sourceDetours: subMerge.detours,
    rootNames: lxImportRootNames(
      directions: directions,
      chainTags: chainTags,
      systemTags: receiver.systemTags,
    ),
  );

  // D-117 — ОДИН список известных целей, после слияния.
  final known = lxImportKnownTargets(
    directions: directions,
    chainTags: chainTags,
    lists: srvMerge.lists,
    systemTags: receiver.systemTags,
    receiverTargets: receiver.receiverTargets,
  );
  var file = gateLxBackupTargets(decoded, known);

  final incomingChains = resolveBackupChainHops(
    file,
    srvMerge.lists,
    srvMerge.folderIds,
    linkOf: srvMerge.linkOf,
  );
  final chains = [
    ...receiver.chains,
    for (final c in incomingChains)
      if (acceptedChainTags.contains(c.tag)) c,
  ];

  // §438 — ось порядка одним проходом по корневым правилам и правилам узлов,
  // пришедших или узнанных этим импортом (BACKUP.md §9 п. 7).
  var rules = renumberBackupAxis(file.rules, srvMerge.lists, srvMerge.touched);
  // D-117 — несортируемый пресет встаёт на номер шаблона приёмника, откуда бы
  // номер ни приехал.
  if (pinRequiredRuleNums(rules, receiver.selectableRules)) {
    rules = sortRulesByAxis(rules);
  }

  // §441 (SPEC 129 §5.4) — `vars` правил-пресетов против шаблона приёмника:
  // необъявленное имя снимается с предупреждением (Н2), умолчание — молча
  // (Н4). Пресет, которого в шаблоне нет, — прежнее `backup_unknown_preset`,
  // его `vars` не трогаются.
  final extraWarnings = <LxBackupWarning>[];
  rules = normalizePresetRulesVars(
    rules,
    receiver.recordVars,
    onUndeclared: (presetId, name) => extraWarnings.add(LxBackupWarning(
        kWarnVarSkipped, 'preset:$presetId.vars.$name',
        reason: kVarSkippedUndeclared)),
  );

  // §393 B9 + §441 — DNS: слияние §5.2, Н2/Н4 против шаблона приёмника, Н9
  // по тому же единому списку целей, что у правил.
  //
  // §443 (SPEC 129 §5.5) — СНАЧАЛА своё хранение приёмника к нормам записи
  // (Н2/Н3/Н4 над `vars` template-серверов, молча), ПОТОМ наложение файла:
  // слияние работает с записями в той форме, в которой их запишет
  // репозиторий, и план (превью, раннер корпуса) показывает нормализованными
  // и записи, которых файл не коснулся. `rules[]` приёмника в план не входят:
  // секция замещается правилами файла, их `vars` нормализуются выше.
  final incomingDns = file.dns;
  final dns = incomingDns == null || incomingDns.isEmpty
      ? null
      : applyDnsBackup(
          incoming: incomingDns,
          servers: normalizeDnsServersVars(
              receiver.dns.servers, receiver.recordVars),
          rules: receiver.dns.rules,
          dnsFinal: receiver.dns.finalServer,
          strategy: receiver.dns.strategy,
          defaultDomainResolver: receiver.dns.defaultDomainResolver,
          recordVars: receiver.recordVars,
          knownTargets: known,
          warnings: extraWarnings,
        );
  if (extraWarnings.isNotEmpty) {
    file = file.copyWith(warnings: [...file.warnings, ...extraWarnings]);
  }

  return LxImportPlan(
    raw: raw,
    file: file,
    knownTargets: known,
    directions: directions,
    appliedDirections: appliedDirections,
    directionPing: directionPing,
    listsBefore: receiver.lists,
    lists: srvMerge.lists,
    appliedSources: subMerge.applied + srvMerge.applied,
    touched: srvMerge.touched,
    chains: chains,
    appliedChains: incomingChains
        .where((c) => acceptedChainTags.contains(c.tag))
        .length,
    rules: rules,
    dns: dns,
  );
}

/// Импорт LX Backup в хранение: снимок приёмника, план, запись.
///
/// Все пути LX-импорта приложения идут сюда (экран «Transfer to desktop»).
/// Полный бэкап хранения (`BackupService`, restore с Home, Debug API
/// `/backup/import`) — другой формат, LX-плана он не касается.
class LxBackupImportService {
  const LxBackupImportService();

  /// Снимок приёмника из хранения и шаблона.
  Future<LxImportReceiver> loadReceiver() async {
    final template = await TemplateLoader.load();
    final vars = await SettingsStorage.getAllVars();
    return LxImportReceiver(
      lists: await SettingsStorage.getServerLists(),
      directions: await SettingsStorage.getDirections(),
      chains: await SettingsStorage.getChains(),
      systemTags: templateSystemTags(template),
      selectableRules: template.selectableRules,
      dns: LxDns(
        servers: await SettingsStorage.getDnsServers(),
        rules: await SettingsStorage.getDnsRulesList(),
        finalServer: vars['dns_final'] ?? '',
        strategy: vars['dns_strategy'] ?? '',
        defaultDomainResolver: vars['dns_default_domain_resolver'] ?? '',
      ),
      recordVars: RecordVarDecls.fromTemplate(template),
    );
  }

  /// План для превью: что приедет и что не применится. Ничего не пишет.
  Future<LxImportPlan> prepare(String raw) async =>
      planLxBackupImport(raw, await loadReceiver());

  /// Запись импорта. План пересчитывается по свежему приёмнику: между превью
  /// и подтверждением хранение могло измениться (фоновое обновление
  /// подписок), и запись по устаревшему снимку затёрла бы изменения.
  Future<LxImportResult> apply(LxImportPlan preview) async {
    final plan = planLxBackupImport(preview.raw, await loadReceiver());
    final file = plan.file;

    if (plan.appliedDirections > 0) {
      await DirectionMutations.bulkReplace(plan.directions);
    }
    // §409 — после bulkReplace: ключ `ping_options.groups` без своего
    // Направления был бы сиротой.
    for (final entry in plan.directionPing.entries) {
      await SettingsStorage.setGroupPing(
        entry.key,
        url: entry.value.url,
        timeoutMs: entry.value.timeoutMs,
      );
    }
    if (plan.appliedChains > 0) await SettingsStorage.setChains(plan.chains);
    await SettingsStorage.saveCustomRules(plan.rules);

    final settings = await _applySections(plan);
    return (
      file: file,
      appliedDirections: plan.appliedDirections,
      appliedChains: plan.appliedChains,
      appliedSettings: settings,
    );
  }

  /// §393 B6-B9 — остальные секции. Возвращает число применённых сущностей.
  ///
  /// Всё идёт через штатные сейверы [SettingsStorage] с `flush: false` и одним
  /// flush в конце: прерывание в середине не оставит половину настроек.
  Future<int> _applySections(LxImportPlan plan) async {
    final file = plan.file;
    var applied = 0;

    // §393 B6 — переменные: фильтр переносимости сделал парсер.
    for (final e in file.vars.entries) {
      await SettingsStorage.setVar(e.key, e.value, flush: false);
      applied++;
    }

    // §393 B6 — route.final: цель уже сверена со списком известных целей.
    final routeFinal = file.routeFinal;
    if (routeFinal != null && routeFinal.isNotEmpty) {
      await SettingsStorage.saveRouteFinal(routeFinal, flush: false);
      applied++;
    }

    // §393 B6/B10 + §401 + §438 — источники. Сравнение поэлементно по
    // identity: `copyWith` даёт новый объект на месте старого, и длина списка
    // не меняется.
    final before = plan.listsBefore;
    final merged = plan.lists;
    applied += plan.appliedSources;
    final listsChanged = merged.length != before.length ||
        plan.touched.isNotEmpty ||
        [
          for (var i = 0; i < before.length; i++)
            if (!identical(merged[i], before[i])) i,
        ].isNotEmpty;
    if (listsChanged) await SettingsStorage.saveServerLists(merged);

    // §393 B9 — DNS. Merge (своя запись под тем же адресом сильнее, §441 —
    // наложение `vars` template-серверов) посчитан планом по свежему
    // приёмнику.
    final result = plan.dns;
    if (result != null) {
      await SettingsStorage.saveDnsServers(result.servers, flush: false);
      await SettingsStorage.saveDnsRulesList(result.rules, flush: false);
      await SettingsStorage.setVar('dns_final', result.dnsFinal, flush: false);
      await SettingsStorage.setVar('dns_strategy', result.strategy,
          flush: false);
      // §438 — третий скаляр секции; у 0.x он пуст, и var остаётся своей.
      if (result.defaultDomainResolver.isNotEmpty) {
        await SettingsStorage.setVar(
            'dns_default_domain_resolver', result.defaultDomainResolver,
            flush: false);
      }
      applied += result.applied;
    }

    // §393 B8 — регистрации WARP: живую не перетирает.
    for (final entry in file.warp) {
      if (entry['type'] == 'wg') {
        if (await SettingsStorage.getWarpAccount() != null) continue;
        final acc = warpAccountFromBackup(entry);
        if (acc == null) continue;
        await SettingsStorage.setWarpAccount(acc, flush: false);
        applied++;
      } else if (entry['type'] == 'masque') {
        if (await SettingsStorage.getMasqueAccount() != null) continue;
        final acc = masqueAccountFromBackup(entry);
        if (acc == null) continue;
        await SettingsStorage.setMasqueAccount(acc, flush: false);
        applied++;
      }
    }

    await SettingsStorage.flushToDisk();
    return applied;
  }
}
