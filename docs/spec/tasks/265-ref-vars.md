# §265 — Ref-vars: переменная по ссылке в пресетах (`{"ref": "<global-var>"}`)

**Статус:** РЕАЛИЗОВАНО, DEVICE-VERIFIED (CPH2411, 09.07.2026) — ref-vars (`resolve_enabled`/
`resolve_strategy`) из internal-секции показываются и правятся В ПРЕСЕТЕ, значение в глобальном
userVars. Модель (`WizardVar.ref`/`isRef`, `WizardTemplate.globalVar`) + билдер (`globalVars`
в `expandPreset`) + UI (ref bool/enum контролы читают/пишут userVars).
**Тип:** generic-механизм движка vars (§120) — пресет ссылается на существующую глобальную
var вместо объявления собственной. Модель + UI-рендер + резолв. Ядро НЕ трогаем.
**Зависит от:** §120 (typed vars + `#if`-движок, section-vars, flat-namespace).
**Потребитель:** §264 (Traffic Processing preset — `resolve_strategy` через ref).

---

## 0. Проблема

Пресет (§033/§264) хочет показать в своём UI-редакторе переменную, которая по смыслу
**глобальная** — объявлена в секции настроек и читается вне пресета. Пример: `resolve_strategy`
объявлена в секции Network и читается в `config.dns.strategy` (через `@resolve_strategy`,
wizard_template ~L365) И в route-resolve правиле. Пресет Traffic Processing (§264) хочет дать
её ручку в своём редакторе, но:

- **Собственная** preset-var хранит значение в `rule.varsValues[name]` (per-preset storage,
  `preset_expand.dart:111`).
- **Глобальная** section-var хранит в `settings.userVars[name]` (глобальный storage,
  `build_config.dart:108`).

Два разных стораджа. Если пресет объявит собственную `resolve_strategy` — её значение
разъедется с глобальным `userVars['resolve_strategy']`, который читает `config.dns.strategy`.
Дубль-декларация (объявить в обоих местах одинаково) работает по flat-namespace, но дублирует
метаданные (title/tooltip/options) → рассинхрон при правке.

## 1. Решение — синтаксис `ref`

Запись в `vars[]` пресета с ключом `ref`:
```json
{"ref": "resolve_strategy"}
```
Это НЕ декларация новой var, а ССЫЛКА на существующую глобальную var по имени.

## 2. Семантика (generic — любой пресет ↔ любая глобальная var)

- **Метаданные не дублируются.** `type` / `options` / `title` / `tooltip` / `default_value`
  берутся из целевой глобальной var (найденной по `ref`-имени в `template.vars`). Ref-запись
  их не несёт — только `{"ref": "<name>"}`.
- **Storage — глобальный.** Ref-var читает/пишет `settings.userVars[<ref>]`, НЕ
  `rule.varsValues`. Единый источник значения: правка в UI пресета = правка глобали. И
  `config.dns.strategy`, и route-правило пресета видят одно значение.
- **UI.** В редакторе правила (`preset_params_tab.dart`) ref-var ПОКАЗЫВАЕТСЯ контролом целевой
  глобали (напр. enum-picker resolve_strategy). Контроллер резолвит определение глобали в
  `refVarDefs` (`_loadVpnMode` → `template.globalVar`); контрол берёт метаданные оттуда, значение
  читает из `globalVars[ref]`, пишет через `setGlobalVar` → `SettingsStorage.setVar` (глобальный
  userVars), НЕ в `varsValues`. Битая ссылка (нет глобали) → var пропускается.
- **Expansion.** `@<ref>` в route-правиле пресета резолвится из flat-`vars` штатно — значение
  уже в userVars → в flat-vars (`build_config.dart:108`). Ref-var в `preset_expand`
  varsValues-подстановке НЕ участвует (значения нет в varsValues).

## 3. Модель

`WizardVar` (`parser_config.dart:170`):
- новое поле `ref` (String, `''` = обычная var), геттер `isRef => ref.isNotEmpty`.
- `WizardVar.fromJson`: если `json['ref']` непустой → `name = ref`, `ref = ref`, остальные
  метаданные пустые (подтягиваются из глобали по `name` на этапе рендера/резолва). Обычная var
  (`ref` пустой) — без изменений.

`preset.vars` при обработке разделяются: собственные (varsValues-storage) vs ref
(userVars-storage) — по `isRef`.

## 4. Резолв целевой глобали

Ref-var несёт только имя. Метаданные для UI/коэрсинга берутся так: найти в `template.vars` var с
`name == ref` и `isRef == false` (первичная декларация в секции). Хелпер, напр.
`WizardTemplate.globalVar(String name)`.

## 5. Валидация

- `ref` на несуществующую глобальную var (нет в `template.vars`) → warning + скрыть контрол в
  UI, НЕ ронять конфиг (паттерн §033 «unresolved → drop silently»).
- Циклы невозможны (ref указывает на обычную var, не на другой ref — если target тоже ref,
  считать невалидным + warning).

## 6. Места правки (код)

| Файл | Что |
|---|---|
| `models/parser_config.dart:170-249` | `WizardVar`: поле `ref` + `isRef`; `fromJson` читает `ref` |
| `models/parser_config.dart` (`WizardTemplate`) | хелпер `globalVar(name)` — найти первичную декларацию |
| `services/builder/preset_expand.dart:102-118` | пропускать ref-vars в varsValues-цикле (их значение не в varsValues) |
| `services/builder/build_config.dart:107` | ref-var значение уже в userVars → в flat-vars; убедиться, что подхватывается |
| `screens/custom_rule_edit/tabs/preset_params_tab.dart:72,240` | рендер ref-var: метаданные из globalVar, значение из/в userVars (не varsValues) |
| `services/debug/serializers/rules.dart` | опц.: пометить ref-vars в сериализации пресета (симметрия) |

## 7. Места правки (документация)

- **docs/TEMPLATE.md** — раздел про vars/`selectable_rules`: описать синтаксис `{"ref": ...}`,
  семантику (глобальный storage, метаданные из целевой var), отличие от собственной preset-var.
- **docs/spec/features/120 template-engine-typed-vars-and-if/spec.md** — добавить раздел
  «Ref-vars» рядом с описанием типов var.

## 8. Тесты

- `WizardVar.fromJson`: `{"ref":"x"}` → `isRef==true`, `name=="x"`.
- Резолв метаданных: ref подтягивает `type`/`options` из глобали.
- Storage-разделение: правка ref-var пишет в userVars, не в varsValues (и наоборот для
  собственной).
- e2e: пресет с ref-var → `@ref` в правиле резолвится из глобального значения.
- Валидация: ref на несуществующую → warning, контрол скрыт, конфиг живёт.

## 9. Открытые вопросы

- Имя поля: `ref` (принято владельцем 08.07.2026).
- Generic или узкий (только resolve_strategy)? — **generic** (решено: стоит столько же,
  переиспользуемо).
