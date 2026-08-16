import 'dart:convert';

import '../config/consts.dart'
    show kBlockOutboundTag, kDirectOutboundTag;
import '../models/custom_rule.dart';
import '../models/parser_config.dart';
import '../models/preset_rule_set.dart' show remoteRuleSetsOfPreset;
import 'builder/rule_order.dart' show nextUserRuleNum;
import 'rule_display_names.dart' show visibleRuleNames;

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

/// Дефолт лечения висячего outbound-тега — тот же, что у удаления канала
/// (`SettingsStorage.deleteChannel`, §202): основной канал, существует всегда.
const String kImportOutboundFallback = 'vpn-1';

/// Build JSON-строки экспорта для выбранных правил.
String buildRulesExport(List<CustomRule> rules, {String? appVersion}) {
  final out = <String, dynamic>{
    'app': 'lxbox',
    'kind': 'rules',
    'format': kRulesExportFormatVersion,
    'created_at': DateTime.now().toUtc().toIso8601String(),
    if (appVersion != null && appVersion.isNotEmpty)
      'source_app_version': appVersion,
    'rules': [for (final r in rules) r.toJson()],
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
  });

  final DateTime? createdAt;
  final String? sourceAppVersion;
  final List<dynamic> rawRules;
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

  return RulesImportContents(
    createdAt: createdAt,
    sourceAppVersion: decoded['source_app_version']?.toString(),
    rawRules: rules,
  );
}

/// Типизированное предупреждение санации — текст рендерит UI через
/// `getLocalText` (§285: сервис строк не показывает).
enum ImportRuleWarningKind {
  /// `outbound` (или preset-override) ссылался на несуществующий канал —
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
/// [channelTags] — теги ВСЕХ каналов получателя (включая выключенные: ссылку
/// на выключенный канал лечит существующая механика варнингов §274/§277).
/// [dnsServerTags] — union storage-refs ∪ template (источник дропдауна §117).
/// Имя и `num` здесь НЕ трогаются — это забота [insertImportedRule] (им нужен
/// список правил в момент вставки, включая ранее вставленные из этого файла).
SanitizedImportRule sanitizeImportedRule(
  dynamic rawEntry, {
  required Set<String> channelTags,
  required Set<String> dnsServerTags,
  required WizardTemplate template,
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

  // preset: без пресета в шаблоне получателя правило нечем разворачивать —
  // отвергаем с внятной причиной вместо broken-card.
  SelectableRule? preset;
  if (parsed.kind == CustomRuleKind.preset) {
    for (final sr in template.selectableRules) {
      if (sr.presetId == parsed.presetId) {
        preset = sr;
        break;
      }
    }
    if (preset == null) {
      return SanitizedImportRule(
        displayLabel: label.isNotEmpty ? label : parsed.presetId,
        rejectReason: ImportRuleRejectReason.unknownPreset,
      );
    }
  }

  final warnings = <ImportRuleWarning>[];
  var rule = parsed;
  var forceDisable = false;

  // ── outbound: тег канала получателя, спец-теги или пусто («как в шаблоне»).
  final validOutbounds = <String>{
    '',
    kOutboundReject,
    kBlockOutboundTag,
    kDirectOutboundTag,
    ...channelTags,
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
  // («tap ☁ to download, then enable», предикат `_copyPreset`).
  final needsSrs = rule is CustomRuleSrs ||
      (rule is CustomRulePreset &&
          preset != null &&
          remoteRuleSetsOfPreset(preset, rule).isNotEmpty);
  if (needsSrs || forceDisable) {
    rule = rule.withEnabled(false);
  }

  final display = rule.kind == CustomRuleKind.preset
      ? (preset!.label.isNotEmpty ? preset.label : preset.presetId)
      : rule.name;
  return SanitizedImportRule(
    rule: rule,
    displayLabel: display,
    warnings: warnings,
    needsSrsDownload: needsSrs,
  );
}

/// Вставка санированного правила в список (мутирует [target]): дедуп имени,
/// назначение `num` (§370), append. Сортировку по оси и персист делает
/// вызывающий — один раз на весь импорт.
///
/// - preset → `num` из шаблона получателя (как `_copyPreset`);
/// - остальные → [nextUserRuleNum] — каждое следующее правило видит уже
///   вставленные предыдущие, поэтому мульти-импорт нумеруется последовательно.
CustomRule insertImportedRule(
  List<CustomRule> target,
  CustomRule rule, {
  required WizardTemplate template,
}) {
  var next = rule;

  if (next.kind == CustomRuleKind.preset) {
    int? templateNum;
    for (final sr in template.selectableRules) {
      if (sr.presetId == next.presetId) {
        templateNum = sr.num;
        break;
      }
    }
    next.orderNum = templateNum ?? nextUserRuleNum(target);
    // Имя preset-правила не трогаем: display-слой §279 даёт live-label
    // шаблона получателя + порядковый суффикс копии.
  } else {
    next.orderNum = nextUserRuleNum(target);
    final existing = visibleRuleNames(target, template);
    if (existing.contains(next.name)) {
      var i = 2;
      while (existing.contains('${next.name} ($i)')) {
        i++;
      }
      next = next.withName('${next.name} ($i)');
    }
  }

  target.add(next);
  return next;
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
