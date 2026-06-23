# §162 — `block_unknown` дефолт `reject` уезжал как `outbound:"reject"` → fatal

**Статус:** Done
**Дата:** 2026-06-23
**Связано:** §033 (selectable presets / expansion), §124 (block_unknown / per-app), §141 (fatal-валидация блокирует save)

## Симптом

У юзеров (≥2 жалобы) после включения пресета **«Unknown traffic»** (`block_unknown`) — fatal на старте:

```
Config invalid: Rule "rules[7]" references missing outbound "reject".
```

Воспроизводилось НЕ у всех включивших пресет — только у тех, кто **не открывал
OutboundPicker** (оставил дефолт).

## Корень

`reject` в sing-box — это `action`, а **не** outbound-tag. Правило
`{outbound: "reject"}` валидатор реджектит как dangling-ref
(`DanglingOutboundRef`, [validator.dart:36](../../../app/lib/services/builder/validator.dart)) → fatal → ядро не стартует.

Пресет `block_unknown` ([wizard_template.json](../../../app/assets/wizard_template.json)) —
единственный shipped-пресет с формой:

```json
"vars": [{ "name": "outbound", "type": "outbound", "default_value": "reject" }],
"rule": { "rule_set": ["unknown-apps"], "outbound": "@outbound" }
```

Нормализация `reject → action` в [preset_expand.dart](../../../app/lib/services/builder/preset_expand.dart)
сидела **внутри** override-ветки `if (override != null && override.isNotEmpty)`,
где `override = rule.varsValues['outbound']`. То есть конвертация срабатывала
только когда юзер ЯВНО выбрал `reject` в пикере (тогда ключ `outbound` есть в
`varsValues`).

Но `reject` приходит и **template-дефолтом**: при включённом-но-нетронутом
пресете `varsValues` пустой, `@outbound` подставляется в `"reject"` на этапе
substitution (раньше override-проверки), а сама override-ветка пропускается
(`override == null`). Литерал `outbound: "reject"` уезжал в `route.rules`.

| Откуда `reject` | в `varsValues`? | конвертация reject→action | результат |
|---|---|---|---|
| Явный выбор в пикере | да | ✅ (override-ветка) | OK |
| Дефолт шаблона (`default_value`) | нет | ❌ (ветка пропущена) | **fatal** |

## Фикс

Безусловный backstop в `expandPreset` — нормализует **финальный** результат
независимо от того, override это или дефолт:

```dart
if (result['outbound'] == 'reject') {
  result.remove('outbound');
  result['action'] = 'reject';
}
```

Это инвариант **билдера** (контракт sing-box `reject == action`), а не забота
автора шаблона — поэтому фикс в коде, а не `#if`-условие в `wizard_template.json`.
Backstop самолечит и любой будущий пресет с формой `outbound:"@outbound"` +
reject-дефолт.

## Переживает ли обновление (юзеры с разных версий)

Да, автоматически, без отдельного migration:

- `CustomRulePreset` персистит только `{presetId, varsValues}`
  ([custom_rule.dart:562,619](../../../app/lib/models/custom_rule.dart)) — само
  развёрнутое правило `{outbound:"reject"}` нигде не сохраняется, ребилдится из
  шаблона при каждой генерации. После фикса первый ребилд даёт `action:reject`.
- Битый `singbox_config.json` не мог осесть на диске: `FatalValidationException`
  бросается ДО возврата json ([subscription_controller.dart:725](../../../app/lib/controllers/subscription_controller.dart),
  §141) → все callsite делают skip-save. На диске у пострадавших — старый
  валидный конфиг или ничего.
- При установке фикс-версии: любой ребилд (запуск VPN / UI-действие) или плашка
  «rebuild config» (§076 dirty-check) → корректный `action:reject`.

## Тест

[preset_expand_test.dart](../../../app/test/services/builder/preset_expand_test.dart) —
кейс «§162 default_value=="reject" в @outbound (пикер не трогали)»: red без
backstop (`Actual: {rule_set, outbound:"reject"}`), green с ним
(`{rule_set, action:"reject"}`).
