# 064 — Custom rule editor: View tab preview независим от Switch (enabled)

**Статус:** done (v1.7.4, v14101, commit `d820387`)
**Связано:** §030 custom routing rules, §053 custom_rule_edit refactor, §062 unified custom_rules order

## TL;DR

При открытии **disabled** custom-правила в editor'е → tab **View** показывал
пустой preview `{rule_set: [], rules: []}`. Юзер открыл editor именно
для inspect'а формы — фильтрация по `enabled` тут лишняя, путает.

Фикс: добавлен опциональный parameter `skipDisabled = true` на
`applyCustomRules`. `ViewTab` зовёт с `skipDisabled: false` — preview
показывает «что родит при включении». Production pipeline
(`applyAllCustomRules`, §062) поведение не меняет — там фильтрация
по `enabled` обязательна.

## Repro (до фикса)

1. Открыть custom-правило с `enabled: false` (Switch OFF в Params tab)
2. Перейти на tab **View**
3. **storage shape** правильно показывает full JSON правила
4. **sing-box config preview** — пустой `{"rule_set": [], "rules": []}`
5. Включить Switch в Params tab → вернуться на View → preview наполняется

## Why это was bug

`applyCustomRules` в [post_steps.dart:617](../../../app/lib/services/builder/post_steps.dart#L617)
имел безусловный skip:

```dart
for (final cr in rules) {
  if (!cr.enabled) continue;  // <-- skip даже в editor preview
  ...
}
```

Это правильно для **production pipeline** (`applyAllCustomRules`) —
disabled-правила не должны попадать в финальный config. Но `ViewTab`
переиспользовал тот же `applyCustomRules` для preview — получал
side-effect фильтрации:

- ✗ Юзер видит пустой preview disabled-правила, думает что правило
  broken / не configured корректно
- ✗ Нет способа в UI понять «что родит правило при включении» без
  фактического переключения Switch (что портит dirty-state)
- ✗ Storage shape (raw JSON) и sing-box preview расходятся семантически
  — storage shape независим от enabled, preview зависит

`expandPreset` для preset-ветки уже не фильтрует на top-level (только
per-rule_set `enabled_default` для §045 bool-var convention — это
другая фильтрация, не на rule-level). Preset preview работал корректно
уже до фикса.

## Фикс — A (chosen)

Параметр `skipDisabled` на `applyCustomRules`:

```dart
List<String> applyCustomRules(
  RuleSetRegistry registry,
  List<CustomRule> rules, {
  Map<String, String> srsPaths = const {},
  bool skipDisabled = true,  // NEW — default keeps backward-compat
}) {
  for (final cr in rules) {
    if (skipDisabled && !cr.enabled) continue;
    ...
  }
}
```

В `view_tab.dart` (inline/srs branch):

```dart
warnings = applyCustomRules(reg, [c.snapshot()],
    srsPaths: srsPaths, skipDisabled: false);
```

### Почему НЕ B (клонировать snapshot с `withEnabled(true)`)

Альтернативой было локально в `ViewTab` сделать
`c.snapshot().withEnabled(true)` и передать builder'у. Отказались:

- **Honest data flow** — B кормит builder'у фейковый snapshot.
  Если завтра в builder появится логика «for disabled rules with
  cached SRS — emit warning» или «log disabled rules count» — B
  молча сломает её в preview.
- **Discoverability** — `withEnabled(true)` в ViewTab выглядит как
  hack, требует комментария «зачем мы тут переписываем enabled».
  Параметр `skipDisabled` с docstring'ом — самодокументируется.
- **Симметрия** — если кто-то завтра захочет preview всех правил
  (Debug API endpoint типа `/config/preview-all`), переиспользует тот
  же flag. С B каждый caller сам клонировал бы snapshot — копипаста.
- **Не lies to the builder** ≠ «extra param boilerplate». Дефолтное
  `skipDisabled = true` сохраняет старый API 1:1 для всех существующих
  callers + тестов (builder/ 80 pass без правок).

## Acceptance

- [x] `applyCustomRules` принимает `skipDisabled` (default `true`)
- [x] `ViewTab` передаёт `skipDisabled: false` для inline/srs ветки
- [x] Existing tests pass без правок (`flutter test test/builder/` 80 pass)
- [x] Smoke на устройстве: открыть disabled-правило с wifi conditions
  → View tab показывает корректный `rule_set` + `rules`, не пустой
- [x] Storage shape (raw `initial.toJson`) поведение **не меняется** —
  показывает что есть в `lxbox_settings.json` (`enabled: false`); preview
  показывает что родит при включении. Не путаются.

## Не входит

- `applyAllCustomRules` (production pipeline, §062) — поведение не
  меняется. Если когда-нибудь потребуется dry-run / preview-all API,
  можно будет добавить тот же flag симметрично.
- `expandPreset` — не трогаем, top-level фильтрации по `enabled`
  там нет, preset preview уже корректен.
- UI hint в editor'е «preview не отражает реальный config из-за
  disabled-state» — не нужен; storage shape выше показывает `enabled`
  явно, а юзер понимает что View — это форма-preview.
