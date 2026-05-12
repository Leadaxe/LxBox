import '../models/custom_rule.dart';
import '../models/parser_config.dart';

/// Конвертер `SelectableRule` (из `wizard_template.json`) → `CustomRulePreset`
/// (spec §033).
///
/// `SelectableRule.presetId` обязательный (§067), так что конвертер всегда
/// возвращает значение — null path удалён. Юзер, который хочет свои
/// match-поля, создаёт `CustomRuleInline` / `CustomRuleSrs` через
/// «+ Add rule» напрямую (минуя каталог Presets).
CustomRulePreset selectableRuleToCustom(
  SelectableRule sr,
  WizardTemplate template, {
  String? overrideOutbound,
}) {
  final varsValues = <String, String>{};
  if (overrideOutbound != null && overrideOutbound.isNotEmpty) {
    varsValues['outbound'] = overrideOutbound;
  }

  return CustomRulePreset(
    name: sr.label.isEmpty ? sr.presetId : sr.label,
    presetId: sr.presetId,
    varsValues: varsValues,
  );
}
