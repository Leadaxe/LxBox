# 096 — Единый `!`-negate во всех фильтрах + detour tri-state

| Поле | Значение |
|------|----------|
| Тип | UX + logic-rewrite (расширение §048/§083/§095 фильтра) |
| Триггер | Юзер: для диагностики разрыва полезно «только detour»; галка-enable перед regex бесполезна |
| Решение юзера | (1) Regex: галка слева → `!`-negate, enable убрать (regex активен пока поле непустое); мелкий prefix-`!` удалить. (2) Detour: **бинарный** `!` без чекбокса — `!` ON (дефолт) = «Hide detour servers», `!` OFF = «Show only detour servers» (нет состояния «показать всё»). (3) `!` как ведущая иконка-тогл, не отдельный чекбокс |

## Идея

Единый `!`-negate ([`NegateToggle`]) у каждой категории фильтра — серый =
обычный (match), bold-красный = инверсия (NOT). Консистентность логики во всех
вкладках + покрывает диагностический кейс «только detour».

## Модель

`!` — ведущая иконка-тогл слева от контрола категории (визуально как бывший
regex-`!`: `cs.error` когда активен, `onSurfaceVariant.withAlpha(140)` когда нет).

| Категория | контрол | выкл / пусто | on | on + `!` | тип |
|---|---|---|---|---|---|
| Regex | `[!]` + поле | нет фильтра | совпадает | НЕ совпадает | match |
| Protocol | `[!]` + чипы | нет фильтра | из выбранных | НЕ из выбранных | match |
| Subscribes | `[!]` + чипы | нет фильтра | из выбранных | НЕ из выбранных | match |
| Detour | `[!]` (без чекбокса) | — | `!` ON (дефолт) = скрыть detour | `!` OFF = только detour | **pool** |
| Ping | `[☐]` + поле | нет фильтра | ≤ N ms | — | match |

- **match**-фильтры → нон-матч приглушены/скрыты («Show non-matching»).
- **detour** → **pool** (физически убирает ноды → чистый список для диагностики).
  Бинарный: всегда что-то фильтрует (нет «показать всё»). Дефолт = скрыть detour
  (чистый список) — это «нормальный» режим, точку/чип НЕ зажигает; «только detour»
  = особый режим, зажигает.
- `!` у protocol/subscriptions имеет смысл только когда что-то выбрано (иначе no-op).

### Predicate (`NodeFilter.passes`)

Унифицировано: для regex/protocol/subscriptions — `fail когда member == invert`
(та же форма, что у regex `m == regexInvert`). `member`:
- regex — `hasMatch(tag)`;
- protocol — `proto != null && protocols.contains(proto)` (unknown → не member,
  под invert → проходит как «не VLESS»);
- subscription — `effective.any(subscriptions.contains)` (effective = candidates
  или `{'custom'}` при пустых).

Новые поля: `protocolsInvert`, `subscriptionsInvert` (`regexInvert` был).

### Detour бинарный (`NodeFilterViewModel`)

`bool _detourHide` (дефолт `true`), заменил `bool _showDetour`. Pool-предикат:

```dart
bool detourPoolPasses(bool isDetour) => _detourHide ? !isDetour : isDetour;
```

`detourHide=true` (дефолт, `!` ON) → проходят non-detour (скрыть detour);
`detourHide=false` (`!` OFF) → проходят только detour. `detourOnly => !_detourHide`
зажигает точку/чип (особый режим). **Глобальный** (не per-channel).

**Default-flip:** старый дефолт показывал все ноды; теперь дефолт скрывает
detour. Поэтому в presenter pool **control-узлы** (`isControlTag`) добавлены в
обход detour-фильтра — selector/urltest/direct никогда не должны исчезать.

### Regex enable убран

`_regexEnabled` удалён; `activeRegex => _regexCompiled` (null при пустом/невалидном);
галку-слот занял `[!]` (`toggleRegexInvert`). Выключение фильтра = очистка (✕).
`ChannelFilters.regexEnabled` тоже удалён.

## Файлы

- `node_filter.dart` — +`protocolsInvert`/`subscriptionsInvert`, унификация predicate.
- `node_filter_view_model.dart` — regex без enable; +protocol/subscription invert
  (per-channel); detour tri-state (глобальный) + `detourPoolPasses`; `detourActive`
  вместо `detourHidden`; `regexActive => compiled != null`.
- `channel_filters.dart` — −`regexEnabled`, +`protocolsInvert`/`subscriptionsInvert`.
- `node_list_presenter.dart` — pool через `detourPoolPasses` + control-bypass;
  `buildNodeFilter` пробрасывает invert-флаги.
- `filter_widgets.dart` — новый `NegateToggle`; `RegexFilterField` (ведущий `!`,
  без enable, prefix = лупа); `MultiSelectChipsRow` +ведущий `!`.
- `filter_panel.dart` — сводка-чипы с `!`-префиксом + detour-чип (шестерёнка,
  только в режиме «только detour»); detour-ряд на Settings (NegateToggle +
  динамический лейбл Hide/Show-only, без чекбокса).

## Тесты

`node_filter_test` (+protocol/subscription invert группы), `channel_filters_test`
(−regexEnabled, +invert поля), `node_filter_view_model_test` (regex без enable,
detour бинарный, invert-тоглы, per-channel invert), `node_list_presenter_test`
(NEW — pool detour-tri × `isDetour` × control-bypass, closes review HIGH-finding).

## Статус — DONE ✅ (device-verify на юзере)
