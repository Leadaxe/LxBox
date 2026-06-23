# 161 — Auto Proxy не стартует: `tolerance` уходит строкой в uint16-поле ядра

| Поле | Значение |
|------|----------|
| Статус | **Done** — три части: (1) `urltest_tolerance` `type:text`→`int` + clamp uint16 (вошло в **v2.4.3**); (2) пустое required-поле → подстановка `default_value`: «UI сам чинит» при загрузке + backstop в build_config + блок persist пустого с errorText (**после v2.4.3, в develop**). `flutter analyze` чисто, 1246 тестов. |
| Дата | 2026-06-23 |
| Тип | task (data-fix `wizard_template.json` + UI/builder fallback пустых required-var) + тесты |
| Повод | Жалобы 4PDA: «последняя версия не взлетела, ни при обновлении поверх, ни при установке заново». Скриншоты: `Stopped: Failed to start service: decode config: outbounds[N].tolerance: json: cannot unmarshal string into Go struct field URLTestOutboundOptions.tolerance of type uint16`. |
| Связано | [[project_two_substitution_engines]] (§120 `if_engine.coerceVarValue`), §104 (ядро sing-box-lx 1.13.13-база), 39ca0bd (регрессия — литерал заменён на var) |

---

## TL;DR

Поле `URLTest.tolerance` в ядре sing-box (база 1.13.13) — строгий Go-тип
`uint16`. Нода `urltest_tolerance` в шаблоне была объявлена `type: text`, и
`coerceVarValue("30", "text")` оставлял значение **строкой**. В итоге в
`config.outbounds[].tolerance` уходило `"30"` (строка), и ядро падало на
decode ещё до старта туннеля.

Срабатывало у каждого, в чьём конфиге есть **Auto Proxy** (urltest-группа
`@auto_proxy_tag`) — то есть в дефолтном шаблоне у всех, кто его не отключил.

Фикс — одна строка данных: `type: text` → `type: int`. Тогда
`coerceVarValue("30", "int")` → `int.tryParse` → число `30`, и в конфиг
уходит `"tolerance": 30`. Ядро принимает.

## Корень

- [`wizard_template.json`](../../../app/assets/wizard_template.json) — нода
  `urltest_tolerance` (секция Auto Proxy) подставляется в
  `preset_groups[].options.tolerance` через `@urltest_tolerance`.
- [`if_engine.dart`](../../../app/lib/services/builder/if_engine.dart)
  `coerceVarValue(raw, type)`: коэрсит в число **только** при `type:int`/`bool`.
  Для `text`/`secret`/`enum`/… значение остаётся дословной строкой (это
  намеренный дизайн §120 — пароль `1234` не должен стать int). Поэтому
  `urltest_tolerance` как `text` давал строку.

### История регрессии

- До 39ca0bd: в шаблоне был **литерал** `"tolerance": 100` (число) → ядро
  парсило нормально.
- 39ca0bd («urltest_* as editable vars»): литерал заменён на
  `"tolerance": "@urltest_tolerance"` с нодой `type:text` → стало строкой.
  Баг латентный — проявляется только при активном Auto Proxy.

Версия ядра тут ни при чём: пин был `1.13.13`-базы всё время существования §104,
а в этой базе upstream sing-box уже типизировал `tolerance` как `uint16`.

## Фикс

```diff
   {
     "name": "urltest_tolerance",
-    "type": "text",
+    "type": "int",
     "default_value": "30",
     "options": ["10", "30", "50", "100", "200"],
     "wizard_ui": "edit",
     ...
   }
```

### Почему безопасно

- **UI не меняется.** В `template_var_list.dart` `int` попадает в `default:` →
  `_buildTextField` (combobox-edit с пресетами). Тот же рендер, что у `text`.
- **Storage не меняется.** Значение по-прежнему хранится строкой `"30"` в
  state; coerce происходит только на сборке конфига.
- **Builder.** `coerceVarValue("30","int")` → `30` (int). Мусорный ввод →
  `int.tryParse` вернёт строку (advisory; валидатор ловит отдельно).

### Защита от вне-диапазонных значений (clamp в uint16)

Ядро ждёт `uint16` (0..65535) для числовых полей (`port`, `tolerance`).
Ручной ввод/импорт мог дать `99999` или `-5` → ядро снова падает на decode.
Закрыто на двух слоях:

- **coerce-backstop** ([`if_engine.dart`](../../../app/lib/services/builder/if_engine.dart)):
  `coerceVarValue` для `type:int` делает `n.clamp(0, 65535)`. Ловит **любой**
  источник (ручной ввод, импорт бэкапа, legacy) — конфиг физически не может
  получить int вне uint16.
- **UI** ([`template_var_list.dart`](../../../app/lib/widgets/template_var_list.dart)):
  int-поле — `keyboardType: number` + `FilteringTextInputFormatter.digitsOnly`
  (буквы/минус не вводятся) + clamp в `onChanged` (значение > 65535
  поджимается на лету).

Все три текущие `int`-ноды укладываются: `tolerance`/`proxy_port` — ровно
uint16, `tun_mtu` (legal max ~9000) — внутри диапазона.

### Пустое required-поле → `default_value` (часть 2)

Связанная боль: пустое значение в **required**-поле так же ломает ядро, как
вне-диапазонное. Стёртый `tolerance` (в UI или в legacy-state) → `""` →
`coerceVarValue("","int")` = `int.tryParse("")` = null → возвращается `""` →
в конфиг `"tolerance": ""` → ядро падает. Наблюдалось на железе в этой сессии
(до `rebuild-config` конфиг нёс `tolerance: ''`).

Правило (предикат): `value.isEmpty && v.required && v.defaultValue.isNotEmpty
&& v.type != 'secret'` → подставить `v.defaultValue`. `required` (default
`true`) отсекает optional-vars §033, где пусто **легитимно** (поле выпадает
через `Dropped`); `secret` исключён, чтобы намеренно стёртый пароль не
«воскресал».

Реализовано на трёх точках:

1. **«UI сам чинит» — точка чтения** ([`template_var_list.dart`](../../../app/lib/widgets/template_var_list.dart)
   `initState`). При загрузке значений виджет применяет предикат: пустое
   required → `default`, и **персистит самочинение** через `onChanged` в
   `addPostFrameCallback`. Накопившиеся у юзеров битые значения исправляются
   при первом открытии экрана с этим полем. Единая точка для всех экранов
   (routing/settings/dns), использующих виджет.
2. **build_config backstop** ([`build_config.dart`](../../../app/lib/services/builder/build_config.dart)
   merge vars, стр. ~96). Тот же предикат при слиянии `userVars` + дефолтов —
   **ДО** `_substituteVars`, не трогает `#if`-логику. Ловит источники в обход
   UI-виджета: импорт бэкапа/пресета, legacy-state. Конфиг физически не
   получит пустое required-поле.
3. **Блок persist пустого + errorText** ([`template_var_list.dart`](../../../app/lib/widgets/template_var_list.dart)
   `_update`). Если юзер стирает required-поле в процессе правки — `onChanged`
   **не вызывается** (значение в storage не меняется), под полем — `errorText:
   "Required"`. Юзер видит, что поле обязательно, а не получает молча
   вернувшийся default. Ошибка снимается при вводе непустого значения.

> Почему НЕ внутри substitution / `#if`: подмена пустого на default там
> сломала бы условную логику (напр. `#if {@v: "#isEmpty"}` ожидает увидеть
> пустоту). Нормализация делается раньше — в плоской карте `vars` до walk'а.

### Будущая работа (не в scope)

Сейчас диапазон `[0,65535]` зашит как единый для всех `int`. Для `tun_mtu`
верхняя граница технически шире смысла (MTU ≤ ~9000). Точные min/max **per
node** — через новые поля шаблона (`"min"`/`"max"` в var-ноде), применяемые в
coerce и UI. Отдельной таской.

## Тесты

- `if_engine_test.dart` — регресс-тест «urltest_tolerance подставляется числом,
  а не строкой»: читает реальный bundled-шаблон, проверяет `tol.type == 'int'`
  и `coerceVarValue(default, type) is int`. Падает, если ноду снова объявят
  строкой.
- Детерминированная демонстрация до/после: `type:text → {"tolerance":"30"}`
  (String) против `type:int → {"tolerance":30}` (int).
- `if_engine_test.dart` — clamp int в uint16 `[0,65535]` (65536→65535, -5→0).
- `build_config_test.dart` (часть 2) — backstop: пустой required int userVar →
  default-число в конфиге; непустой → как есть; optional (`required:false`)
  пустой → НЕ подставляется (§033 не сломан).
- `widgets/template_var_list_test.dart` (часть 2) — UI: пустое required с
  default → самочинится + персистится; optional/secret пустые → НЕ чинятся;
  стирание required → `onChanged` не зовётся + errorText «Required»; ввод
  валидного → персист + ошибка снята.
