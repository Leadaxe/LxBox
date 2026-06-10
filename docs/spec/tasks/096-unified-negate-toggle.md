# 096 — Единый `!`-negate во всех фильтрах + detour tri-state

| Поле | Значение |
|------|----------|
| Тип | UX + logic-rewrite (расширение §048/§083/§095 фильтра) |
| Триггер | Юзер: для диагностики разрыва полезно «только detour»; галка-enable перед regex бесполезна |
| Решение юзера | (1) Regex: галка слева → `!`-negate, enable убрать (regex активен пока поле непустое); мелкий prefix-`!` удалить. (2) Detour: чекбокс-**enable** + `!`. Старт = чекбокс ВЫКЛ → показать всё. Чекбокс ВКЛ + `!` ON = скрыть detour; ВКЛ + `!` OFF = только detour. (3) `!` — ведущая иконка-тогл (у regex/protocol/subscriptions без чекбокса; у detour — с чекбоксом-enable) |

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
| Detour | `[☑]`enable + `[!]` | чекбокс ВЫКЛ (старт) = показать всё | вкл+`!` ON = скрыть detour | вкл+`!` OFF = только detour | **pool** |
| Ping | `[☐]` + поле | нет фильтра | ≤ N ms | — | match |

- **match**-фильтры → нон-матч приглушены/скрыты («Show non-matching»).
- **detour** → **pool** (физически убирает ноды → чистый список для диагностики).
  Чекбокс-enable ВЫКЛ (старт) → показать всё (filter off, точку/чип НЕ зажигает).
  ВКЛ → `!` ON = скрыть detour, OFF = только detour (любой вкл-режим зажигает).
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

### Detour (`NodeFilterViewModel`) — чекбокс-enable + `!`

`bool _detourEnabled` (чекбокс, дефолт `false` = старт «показать всё») +
`bool _detourHide` (`!`, дефолт `true`); заменили `bool _showDetour`. Pool-предикат:

```dart
bool detourPoolPasses(bool isDetour) =>
    !_detourEnabled || (_detourHide ? !isDetour : isDetour);
```

enabled=false (старт) → всё проходит (показать всё); enabled + hide → non-detour
(скрыть detour); enabled + !hide → только detour. `detourActive => _detourEnabled`
зажигает точку/чип; `detourOnly => enabled && !hide` выбирает иконку чипа
(⚙ только-detour vs ⊘ скрыт). **Глобальный** (не per-channel).

**Control-bypass:** при включённом detour-фильтре control-узлы (`isControlTag`:
selector/urltest/direct/…) НИКОГДА не отсеиваются pool'ом — иначе auto/direct
могли бы исчезнуть из списка.

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
- `filter_panel.dart` — сводка-чипы с `!`-префиксом + detour-чип (⚙ только-detour
  / ⊘ скрыт, когда фильтр вкл); detour-ряд на Settings: чекбокс-enable +
  NegateToggle (`!` независим от чекбокса, ON по умолчанию) + лейбл по `!` —
  Hide/Only detour servers; снятие галки лейбл НЕ меняет (вкл/выкл фильтра =
  чекбокс + summary-чип).

## Тесты

`node_filter_test` (+protocol/subscription invert группы), `channel_filters_test`
(−regexEnabled, +invert поля), `node_filter_view_model_test` (regex без enable,
detour чекбокс-enable+`!`, invert-тоглы, per-channel invert), `node_list_presenter_test`
(NEW — pool detour × `isDetour` × показать-всё/hide/only × control-bypass, closes review HIGH).

## Статус — DONE ✅ (device-verify на юзере)
