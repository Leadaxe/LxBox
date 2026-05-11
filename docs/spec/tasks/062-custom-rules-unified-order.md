# 062 — custom_rules: единый order между preset/inline/srs

**Статус:** active (v1.7.4)
**Связано:** §030 custom routing rules, §033 preset bundles, §051 wifi conditions

## TL;DR

`SettingsStorage.custom_rules` это **один список** с mixed `kind`
(`preset` | `inline` | `srs`). UI и Debug API (`POST /rules/reorder`) предполагают
что order этого списка = order matching в sing-box `route.rules[]`.

Builder (`build_config.dart:242-255`) **ломает** это предположение: вызывает
`applyPresetBundles` (только preset rules) и `applyCustomRules` (только
inline/srs) последовательно, поэтому в финальном sing-box config все preset
правила оказываются ПЕРЕД всеми inline/srs независимо от storage order.

Чинится: один проход по `customRules` с dispatch по kind, registry уже
дедуплицирует rule_sets через `tryRegisterRuleSet`.

## Repro

```bash
# storage order: [preset, preset, inline, preset, ...]
TOKEN=...
curl -s -H "Authorization: Bearer $TOKEN" "$BASE/rules" \
  | jq '.[].name + " (" + .[].kind + ")"'

# Поднимаем inline на позицию 1 (между preset'ами):
curl -X POST -H "Authorization: Bearer $TOKEN" -H "Content-Type: application/json" \
  -d '{"order":[<preset>,<inline>,<preset>,<preset>,...]}' \
  "$BASE/rules/reorder"
curl -X POST -H "Authorization: Bearer $TOKEN" "$BASE/action/rebuild-config"

# Проверяем порядок в sing-box config:
curl -s -H "Authorization: Bearer $TOKEN" "$BASE/config" \
  | jq '.route.rules | to_entries | .[] | "\(.key): \(.value)"'

# Bug: inline rule всё равно идёт ПОСЛЕ всех preset, не на позиции 1.
```

## Expected

`route.rules[]` order **строго** соответствует `customRules` storage order
(минус system rules в head: resolve / sniff / dns hijack).

## Cause

```dart
// build_config.dart:242-255
applyPresetBundles(ruleSets, settings.customRules, ...);  // только preset, в storage order
applyCustomRules(ruleSets, settings.customRules, ...);    // только inline/srs (preset → continue)
```

Inside [`applyPresetBundles`](app/lib/services/builder/post_steps.dart:432) — фильтр `if (cr is! CustomRulePreset) continue`.
Inside [`applyCustomRules`](app/lib/services/builder/post_steps.dart:562) — `case CustomRulePreset(): continue`.
Каждый вызов добавляет правила в registry в порядке своей подгруппы → итоговый
config: [все preset] + [все inline/srs].

## Fix

Добавить `applyAllCustomRules(registry, rules, presets, ...)` — единый entry
point, выносит per-rule logic в private functions:

```dart
UnifiedApplyResult applyAllCustomRules(
  RuleSetRegistry registry,
  List<CustomRule> rules,
  List<SelectableRule> presets, {
  Map<String, String> srsPaths = const {},
  Map<String, String> presetSrsPaths = const {},
  Map<String, bool> isPresetDnsEnabled = const {},
}) {
  final dnsRulesByPresetId = <String, Map<String, dynamic>>{};
  final labelByPresetId = <String, String>{};
  final extraDnsServers = <Map<String, dynamic>>[];
  final dnsServerByTag = <String, Map<String, dynamic>>{};
  final warnings = <String>[];
  for (final cr in rules) {
    switch (cr) {
      case CustomRulePreset():
        warnings.addAll(_applyPresetSingle(cr, registry, presets,
            presetSrsPaths: presetSrsPaths,
            isPresetDnsEnabled: isPresetDnsEnabled,
            dnsRulesByPresetId: dnsRulesByPresetId,
            labelByPresetId: labelByPresetId,
            extraDnsServers: extraDnsServers,
            dnsServerByTag: dnsServerByTag));
      case CustomRuleInline():
        warnings.addAll(_applyInlineSingle(cr, registry));
      case CustomRuleSrs():
        warnings.addAll(_applySrsSingle(cr, registry, srsPaths));
    }
  }
  return UnifiedApplyResult(
    extraDnsServers: extraDnsServers,
    dnsRulesByPresetId: dnsRulesByPresetId,
    labelByPresetId: labelByPresetId,
    warnings: warnings,
  );
}
```

В `build_config.dart` заменить два вызова на один:

```dart
final unified = applyAllCustomRules(
  ruleSets,
  settings.customRules,
  template.selectableRules,
  srsPaths: srsPaths,
  presetSrsPaths: presetSrsPaths,
  isPresetDnsEnabled: isPresetDnsEnabled,
);
emitWarnings.addAll(unified.warnings);
// далее использовать unified.dnsRulesByPresetId / labelByPresetId / extraDnsServers
```

## Backward compat

Старые `applyPresetBundles` / `applyCustomRules` остаются как **public shim**
(под hood обходят rules в group fashion). Их юзают тесты в
`test/builder/custom_rules_test.dart`. Build pipeline на них больше не
полагается.

## RuleSet dedup

`mergeFragments` ранее дедуплицировал rule_sets между preset'ами. Теперь это
делает `RuleSetRegistry.tryRegisterRuleSet` (identical-skip / first-wins
warning) — всё уже встроено, цикл просто зовёт его per-rule.

DNS-аспекты (`dnsServer` tag-dedup) переезжают в `_applyPresetSingle` через
shared `dnsServerByTag` map (передаём аргументом из unified scope).

## Тесты

1. **Существующие** `test/builder/custom_rules_test.dart` — должны пройти
   без изменений (shim сохраняет API).
2. **Новый** `test/builder/unified_order_test.dart`:
   - storage = `[preset_A, inline_X, preset_B]` → config order = same
   - storage = `[inline_Y, preset_C]` → inline_Y first
   - mixed kinds + dedup: два preset'а с одинаковым rule_set → first-wins (как раньше)
3. `pipeline_e2e_test.dart` — должен пройти без изменений (e2e зависит от
   storage order, который для текущих fixture'ов уже соответствует).

## Verification on device

```bash
# 1. storage: [preset, preset, inline, preset, ...]
# 2. rebuild
# 3. config.route.rules[] order совпадает с storage order
#    (за вычетом resolve/sniff/dns hijack в head)
```

## Out of scope

- UI Drag-and-drop reorder поверх mixed kinds — уже работает в Routing→Rules
  через `ReorderableListView`, фикс просто чинит трансляцию storage→config.
- Изменение storage shape — не требуется.
