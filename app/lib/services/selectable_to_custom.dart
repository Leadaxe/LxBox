import '../models/custom_rule.dart';
import '../models/parser_config.dart';

/// Конвертер `SelectableRule` (из wizard_template.json) → `CustomRule`.
/// Используется когда юзер нажимает "Copy to Rules" в Presets, а также в
/// one-shot миграции legacy `enabled_rules` при первом запуске после
/// перехода на единую модель.
///
/// Обрабатываем три формы пресетов:
///  1. `rule_set: [remote SRS]` → `CustomRule(kind: srs, srsUrl: …)`
///  2. `rule.rule_set: "<tag>"` ссылка на inline rule_set внутри template
///     `route.rule_set` → разворачиваем match-поля в `CustomRule` (inline)
///  3. Поля match прямо в `rule` (domain/protocol/…) → `CustomRule` (inline)
///
/// Возвращает `null` если пресет невозможно представить (нет target'а или
/// пустой rule).
CustomRule? selectableRuleToCustom(
  SelectableRule sr,
  WizardTemplate template, {
  String? overrideOutbound,
}) {
  final rule = sr.rule;
  if (rule.isEmpty) return null;

  final target = _target(rule, overrideOutbound);
  if (target.isEmpty) return null;

  // Case 1: preset's own remote rule_set
  if (sr.ruleSets.isNotEmpty) {
    final first = sr.ruleSets.first;
    final url = (first['url'] as String?)?.trim() ?? '';
    if (url.isNotEmpty) {
      return CustomRule(
        name: sr.label,
        kind: CustomRuleKind.srs,
        srsUrl: url,
        target: target,
      );
    }
  }

  // Case 2: reference to inline rule_set defined in template.route.rule_set
  final ruleSetRef = rule['rule_set'];
  if (ruleSetRef is String) {
    final expanded = _expandInlineRef(ruleSetRef, template);
    if (expanded != null) {
      return CustomRule(
        name: sr.label,
        domains: _stringList(expanded['domain']),
        domainSuffixes: _stringList(expanded['domain_suffix']),
        domainKeywords: _stringList(expanded['domain_keyword']),
        ipCidrs: _stringList(expanded['ip_cidr']),
        ports: _intList(expanded['port']).map((p) => p.toString()).toList(),
        portRanges: _stringList(expanded['port_range']),
        packages: _stringList(expanded['package_name']),
        protocols: _stringList(rule['protocol']),
        ipIsPrivate: (expanded['ip_is_private'] as bool?) ?? false,
        target: target,
      );
    }
    return null;
  }

  // Case 3: inline rule с match-полями прямо в rule
  return CustomRule(
    name: sr.label,
    domains: _stringList(rule['domain']),
    domainSuffixes: _stringList(rule['domain_suffix']),
    domainKeywords: _stringList(rule['domain_keyword']),
    ipCidrs: _stringList(rule['ip_cidr']),
    ports: _intList(rule['port']).map((p) => p.toString()).toList(),
    portRanges: _stringList(rule['port_range']),
    packages: _stringList(rule['package_name']),
    protocols: _stringList(rule['protocol']),
    ipIsPrivate: (rule['ip_is_private'] as bool?) ?? false,
    target: target,
  );
}

String _target(Map<String, dynamic> rule, String? override) {
  if (override != null && override.isNotEmpty) return override;
  if (rule['action'] == 'reject') return kRejectTarget;
  final out = rule['outbound'];
  return out is String ? out : '';
}

/// Найти inline rule_set по tag в template.config.route.rule_set и вернуть
/// первую headless-rule entry. Null если не нашли или rule_set не inline.
Map<String, dynamic>? _expandInlineRef(String tag, WizardTemplate template) {
  final route = template.config['route'];
  if (route is! Map) return null;
  final sets = route['rule_set'];
  if (sets is! List) return null;
  for (final s in sets) {
    if (s is! Map) continue;
    if (s['tag'] != tag) continue;
    if (s['type'] != 'inline') return null;
    final rules = s['rules'];
    if (rules is! List || rules.isEmpty) return null;
    final first = rules.first;
    if (first is Map<String, dynamic>) return first;
    if (first is Map) return Map<String, dynamic>.from(first);
  }
  return null;
}

List<String> _stringList(dynamic v) {
  if (v is! List) return const [];
  return v.map((e) => e.toString()).toList();
}

List<int> _intList(dynamic v) {
  if (v is! List) return const [];
  return v
      .map((e) => e is int ? e : int.tryParse(e.toString()))
      .whereType<int>()
      .toList();
}
