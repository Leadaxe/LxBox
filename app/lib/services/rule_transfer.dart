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
///   "rules": [ { ...CustomRule.toJson()... } ]
/// }
/// ```
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
    'rules': [for (final r in rules) r.toJson()],
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

  // `CustomRule.fromJson` без kind молча падает в inline (backward-compat
  // storage) — для импорта это превратило бы мусор в пустое inline-правило,
  // поэтому kind проверяется ДО fromJson.
  final kindRaw = rawEntry['kind']?.toString();
  final knownKind =
      CustomRuleKind.values.any((k) => k.name == kindRaw);
  final label = rawEntry['name']?.toString() ?? '';
  if (!knownKind) {
    return SanitizedImportRule(
      displayLabel: label,
      rejectReason: ImportRuleRejectReason.unsupportedEntry,
    );
  }

  // id перегенерируется конструктором: без ключа `id` fromJson получает null
  // и `CustomRule` сам выдаёт новый UUID — повторный импорт не коллизирует.
  final cleaned = Map<String, dynamic>.from(rawEntry)..remove('id');
  final CustomRule parsed;
  try {
    parsed = CustomRule.fromJson(cleaned);
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
