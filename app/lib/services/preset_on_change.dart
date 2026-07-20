import '../models/custom_rule.dart';
import '../models/parser_config.dart';
import 'builder/if_engine.dart';
import 'builder/post_steps.dart' show presetDnsEnableVar;
import 'settings_storage.dart';

/// §232+§266 — декларативный side-effect `on_change` для ПРЕСЕТОВ.
///
/// Магическая var пресета несёт `on_change: {"set": {"@target": <#if-node>}}`.
/// Когда меняется её значение (пресет вкл/выкл, dns_enable-тумблер), каждый
/// `@target` пере-вычисляется через `#if`-движок и пишется в ГЛОБАЛЬНЫЙ
/// userVars (`SettingsStorage.setVar`). Пример: FakeIP-пресет глушит
/// `resolve_enabled` пока он активен (`@rule_enable` И `@dns_enable`).
///
/// Псевдо-vars (не хранятся, вычисляются из состояния пресета):
/// - `@rule_enable` = `cr.enabled` (пресет включён свичем).
/// - `@dns_enable` = §257 `presetDnsEnableVar` (DNS-аспект пресета).
///
/// Отличие от section-var on_change (`settings_screen._applyOnChange`): там
/// цель и источник в одной модели (VarValuesModel); здесь источник — состояние
/// пресета (custom_rules), цель — глобальная var (userVars). Пишем сразу в
/// userVars (её родной storage), НЕ в varsValues пресета.
///
/// Зовётся из ВСЕХ точек смены rule_enable/dns_enable: создание пресета
/// (routing `_copyPreset`), toggle свича (routing/редактор), dns_enable-тумблер
/// (редактор `onBoolVarToggle`, DNS Settings `_togglePresetDnsEnable`).
///
/// Идемпотентна: `setVar` перезаписывает; повторный вызов с тем же состоянием
/// даёт то же значение цели.
Future<void> applyPresetOnChange(
  SelectableRule preset,
  CustomRulePreset cr,
) async {
  // Собираем on_change-декларации со ВСЕХ vars пресета (rule_enable и
  // dns_enable несут идентичную формулу — любая из них триггерит пересчёт).
  final targets = <String, Map<String, dynamic>>{};
  for (final v in preset.vars) {
    final oc = v.onChange?['set'];
    if (oc is! Map<String, dynamic>) continue;
    oc.forEach((target, ifNode) {
      if (ifNode is Map<String, dynamic>) {
        final tName = target.startsWith('@') ? target.substring(1) : target;
        targets[tName] = ifNode; // последняя декларация wins (они идентичны)
      }
    });
  }
  if (targets.isEmpty) return;

  // Namespace для резолва: псевдо-vars пресета + текущие глобальные userVars.
  // Псевдо перекрывают userVars (их значение — «живое» состояние пресета).
  final userVars = await SettingsStorage.getAllVars();
  final ns = <String, String>{
    ...userVars,
    'rule_enable': cr.enabled ? 'true' : 'false',
    // §297 — единый предикат с билдером (был дубль `_dnsEnableValue`).
    'dns_enable': presetDnsEnableVar(cr, preset) ? 'true' : 'false',
  };

  // WizardVar-ноды для коэрсинга типов резолвером (bool). Собираем из
  // preset.vars + пустышки для псевдо/userVars (тип bool для *_enable).
  final byName = <String, WizardVar>{
    for (final v in preset.vars) v.name: v,
  };
  final resolve = makeResolver(ns, byName);

  for (final entry in targets.entries) {
    final resolved = evalIfScalar(entry.value, resolve);
    if (resolved == null) continue;
    await SettingsStorage.setVar(entry.key, resolved);
  }
}

