# §225 — Raw-JSON тип кастомного правила маршрутизации (GitHub #17)

**Тип:** feature-изменение фичи [030 custom routing rules](../features/030%20custom%20routing%20rules/spec.md)
**Статус:** ✅ Реализовано (unit-тесты зелёные, analyze чист; device-verify pending)
**Приоритет:** Medium (power-user; закрывает #17 одним механизмом)
**Связано:** §030 (custom rules), §033 (preset), #17 (FR: полный набор route actions),
косвенно #18 (Fake-IP через `hijack-dns`)

## Мотивация (issue #17)

Юзер просит вынести в UI полный набор sing-box route-actions: `route`,
`route-options` (override addr/port, TLS fragment), `sniff`, `resolve`,
`hijack-dns`. Разбор показал:

- `route` (в outbound) и `reject` — **уже** есть (OutboundPicker «Action»).
- `resolve` / `sniff` / `hijack-dns` — **уже работают** как глобальные правила
  базового конфига (`wizard_template.json`), просто не как per-rule UI.
- Остальное (`route-options`, per-rule sniff/resolve tuning) — глубоко
  power-user, не оправдывает матрицу переключателей в мобильном UI.

Вместо десятка новых форм-полей вводим **третий тип правила — `json`**: юзер
пишет сырой JSON-объект правила (или массив), билдер кладёт его в `route.rules`
как есть. Один механизм закрывает ЛЮБОЙ будущий action без изменения модели.

## UX

Секция **Source** в редакторе правила становится тремя вариантами:

```
( ) Inline   ( ) SRS   ( ) JSON
```

(лейблы: `Inline` / `Remote (.srs)` / `Raw JSON`.)

При выборе **JSON**:
- Прячем match/port/protocol/wifi/inbound/dns-секции и OutboundPicker «Action»
  (действие — часть самого JSON).
- Показываем один многострочный `TextField` (monospace) для тела правила +
  подсказку с примером и inline-валидацией (parse-ошибка → красный helper,
  Save заблокирован).
- Пример-плейсхолдер:
  ```json
  { "protocol": "dns", "action": "hijack-dns" }
  ```

## Модель

Новый подкласс `CustomRuleJson extends CustomRule` в
[custom_rule.dart](../../app/lib/models/custom_rule.dart):

- Поля: `id`, `name`, `enabled`, `json` (String — сырой текст, хранится как
  ввёл юзер, не переформатируем).
- `kind => CustomRuleKind.json` (добавить в enum: `{ inline, srs, preset, json }`).
- `toJson`/`fromJson` — сохраняем `json`-строку в `lxbox_settings.json`
  (backward-compat: старые записи без `json` не существуют — тип новый).
- `outbound` getter → пустая строка (действие внутри тела; не участвует в
  OutboundPicker). `summary` → первые ~40 симв. одной строки JSON или «Raw JSON».
- Convenience-getters базового класса (domains/ports/…) для `json` → пустые
  (как сейчас для srs/preset — switch `_ => const []`).

## Билдер

В `applyAllCustomRules` ([custom_rules.dart:448](../../app/lib/services/builder/post_steps/custom_rules.dart))
добавить ветку `case CustomRuleJson():`:

1. `if (!cr.enabled) continue;`
2. Распарсить `cr.json` (`jsonDecode`).
3. Форма:
   - **Объект** (`Map`) → `registry.addRule(map)` (один rule).
   - **Массив** (`List`) объектов → `addRule` для каждого (по порядку).
   - Иначе (скаляр / битый JSON / не-Map-элементы) → **skip + warning**
     `Raw-JSON rule "<name>" skipped: <причина>` (как SRS-skip). НЕ роняем
     сборку — правило деградирует, остальной конфиг цел.
4. Порядок сохраняется (позиция в общем цикле = приоритет матчинга).

**Ключевая защита — уже существует:** `validateConfig`
([validator.dart:34](../../app/lib/services/builder/validator.dart)) уже ловит
`rules[].outbound` на dangling-tag (fatal `DanglingOutboundRef`). Значит
raw-JSON правило с битым `outbound` будет поймано ДО старта ядра тем же путём,
что и обычные правила — отдельной валидации не требуется. (Опечатка в имени
поля action-типа sing-box сама по себе не dangling-ref; на такое рассчитываем
на грамотность power-user'а — как и на прямое редактирование JSON конфига.)

## View-таб

`ViewTab` для `json`-правила показывает распарсенный/pretty-printed JSON (или
raw-текст + warning если не парсится). Preview-эмит: тот же путь, что билдер.

## Файлы

| Файл | Изменение |
|---|---|
| `models/custom_rule.dart` | enum + класс `CustomRuleJson` + getters |
| `services/builder/post_steps/custom_rules.dart` | ветка `CustomRuleJson` в `applyAllCustomRules` |
| `screens/custom_rule_edit/edit_controller.dart` | `_kind==json` state, snapshot(), json-controller |
| `screens/custom_rule_edit/tabs/params_tab.dart` | 3-я radio-опция + JSON-секция, скрытие остального |
| `screens/custom_rule_edit/sections/json_section.dart` | новый — TextField + inline-валидация |
| `screens/custom_rule_edit/tabs/view_tab.dart` | ветка json |
| `docs/spec/features/030 .../spec.md` | обновить enum до `{inline, srs, preset, json}` |

## Границы (что НЕ делаем)

- Не добавляем per-action UI-формы (`sniff`/`resolve`/`hijack-dns` тумблеры) —
  всё через JSON. `hijack-dns` per-rule как first-class тумблер — потенциально
  в связке с Fake-IP (#18), отдельная задача.
- Не валидируем семантику action-полей sing-box (только JSON-синтаксис +
  существующий dangling-outbound-чек). Raw = ответственность power-user'а.

## Верификация

- Unit: `applyAllCustomRules` с `CustomRuleJson` (объект / массив / битый JSON /
  не-Map → warning). Round-trip `toJson`/`fromJson`.
- Device: создать JSON-правило `{ "protocol":"dns","action":"hijack-dns" }`,
  включить, стартовать туннель → конфиг валиден, ядро поднялось.
