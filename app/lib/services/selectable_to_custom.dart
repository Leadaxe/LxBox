import '../models/custom_rule.dart';
import '../models/parser_config.dart';
import 'record_vars.dart';

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
  if (overrideOutbound != null) {
    // §441 (Н3/Н4) — цель, равная умолчанию объявленной `outbound`, не
    // пишется: правило следует шаблону.
    RecordVarDecl? decl;
    for (final v in sr.vars) {
      if (v.name == kPresetOutboundVar && !v.isRef) {
        decl = RecordVarDecl(name: v.name, defaultValue: v.defaultValue);
        break;
      }
    }
    final stored = recordVarValueToStore(overrideOutbound, decl);
    if (stored != null) varsValues[kPresetOutboundVar] = stored;
  }

  return CustomRulePreset(
    name: sr.label.isEmpty ? sr.presetId : sr.label,
    presetId: sr.presetId,
    varsValues: varsValues,
  );
}
