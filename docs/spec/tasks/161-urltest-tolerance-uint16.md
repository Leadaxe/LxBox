# 161 — Auto Proxy не стартует: `tolerance` уходит строкой в uint16-поле ядра

| Поле | Значение |
|------|----------|
| Статус | **Done** (2026-06-23) — `urltest_tolerance` переведён `type:text`→`type:int`. `flutter analyze` чисто, builder+e2e тесты прошли, добавлен регресс-тест. Вошло в v2.4.3. |
| Дата | 2026-06-23 |
| Тип | task (data-fix в `wizard_template.json`) + регресс-тест |
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

### Известное ограничение (не в scope)

Ядро ждёт `uint16` (0..65535). Пресет предлагает `200`, ручной ввод не
ограничен. Значение > 65535 пройдёт `int.tryParse`, но ядро снова отвергнет
на decode. Клампинг/валидация диапазона для `int`-нод — отдельной таской.

## Тесты

- `if_engine_test.dart` — регресс-тест «urltest_tolerance подставляется числом,
  а не строкой»: читает реальный bundled-шаблон, проверяет `tol.type == 'int'`
  и `coerceVarValue(default, type) is int`. Падает, если ноду снова объявят
  строкой.
- Детерминированная демонстрация до/после: `type:text → {"tolerance":"30"}`
  (String) против `type:int → {"tolerance":30}` (int).
