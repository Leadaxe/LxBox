import '../models/custom_rule.dart';
import '../models/parser_config.dart';

// §279 Phase 2 (spec §3.5.1) — live display-имена custom-правил.
//
// У preset-правил `name` — снапшот label'а активной локали в момент создания
// (fallback). Display-сайты резолвят label ВЖИВУЮ из локализованного шаблона,
// иначе смена языка оставила бы имена пресетов на языке создания навсегда.
//
// Дизамбигуация копий: live-резолюция схлопывала бы " (2)"-суффиксы — все
// копии одного пресета выглядели бы идентично. Правило: N-я копия одного
// presetId в порядке списка получает суффикс " (N)", первая — без суффикса.

/// Live display-имя правила [rule] в контексте списка [allRules].
///
/// - не-preset → сохранённое `name` как есть;
/// - preset → label из [template] (+ порядковый суффикс для копий);
/// - шаблон недоступен (холодный кэш) или пресет исчез → fallback на
///   сохранённое `name`.
String ruleDisplayName(
  CustomRule rule,
  List<CustomRule> allRules,
  WizardTemplate? template,
) {
  if (rule.kind != CustomRuleKind.preset) return rule.name;
  final live = _liveLabel(rule.presetId, template);
  if (live == null) return rule.name;
  // Порядковый номер копии этого presetId в порядке списка (1-based).
  var ordinal = 0;
  for (final r in allRules) {
    if (r.kind != CustomRuleKind.preset || r.presetId != rule.presetId) {
      continue;
    }
    ordinal++;
    if (r.id == rule.id) return ordinal <= 1 ? live : '$live ($ordinal)';
  }
  // Правила нет в списке (свежая копия до insert'а) — без суффикса.
  return live;
}

/// Display-имена всех правил списка (позиционно выровнены с [rules]).
List<String> ruleDisplayNames(
  List<CustomRule> rules,
  WizardTemplate? template,
) {
  final out = <String>[];
  final ordinalByPresetId = <String, int>{};
  for (final r in rules) {
    if (r.kind != CustomRuleKind.preset) {
      out.add(r.name);
      continue;
    }
    final n = (ordinalByPresetId[r.presetId] ?? 0) + 1;
    ordinalByPresetId[r.presetId] = n;
    final live = _liveLabel(r.presetId, template);
    if (live == null) {
      out.add(r.name);
    } else {
      out.add(n <= 1 ? live : '$live ($n)');
    }
  }
  return out;
}

/// Множество ВИДИМЫХ имён списка правил (display-резолвнутые + сохранённые
/// снапшоты preset-строк) без правила [excludeId]. Для дедупа новых/
/// переименованных имён: inline-правило не должно взять ни видимый live-label
/// пресета, ни его снапшот (коллизия всплыла бы при смене локали обратно).
Set<String> visibleRuleNames(
  List<CustomRule> rules,
  WizardTemplate? template, {
  String excludeId = '',
}) {
  final names = ruleDisplayNames(rules, template);
  final out = <String>{};
  for (var i = 0; i < rules.length; i++) {
    if (rules[i].id == excludeId) continue;
    out.add(names[i]);
    out.add(rules[i].name); // снапшот (для preset может отличаться от live)
  }
  return out;
}

String? _liveLabel(String presetId, WizardTemplate? template) {
  if (presetId.isEmpty || template == null) return null;
  for (final p in template.selectableRules) {
    if (p.presetId == presetId) return p.label.isEmpty ? null : p.label;
  }
  return null;
}
