import 'dart:convert';

import '../config/consts.dart'
    show kBlockOutboundTag, kDirectOutboundTag;
import '../models/custom_rule.dart';
import '../models/dns_ref.dart';
import '../models/parser_config.dart';
import 'builder/rule_order.dart' show nextUserRuleNum;
import 'parser/uri_utils.dart' show newUuidV4;

/// §396 — обмен правилами роутинга файлом (export/import выбранных правил).
///
/// Wire-format — конверт, симметричный бэкапу (`backup_service.dart`):
///
/// ```json
/// {
///   "app": "lxbox",
///   "kind": "rules",
///   "format": 1,
///   "created_at": "<ISO8601 UTC>",
///   "source_app_version": "2.20.10+22010",
///   "rules": [ { "id": …, "name": …, "enabled": …, "kind": …, … } ]
/// }
/// ```
///
/// Элемент `rules[]` пишет и читает кодек файла внизу модуля
/// ([_ruleToFile] / [_ruleFromFile]), а не форма хранения: формат файла
/// меняется своим номером, независимо от хранения.
///
/// Экспорт пишет правила as is (включая `id`/`enabled`/`num`) — вся санация
/// на стороне импорта: id перегенерируется, чужая ось `num` не переносится,
/// висячие ссылки лечатся (§5 спеки).

/// Версия схемы конверта. Читатель отвергает `format > 1` — файл из более
/// новой версии приложения может нести несовместимую семантику полей.
const int kRulesExportFormatVersion = 1;

/// Дефолт лечения висячего outbound-тега — тот же, что у удаления Направления
/// (`SettingsStorage.deleteDirection`, §202): основное Направление, существует всегда.
const String kImportOutboundFallback = 'vpn-1';

/// Build JSON-строки экспорта для выбранных правил (+ опциональные
/// DNS-секции второго экрана — сырые элементы storage as is).
String buildRulesExport(
  List<CustomRule> rules, {
  String? appVersion,
  List<Map<String, dynamic>> dnsServers = const [],
  List<Map<String, dynamic>> dnsRules = const [],
}) {
  final out = <String, dynamic>{
    'app': 'lxbox',
    'kind': 'rules',
    'format': kRulesExportFormatVersion,
    'created_at': DateTime.now().toUtc().toIso8601String(),
    if (appVersion != null && appVersion.isNotEmpty)
      'source_app_version': appVersion,
    'rules': [for (final r in rules) _ruleToFile(r)],
    if (dnsServers.isNotEmpty) 'dns_servers': dnsServers,
    if (dnsRules.isNotEmpty) 'dns_rules': dnsRules,
  };
  return const JsonEncoder.withIndent('  ').convert(out);
}

/// Suggested filename экспорта: `lxbox-rules-{YYYYMMDD-HHMM}.json`
/// (образец — `BackupService.suggestedFilename`).
String suggestedRulesFilename() {
  final now = DateTime.now();
  String two(int v) => v.toString().padLeft(2, '0');
  final date = '${now.year}${two(now.month)}${two(now.day)}'
      '-${two(now.hour)}${two(now.minute)}';
  return 'lxbox-rules-$date.json';
}

/// Распарсенный конверт импорта. Элементы [rawRules] намеренно dynamic —
/// per-element валидация (вплоть до «мусор, пропустить») живёт в
/// [sanitizeImportedRule], чтобы один битый элемент не ронял весь файл.
class RulesImportContents {
  const RulesImportContents({
    this.createdAt,
    this.sourceAppVersion,
    required this.rawRules,
    this.rawDnsServers = const [],
    this.rawDnsRules = const [],
  });

  final DateTime? createdAt;
  final String? sourceAppVersion;
  final List<dynamic> rawRules;

  /// Опциональные DNS-секции конверта (`dns_servers[]` / `dns_rules[]`).
  final List<dynamic> rawDnsServers;
  final List<dynamic> rawDnsRules;
}

/// Parse + validate конверта. Throws [FormatException] на нечитаемый файл.
/// Тексты — как у `BackupService.parseImport`: английские, UI показывает
/// `e.message` в снекбаре as is.
RulesImportContents parseRulesImport(String raw) {
  final dynamic decoded;
  try {
    decoded = jsonDecode(raw);
  } catch (_) {
    throw const FormatException(
        'Not a valid JSON file. Make sure you picked a LxBox rules file.');
  }

  if (decoded is! Map<String, dynamic>) {
    throw const FormatException('Rules file root must be a JSON object.');
  }

  final app = decoded['app']?.toString();
  final kind = decoded['kind']?.toString();
  if (app != 'lxbox' || kind != 'rules') {
    // kind: backup — самая вероятная путаница: подсказываем, куда его нести.
    if (app == 'lxbox' && kind == 'backup') {
      throw const FormatException(
          'This is a LxBox backup file — restore it via Settings → Backup.');
    }
    throw const FormatException(
        'Not a LxBox rules file (missing or invalid app/kind markers).');
  }

  final format = decoded['format'];
  if (format is! int || format < 1) {
    throw const FormatException('Rules file has no valid format version.');
  }
  if (format > kRulesExportFormatVersion) {
    throw const FormatException(
        'Rules file is from a newer app version. Update LxBox and retry.');
  }

  final rules = decoded['rules'];
  if (rules is! List || rules.isEmpty) {
    throw const FormatException('Rules file contains no rules.');
  }

  DateTime? createdAt;
  final createdRaw = decoded['created_at']?.toString();
  if (createdRaw != null) {
    createdAt = DateTime.tryParse(createdRaw);
  }

  final dnsServers = decoded['dns_servers'];
  final dnsRules = decoded['dns_rules'];

  return RulesImportContents(
    createdAt: createdAt,
    sourceAppVersion: decoded['source_app_version']?.toString(),
    rawRules: rules,
    rawDnsServers: dnsServers is List ? dnsServers : const [],
    rawDnsRules: dnsRules is List ? dnsRules : const [],
  );
}

/// Теги DNS-серверов, на которые ссылаются правила (`dns.serverTag` +
/// `resolve.serverTag`). Экспорт предотмечает ими секцию DNS servers.
Set<String> referencedDnsServerTags(Iterable<CustomRule> rules) {
  final tags = <String>{};
  for (final r in rules) {
    final dnsTag = r.dns?.serverTag;
    if (dnsTag != null && dnsTag.isNotEmpty) tags.add(dnsTag);
    final resolveTag = r.resolve?.serverTag;
    if (resolveTag != null && resolveTag.isNotEmpty) tags.add(resolveTag);
  }
  return tags;
}

/// Типизированное предупреждение санации — текст рендерит UI через
/// `getLocalText` (§285: сервис строк не показывает).
enum ImportRuleWarningKind {
  /// `outbound` (или preset-override) ссылался на несуществующее Направление —
  /// заменён на [kImportOutboundFallback], правило выключено.
  outboundMissing,

  /// `dns.serverTag` ссылался на несуществующий DNS-сервер — DNS-опция
  /// выключена, тег очищен (`forceIpv4` сохранён — глушилке §256 сервер
  /// не нужен).
  dnsServerMissing,

  /// `resolve.serverTag` ссылался на несуществующий DNS-сервер — сброшен
  /// в '' (= auto, §247).
  resolveServerMissing,
}

class ImportRuleWarning {
  const ImportRuleWarning(this.kind, this.missingTag);

  final ImportRuleWarningKind kind;

  /// Тег, которого не оказалось у получателя (для подстановки в текст).
  final String missingTag;
}

/// Причина, по которой элемент файла неимпортируем (disabled в превью).
enum ImportRuleRejectReason {
  /// Элемент — не объект или `kind` не из известного enum'а (файл от более
  /// новой версии с новым видом правил; остальные элементы живы).
  unsupportedEntry,

  /// §398 — пресеты вне обмена: пресет есть у каждого получателя (он из
  /// шаблона приложения), переносить нечего. Файлы v2.20.11 могли нести
  /// пресет в `rules[]` — отвергаем на импорте.
  presetNotTransferable,

  /// §398 — правило с таким видимым именем у получателя уже есть. Дублей не
  /// создаём: неотличимые по имени правила невозможно осмысленно удалять.
  nameExists,

  /// preset: `presetId` отсутствует в шаблоне получателя.
  unknownPreset,
}

/// Итог санации одного элемента `rules[]`.
class SanitizedImportRule {
  const SanitizedImportRule({
    this.rule,
    required this.displayLabel,
    this.warnings = const [],
    this.rejectReason,
    this.needsSrsDownload = false,
  });

  /// Готовое к вставке правило (id уже перегенерирован). null → см.
  /// [rejectReason].
  final CustomRule? rule;

  /// Имя для строки превью: name из файла; для preset — live-label шаблона
  /// получателя (fallback: name/presetId из файла).
  final String displayLabel;

  final List<ImportRuleWarning> warnings;
  final ImportRuleRejectReason? rejectReason;

  /// Правилу нужен `.srs`-файл (CustomRuleSrs или preset с remote
  /// rule_set'ами) — приезжает выключенным, юзеру нужен ☁ (паттерн
  /// `_copyPreset`).
  final bool needsSrsDownload;

  bool get importable => rule != null;
}

/// Санация одного элемента `rules[]` (§5 спеки §396).
///
/// [directionTags] — теги ВСЕХ Направлений получателя (включая выключенные: ссылку
/// на выключенное Направление лечит существующая механика варнингов §274/§277).
/// [dnsServerTags] — union storage-refs ∪ template (источник дропдауна §117).
/// [existingNames] — §398: видимые имена правил получателя
/// (`visibleRuleNames`, §279). Совпадение → элемент неимпортируем: дублей по
/// имени не создаём, иначе их невозможно осмысленно различать и удалять.
/// Вызывающий добавляет в набор имена уже вставленных элементов файла, чтобы
/// два одноимённых правила в одном файле не прошли оба.
///
/// `num` здесь НЕ трогается — это забота [insertImportedRule].
SanitizedImportRule sanitizeImportedRule(
  dynamic rawEntry, {
  required Set<String> directionTags,
  required Set<String> dnsServerTags,
  required WizardTemplate template,
  Set<String> existingNames = const {},
}) {
  if (rawEntry is! Map<String, dynamic>) {
    return const SanitizedImportRule(
      displayLabel: '',
      rejectReason: ImportRuleRejectReason.unsupportedEntry,
    );
  }

  // Элемент без известного kind — мусор или вид из более новой версии: не
  // угадываем его как inline, отвергаем.
  final kindRaw = rawEntry['kind']?.toString();
  final kind =
      CustomRuleKind.values.where((k) => k.name == kindRaw).firstOrNull;
  final label = rawEntry['name']?.toString() ?? '';
  if (kind == null) {
    return SanitizedImportRule(
      displayLabel: label,
      rejectReason: ImportRuleRejectReason.unsupportedEntry,
    );
  }

  // id перегенерируется конструктором: кодек файла `id` не читает, и
  // `CustomRule` сам выдаёт новый UUID — повторный импорт не коллизирует.
  final CustomRule parsed;
  try {
    parsed = _ruleFromFile(rawEntry, kind);
  } catch (_) {
    return SanitizedImportRule(
      displayLabel: label,
      rejectReason: ImportRuleRejectReason.unsupportedEntry,
    );
  }

  // §398 — пресеты вне обмена: пресет есть у каждого получателя (он из
  // шаблона приложения). Файлы v2.20.11 могли нести его в `rules[]`, а
  // вторая копия пресета в списке ещё и неудаляема (seed §264 держит
  // инвариант по presetId) — отвергаем на входе.
  if (parsed.kind == CustomRuleKind.preset) {
    return SanitizedImportRule(
      displayLabel: label.isNotEmpty ? label : parsed.presetId,
      rejectReason: ImportRuleRejectReason.presetNotTransferable,
    );
  }

  // §398 — дубль по видимому имени не создаём.
  if (existingNames.contains(parsed.name)) {
    return SanitizedImportRule(
      displayLabel: parsed.name,
      rejectReason: ImportRuleRejectReason.nameExists,
    );
  }

  final warnings = <ImportRuleWarning>[];
  var rule = parsed;
  var forceDisable = false;

  // ── outbound: тег Направления получателя, спец-теги или пусто («как в шаблоне»).
  final validOutbounds = <String>{
    '',
    kOutboundReject,
    kBlockOutboundTag,
    kDirectOutboundTag,
    ...directionTags,
  };
  final outbound = rule.outbound;
  if (!validOutbounds.contains(outbound)) {
    warnings.add(
        ImportRuleWarning(ImportRuleWarningKind.outboundMissing, outbound));
    rule = rule.withOutbound(kImportOutboundFallback);
    // Включённое правило сразу погнало бы трафик не туда, куда задумал
    // автор, — выключаем; причина названа в превью (§261: не мутируем молча).
    forceDisable = true;
  }

  // ── dns.serverTag / resolve.serverTag: только inline/srs (у preset DNS
  // живёт в шаблоне). Лечение мутирует копию через type-specific copyWith.
  final dns = rule.dns;
  if (dns != null &&
      dns.serverTag.isNotEmpty &&
      !dnsServerTags.contains(dns.serverTag)) {
    warnings.add(ImportRuleWarning(
        ImportRuleWarningKind.dnsServerMissing, dns.serverTag));
    rule = _withDns(
        rule, dns.copyWith(enabled: false, serverTag: ''));
  }
  final resolve = rule.resolve;
  if (resolve != null &&
      resolve.serverTag.isNotEmpty &&
      !dnsServerTags.contains(resolve.serverTag)) {
    warnings.add(ImportRuleWarning(
        ImportRuleWarningKind.resolveServerMissing, resolve.serverTag));
    rule = _withResolve(rule, resolve.copyWith(serverTag: ''));
  }

  // ── srs: кэша `.srs` у получателя нет — правило приезжает выключенным
  // («tap ☁ to download, then enable», предикат `_copyPreset`). §398 —
  // preset-ветки здесь больше нет: пресеты до этой точки не доходят.
  final needsSrs = rule is CustomRuleSrs;
  if (needsSrs || forceDisable) {
    rule = rule.withEnabled(false);
  }

  return SanitizedImportRule(
    rule: rule,
    displayLabel: rule.name,
    warnings: warnings,
    needsSrsDownload: needsSrs,
  );
}

/// Вставка санированного правила в список (мутирует [target]): назначение
/// `num` (§370) + append. Сортировку по оси и персист делает вызывающий —
/// один раз на весь импорт.
///
/// §398 — имя НЕ мутируется: конфликтные по имени элементы отбраковываются
/// санацией и сюда не доходят (дублей не создаём). Пресетов здесь тоже нет.
/// `num` — [nextUserRuleNum]: каждое следующее правило видит уже вставленные
/// предыдущие, поэтому мульти-импорт нумеруется последовательно.
CustomRule insertImportedRule(
  List<CustomRule> target,
  CustomRule rule, {
  required WizardTemplate template,
}) {
  rule.orderNum = nextUserRuleNum(target);
  target.add(rule);
  return rule;
}

// ─── §396 DNS-секции: санация dns_servers[] / dns_rules[] ────────────────

/// Почему элемент DNS-секции не будет импортирован (disabled в превью).
enum ImportDnsSkipReason {
  /// Не парсится (`DnsServerRef.fromJson`/`DnsRuleRef.fromJson` → null)
  /// или сам элемент — не объект.
  unsupportedEntry,

  /// Сервер/правило с этим tag/именем/дублем уже есть у получателя —
  /// его настройки НЕ перезаписываются чужим файлом.
  alreadyExists,

  /// template-сущность, которой нет в шаблоне этой версии приложения.
  notAvailable,

  /// `kind: preset` — такие refs резолвер §294 порождает и чистит сам
  /// при включении routing-пресета; поштучно не переносятся.
  managedByPresets,
}

/// Итог санации одного элемента DNS-секции. [item] — готовый к вставке
/// raw-объект (для srs-правила `id` уже перегенерирован).
class SanitizedImportDnsItem {
  const SanitizedImportDnsItem({
    this.item,
    required this.label,
    this.skipReason,
  });

  final Map<String, dynamic>? item;
  final String label;
  final ImportDnsSkipReason? skipReason;

  bool get importable => item != null;
}

/// Санация элемента `dns_servers[]`.
///
/// [existingTags] — теги `dns_options.servers` получателя;
/// [templateServerTags] — теги шаблонных серверов его версии приложения.
SanitizedImportDnsItem sanitizeImportedDnsServer(
  dynamic raw, {
  required Set<String> existingTags,
  required Set<String> templateServerTags,
}) {
  if (raw is! Map) {
    return const SanitizedImportDnsItem(
        label: '', skipReason: ImportDnsSkipReason.unsupportedEntry);
  }
  final map = raw.cast<String, dynamic>();
  final ref = DnsServerRef.fromJson(map);
  if (ref == null) {
    return SanitizedImportDnsItem(
      label: map['tag']?.toString() ?? '',
      skipReason: ImportDnsSkipReason.unsupportedEntry,
    );
  }
  final label = (ref.description?.isNotEmpty ?? false)
      ? '${ref.description} (${ref.tag})'
      : ref.tag;
  if (ref is DnsServerPreset) {
    return SanitizedImportDnsItem(
        label: label, skipReason: ImportDnsSkipReason.managedByPresets);
  }
  if (existingTags.contains(ref.tag)) {
    return SanitizedImportDnsItem(
        label: label, skipReason: ImportDnsSkipReason.alreadyExists);
  }
  if (ref is DnsServerTemplate && !templateServerTags.contains(ref.tag)) {
    return SanitizedImportDnsItem(
        label: label, skipReason: ImportDnsSkipReason.notAvailable);
  }
  return SanitizedImportDnsItem(item: ref.toJson(), label: label);
}

/// Санация элемента `dns_rules[]`.
///
/// [existingRules] — сырые `dns_options.rules` получателя;
/// [template] — для проверки preset/template-правил.
SanitizedImportDnsItem sanitizeImportedDnsRule(
  dynamic raw, {
  required List<Map<String, dynamic>> existingRules,
  required WizardTemplate template,
}) {
  if (raw is! Map) {
    return const SanitizedImportDnsItem(
        label: '', skipReason: ImportDnsSkipReason.unsupportedEntry);
  }
  final map = raw.cast<String, dynamic>();
  final ref = DnsRuleRef.fromJson(map);
  if (ref == null) {
    return SanitizedImportDnsItem(
      label: map['name']?.toString() ?? map['presetId']?.toString() ?? '',
      skipReason: ImportDnsSkipReason.unsupportedEntry,
    );
  }

  switch (ref) {
    case DnsRulePreset():
      final exists = existingRules.any(
          (r) => r['kind'] == 'preset' && r['presetId'] == ref.presetId);
      if (exists) {
        return SanitizedImportDnsItem(
            label: ref.presetId,
            skipReason: ImportDnsSkipReason.alreadyExists);
      }
      final known =
          template.selectableRules.any((sr) => sr.presetId == ref.presetId);
      if (!known) {
        return SanitizedImportDnsItem(
            label: ref.presetId,
            skipReason: ImportDnsSkipReason.notAvailable);
      }
      return SanitizedImportDnsItem(item: ref.toJson(), label: ref.presetId);

    case DnsRuleTemplate():
      final exists = existingRules
          .any((r) => r['kind'] == 'template' && r['name'] == ref.name);
      if (exists) {
        return SanitizedImportDnsItem(
            label: ref.name, skipReason: ImportDnsSkipReason.alreadyExists);
      }
      final known = (template.dnsOptions['rules'] as List<dynamic>? ??
              const [])
          .any((r) => r is Map && r['name'] == ref.name);
      if (!known) {
        return SanitizedImportDnsItem(
            label: ref.name, skipReason: ImportDnsSkipReason.notAvailable);
      }
      return SanitizedImportDnsItem(item: ref.toJson(), label: ref.name);

    case DnsRuleInline():
      // Точный дубль (name + rule-body) → skip; иначе импортируем как есть.
      final encoded = jsonEncode(ref.toJson());
      final dup = existingRules.any((r) =>
          r['kind'] == 'inline' &&
          jsonEncode(DnsRuleRef.fromJson(r)?.toJson() ?? const {}) == encoded);
      if (dup) {
        return SanitizedImportDnsItem(
            label: ref.name, skipReason: ImportDnsSkipReason.alreadyExists);
      }
      // `enabled` — вне типизированной модели (форма §294), но живёт в raw
      // storage: переносим значение автора вместе с правилом.
      final out = ref.toJson();
      if (map['enabled'] is bool) out['enabled'] = map['enabled'];
      return SanitizedImportDnsItem(item: out, label: ref.name);

    case DnsRuleSrs():
      final dup = existingRules
          .any((r) => r['kind'] == 'srs' && r['name'] == ref.name);
      if (dup) {
        return SanitizedImportDnsItem(
            label: ref.name, skipReason: ImportDnsSkipReason.alreadyExists);
      }
      // Кэш-файл `.srs` привязан к id — у получателя свой, id перегенерируем.
      final out = ref.copyWith(id: newUuidV4()).toJson();
      if (map['enabled'] is bool) out['enabled'] = map['enabled'];
      return SanitizedImportDnsItem(item: out, label: ref.name);
  }
}

// ─── Кодек элемента `rules[]`, format 1 ──────────────────────────────────
// Форма элемента заморожена вместе с `format: 1`: ключи camelCase, `kind` —
// дискриминатор, пустые списки и дефолты не пишутся. Порядок ключей тот же,
// что в файлах, выпущенных до §439, — экспорт тех же правил даёт тот же файл.

Map<String, dynamic> _ruleToFile(CustomRule r) => switch (r) {
      CustomRuleInline() => {
          ..._fileHead(r),
          if (r.domains.isNotEmpty) 'domains': r.domains,
          if (r.domainSuffixes.isNotEmpty) 'domainSuffixes': r.domainSuffixes,
          if (r.domainKeywords.isNotEmpty) 'domainKeywords': r.domainKeywords,
          if (r.ipCidrs.isNotEmpty) 'ipCidrs': r.ipCidrs,
          ..._fileFilters(r),
        },
      CustomRuleSrs() => {
          ..._fileHead(r),
          if (r.srsUrl.isNotEmpty) 'srsUrl': r.srsUrl,
          // ## 12 — полный список только при двух и более наборах.
          if (r.srsUrls.length > 1) 'srsUrls': r.srsUrls,
          ..._fileFilters(r),
          if (r.updateIntervalHours != kDefaultSrsTtlHours)
            'updateIntervalHours': r.updateIntervalHours,
        },
      CustomRulePreset() => {
          ..._fileHead(r),
          'presetId': r.presetId,
          if (r.varsValues.isNotEmpty) 'varsValues': r.varsValues,
        },
      CustomRuleJson() => {
          ..._fileHead(r),
          'json': r.json,
        },
    };

Map<String, dynamic> _fileHead(CustomRule r) => {
      'id': r.id,
      'name': r.name,
      'enabled': r.enabled,
      'kind': r.kind.name,
      if (r.orderNum != null) 'num': r.orderNum,
    };

/// Доп-фильтры, `outbound` и опции inline/srs — общий хвост двух видов.
Map<String, dynamic> _fileFilters(CustomRule r) => {
      if (r.ports.isNotEmpty) 'ports': r.ports,
      if (r.portRanges.isNotEmpty) 'portRanges': r.portRanges,
      if (r.packages.isNotEmpty) 'packages': r.packages,
      if (r.protocols.isNotEmpty) 'protocols': r.protocols,
      if (r.network.isNotEmpty) 'network': r.network,
      if (r.ipIsPrivate) 'ipIsPrivate': true,
      if (r.sourceIpCidrs.isNotEmpty) 'sourceIpCidrs': r.sourceIpCidrs,
      if (r.sourceIpIsPrivate) 'sourceIpIsPrivate': true,
      if (r.inbounds.isNotEmpty) 'inbounds': r.inbounds,
      if (r.wifiSsids.isNotEmpty) 'wifiSsids': r.wifiSsids,
      if (r.wifiBssids.isNotEmpty) 'wifiBssids': r.wifiBssids,
      'outbound': r.outbound,
      if (r.dns != null) 'dns': _dnsToFile(r.dns!),
      if (r.resolve != null) 'resolve': _resolveToFile(r.resolve!),
    };

Map<String, dynamic> _dnsToFile(RuleDns d) => {
      'enabled': d.enabled,
      'serverTag': d.serverTag,
      if (d.forceIpv4) 'forceIpv4': true,
    };

Map<String, dynamic> _resolveToFile(RuleResolve r) => {
      'only': r.only,
      if (r.strategy.isNotEmpty) 'strategy': r.strategy,
      if (r.serverTag.isNotEmpty) 'serverTag': r.serverTag,
      if (r.disableCache) 'disableCache': true,
      if (r.disableOptimisticCache) 'disableOptimisticCache': true,
      if (r.rewriteTtl != null) 'rewriteTtl': r.rewriteTtl,
      if (r.timeout.isNotEmpty) 'timeout': r.timeout,
      if (r.clientSubnet.isNotEmpty) 'clientSubnet': r.clientSubnet,
    };

/// Элемент `rules[]` вида [kind] → правило с новым `id`. Поле неверного типа
/// (`name` числом, `enabled` строкой, …) бросает — вызывающий отвергает
/// элемент. Каждый вид читает только свои ключи: чужой ключ, даже битый,
/// элемент не роняет. `outbound` без значения — прежнее имя `target`, затем
/// direct-out.
CustomRule _ruleFromFile(Map<String, dynamic> j, CustomRuleKind kind) {
  final name = (j['name'] as String?) ?? '';
  final enabled = (j['enabled'] as bool?) ?? true;
  final orderNum = j['num'] as int?;
  switch (kind) {
    case CustomRuleKind.inline:
      return CustomRuleInline(
        name: name,
        enabled: enabled,
        orderNum: orderNum,
        domains: _fileStrings(j['domains']),
        domainSuffixes: _fileStrings(j['domainSuffixes']),
        domainKeywords: _fileStrings(j['domainKeywords']),
        ipCidrs: _fileStrings(j['ipCidrs']),
        ports: _fileStrings(j['ports']),
        portRanges: _fileStrings(j['portRanges']),
        packages: _fileStrings(j['packages']),
        protocols: _fileStrings(j['protocols']),
        network: _fileStrings(j['network']),
        ipIsPrivate: (j['ipIsPrivate'] as bool?) ?? false,
        sourceIpCidrs: _fileStrings(j['sourceIpCidrs']),
        sourceIpIsPrivate: (j['sourceIpIsPrivate'] as bool?) ?? false,
        inbounds: _fileStrings(j['inbounds']),
        wifiSsids: _fileStrings(j['wifiSsids']),
        wifiBssids: _fileStrings(j['wifiBssids']),
        outbound: _fileOutbound(j),
        dns: _dnsFromFile(j['dns']),
        resolve: _resolveFromFile(j['resolve']),
      );
    case CustomRuleKind.srs:
      final ttl = j['updateIntervalHours'];
      final ttlHours = ttl is num ? ttl.toInt() : null;
      return CustomRuleSrs(
        name: name,
        enabled: enabled,
        orderNum: orderNum,
        srsUrl: (j['srsUrl'] as String?) ?? '',
        srsUrls: _fileStrings(j['srsUrls']),
        ports: _fileStrings(j['ports']),
        portRanges: _fileStrings(j['portRanges']),
        packages: _fileStrings(j['packages']),
        protocols: _fileStrings(j['protocols']),
        network: _fileStrings(j['network']),
        ipIsPrivate: (j['ipIsPrivate'] as bool?) ?? false,
        sourceIpCidrs: _fileStrings(j['sourceIpCidrs']),
        sourceIpIsPrivate: (j['sourceIpIsPrivate'] as bool?) ?? false,
        inbounds: _fileStrings(j['inbounds']),
        wifiSsids: _fileStrings(j['wifiSsids']),
        wifiBssids: _fileStrings(j['wifiBssids']),
        outbound: _fileOutbound(j),
        dns: _dnsFromFile(j['dns']),
        resolve: _resolveFromFile(j['resolve']),
        // §366 — нет значения, мусор, отрицательное → дефолт; 0 = Never.
        updateIntervalHours: ttlHours == null || ttlHours < 0
            ? kDefaultSrsTtlHours
            : ttlHours,
      );
    case CustomRuleKind.preset:
      final vars = j['varsValues'];
      return CustomRulePreset(
        name: name,
        enabled: enabled,
        orderNum: orderNum,
        presetId: (j['presetId'] as String?) ?? '',
        varsValues: vars is Map
            ? {
                for (final e in vars.entries)
                  if (e.key is String)
                    e.key as String: e.value?.toString() ?? '',
              }
            : const {},
      );
    case CustomRuleKind.json:
      return CustomRuleJson(
        name: name,
        enabled: enabled,
        orderNum: orderNum,
        json: (j['json'] as String?) ?? '',
      );
  }
}

String _fileOutbound(Map<String, dynamic> j) =>
    (j['outbound'] as String?) ?? (j['target'] as String?) ?? kDirectOutboundTag;

List<String> _fileStrings(Object? v) =>
    v is List ? [for (final e in v) e.toString()] : const [];

RuleDns? _dnsFromFile(Object? v) {
  if (v is! Map) return null;
  return RuleDns(
    enabled: v['enabled'] == true,
    serverTag: v['serverTag']?.toString() ?? '',
    forceIpv4: v['forceIpv4'] == true,
  );
}

RuleResolve? _resolveFromFile(Object? v) {
  if (v is! Map) return null;
  return RuleResolve(
    only: v['only'] == true,
    strategy: v['strategy']?.toString() ?? '',
    serverTag: v['serverTag']?.toString() ?? '',
    disableCache: v['disableCache'] == true,
    disableOptimisticCache: v['disableOptimisticCache'] == true,
    rewriteTtl: switch (v['rewriteTtl']) {
      final int n when n >= 0 => n,
      final String s => int.tryParse(s),
      _ => null,
    },
    timeout: v['timeout']?.toString() ?? '',
    clientSubnet: v['clientSubnet']?.toString() ?? '',
  );
}

// ─── helpers: type-preserving запись dns/resolve ─────────────────────────
// У sealed-базы нет withDns/withResolve (опции есть только у inline/srs) —
// локальный pattern-match вместо расширения базового класса.

CustomRule _withDns(CustomRule rule, RuleDns dns) => switch (rule) {
      CustomRuleInline() => rule.copyWith(dns: dns),
      CustomRuleSrs() => rule.copyWith(dns: dns),
      _ => rule,
    };

CustomRule _withResolve(CustomRule rule, RuleResolve resolve) =>
    switch (rule) {
      CustomRuleInline() => rule.copyWith(resolve: resolve),
      CustomRuleSrs() => rule.copyWith(resolve: resolve),
      _ => rule,
    };
