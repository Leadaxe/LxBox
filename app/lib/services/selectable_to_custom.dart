import '../models/custom_rule.dart';
import '../models/parser_config.dart';

/// Конвертер `SelectableRule` (из `wizard_template.json`) → `CustomRulePreset`
/// (spec §033, v1.4.1 task 011).
///
/// **Single path — всегда тонкая ссылка.** Legacy copy-by-value
/// (`kind: inline|srs` с дублированием полей) убран сознательно:
/// обновление шаблона должно автоматически менять поведение у всех юзеров,
/// без ручных миграций. Юзер, который хочет свои match-поля, создаёт
/// `CustomRuleInline` / `CustomRuleSrs` через «+ Add rule» напрямую
/// (минуя каталог Presets).
///
/// Пресет без `preset_id` в шаблоне → возвращает null (ошибка шаблона
/// ловится в ревью, не в рантайме). `overrideOutbound` →
/// `varsValues['outbound']`.
CustomRulePreset? selectableRuleToCustom(
  SelectableRule sr,
  WizardTemplate template, {
  String? overrideOutbound,
}) {
  if (sr.presetId.isEmpty) return null;

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
