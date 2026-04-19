import '../../models/validation.dart';

/// Валидация собранного конфига (§3.5 спеки 026). Функция, не класс.
///
/// Проверяет:
/// - `route.rules[].outbound` ссылается на существующий tag → иначе
///   `DanglingOutboundRef` (fatal).
/// - `outbounds[type=urltest]` не пуст → иначе `EmptyUrltestGroup` (fatal).
/// - `outbounds[type=selector].default` в options → иначе `InvalidDefault`
///   (fatal).
ValidationResult validateConfig(Map<String, dynamic> config) {
  final issues = <ValidationIssue>[];

  final outbounds = (config['outbounds'] as List<dynamic>? ?? const [])
      .whereType<Map<String, dynamic>>()
      .toList();
  final endpoints = (config['endpoints'] as List<dynamic>? ?? const [])
      .whereType<Map<String, dynamic>>()
      .toList();

  final allTags = <String>{
    for (final o in outbounds) o['tag'] as String? ?? '',
    for (final e in endpoints) e['tag'] as String? ?? '',
  }..remove('');

  // Rule → outbound references.
  final rules = (config['route']?['rules'] as List<dynamic>? ?? const [])
      .whereType<Map<String, dynamic>>();
  var ruleIdx = 0;
  for (final r in rules) {
    final outRef = r['outbound'];
    if (outRef is String && outRef.isNotEmpty && !allTags.contains(outRef)) {
      issues.add(DanglingOutboundRef('rules[$ruleIdx]', outRef));
    }
    ruleIdx++;
  }

  // Empty urltest + invalid selector default.
  for (final o in outbounds) {
    final type = o['type'] as String? ?? '';
    final tag = o['tag'] as String? ?? '';
    final opts = (o['outbounds'] as List<dynamic>? ?? const [])
        .whereType<String>()
        .toList();
    if (type == 'urltest' && opts.isEmpty) {
      issues.add(EmptyUrltestGroup(tag));
    }
    if (type == 'selector') {
      final def = o['default'];
      if (def is String && !opts.contains(def)) {
        issues.add(InvalidDefault(tag, def));
      }
    }
  }

  return ValidationResult(issues);
}
