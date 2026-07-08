# 120 — Template engine: типизированные переменные + `#if`

| Поле | Значение |
|------|----------|
| Статус | Реализовано (Часть 1+2 + §119-миграция + §264 traffic-processing preset + §265 ref-vars); template-load-валидация `#if` — отдельным шагом |
| Дата старта | 2026-06-22 |
| Связанные spec'ы | [`026 parser v2`](../026%20parser%20v2/spec.md) — var-substitution pipeline живёт здесь; [`119 vpn-mode`](../119%20vpn-mode/spec.md) — `applyVpnMode` поглощается `#if`, `tun-in`/`mixed-in` уходят в шаблон; [`033 preset bundles`](../033%20preset%20bundles/spec.md) — `selectable_rules[].vars`, существующий `enabled:"@var"`-гейтинг поглощается `#if`; [`045 tls ech`](../045%20tls%20ech/spec.md) — ввёл `enabled:"@var"` convention в `preset_expand`; [`046 tunnel apps split-tunneling`](../046%20tunnel%20apps%20split-tunneling/spec.md) — `applyTunPackages` ищет `tun-in` в готовом `inbounds[]`, фазовая зависимость с `#if` |
| Прообраз | singbox-launcher `SPECS/067-F-N-TEMPLATE_EXPRESSIONS` — десктопный Go-движок; берём **дизайн** (`#if`, predicates, naming-дисциплина `#`/`@`/bare), НЕ код и НЕ формат шаблона |
| Затронутые файлы | **`app/lib/services/builder/if_engine.dart`** (НОВЫЙ — общее ядро: `coerceVarValue`, `makeResolver`, `walk`/`#if`, `Dropped` sentinel, `_matchCache`), `app/lib/models/parser_config.dart` (var-type комментарий + `int`), `app/lib/services/builder/build_config.dart` (`_substituteVars`→обёртка над `walk`; `byName`-ноды; проброс `vpn_mode`/`proxy_*` прямым присваиванием; убран `applyVpnMode` + sniff-removal), `app/lib/services/builder/preset_expand.dart` (`substituteVars`→делегат `walk`, `_Dropped`→общий `Dropped`), `app/lib/services/builder/post_steps/vpn_mode.dart` (**удалён**), `app/lib/services/builder/post_steps.dart` (снят `part` + import), `app/assets/wizard_template.json` (`tun_mtu`→`int`; `inbounds`/route-rules через `#if`; hidden-секция `_vpn_mode_internal` с нодами `vpn_mode`/`proxy_*`), `app/test/builder/if_engine_test.dart` (НОВЫЙ), `app/test/builder/vpn_mode_test.dart` (переписан под декларативный путь), `docs/TEMPLATE.md`, `docs/ARCHITECTURE.md` |

## Проблема

Движок подстановки переменных L×Box (`_substituteVars` / `_resolveVar`,
[`build_config.dart:459`](../../../app/lib/services/builder/build_config.dart#L459))
**угадывает тип значения по содержимому строки**, а не по объявленному в шаблоне
типу:

```dart
dynamic _resolveVar(dynamic value, Map<String, String> vars) {
  if (value is! String || !value.startsWith('@')) return null;
  final name = value.substring(1);
  if (!vars.containsKey(name)) return null;
  final v = vars[name]!;
  if (v == 'true') return true;          // строка → bool (по содержимому!)
  if (v == 'false') return false;
  return int.tryParse(v) ?? v;           // строка → int (по содержимому!)
}
```

Объявленный `WizardVar.type` (`bool`/`text`/`enum`/`secret`/`outbound`/`dns_servers`,
[`parser_config.dart:185`](../../../app/lib/models/parser_config.dart#L185)) **до
резолва не доезжает** — к строке 92 `build_config` богатая var-нода схлопывается
в плоский `Map<String, String>`:

```dart
vars[v.name] = settings.userVars[v.name] ?? v.defaultValue;  // type потерян
```

### Следствия (реальные баги, латентные и активный)

| Var | Объявленный `type` | Что делает движок | Статус |
|---|---|---|---|
| `tun_mtu` | `text` | default `1492` → коэрсится в `int` | **активный** mismatch type↔поведение (работает случайно) |
| `clash_secret` | `secret` | секрет `12345` стал бы `int 12345` | латентный (сейчас не наступали) |
| `auto_proxy_tag` | `text` | тег вида `123` стал бы `int` | латентный |
| *(будущий)* `proxy_pass` | `secret` | пароль `1234`/`true`/`007` исказился бы | блокирует §119 `mixed-in` в шаблоне |

Именно type-coercion — причина, по которой §119 `mixed-in` **строится
императивно** в коде ([`post_steps/vpn_mode.dart`](../../../app/lib/services/builder/post_steps/vpn_mode.dart)),
а не лежит в шаблоне: `users:[{username,password}]` с паролем через `@var`
словил бы coercion. Это нарушает консистентность — читатель `wizard_template.json`
видит только `tun-in` и делает вывод «socks/http inbound мы не умеем».

### Второй разрыв: условность только на уровне фрагмента

Шаблон умеет условность лишь грубо:
- `selectable_rules[].enabled: "@var"` ([`preset_expand.dart:122`](../../../app/lib/services/builder/preset_expand.dart#L122))
  — пропустить фрагмент, если bool-var ≠ `true`. Один флаг, без `and`/`or`/негации.
- `applyVpnMode` — императивная перестройка `inbounds[]` + route-rules в коде.

Условно включить **одно поле внутри объекта** (например `users` только при auth)
или **набрать список тегов по режиму** — движок не позволяет. Отсюда вся
структурная логика `tun|mixed` живёт в Dart, а не в шаблоне.

## Целевая модель

Единый **typed template engine** — в одном проходе, две связанные части (НЕ
разделяемые: `#if`-предикаты опираются на `node.type`):

1. **Типизированные переменные.** Var-нода (`type`/`default`/`title`/`tooltip`/…)
   — **всегда из шаблона**, единственный источник правды о метаданных. Значение —
   **из состояния** (`settings.userVars[name]`) с fallback на `node.default`.
   Coerce — **строго по `node.type`**, без угадывания по содержимому.

2. **`#if`-конструкт.** Декларативная условность прямо в JSON шаблона: map-spread
   (условное поле объекта) и array-element (условный элемент массива), с
   expression language (`and`/`or` + предикаты `#in`/`#not`/`#notEmpty`/…).
   Поглощает существующий `enabled:"@var"`.

> **Принцип:** метаданные из шаблона, данные из состояния, тип — из ноды.
> Это тот же дизайн, что у десктопного лаунчера (SPEC 067), но реализованный
> в нашем Dart-движке поверх существующих `WizardVar`/`selectable_rules` —
> **расширяем существующее, не кладём второй механизм рядом.**

---

## Часть 1 — Типизированные переменные

### Var-type enum

`WizardVar.type` сегодня — свободная строка. Расширяем перечень **явным `int`**
и фиксируем coerce-семантику каждого типа:

| `type` | Coerce в config | Прим. |
|---|---|---|
| `bool` | `'true'→true`, `'false'→false`, иначе → `false` + warn | строгое, не `int` |
| `int` | `int.tryParse`; не парсится → оставить строкой + warn | **новый явный тип** |
| `text` | **всегда String, дословно** | произвольный текст |
| `secret` | **всегда String, дословно** | пароли/секреты — никогда не коэрсить |
| `enum` | **всегда String**; опц. проверка ∈ `optionValues` | |
| `outbound` | **всегда String** | тег outbound'а |
| `dns_servers` | **всегда String** | тег dns-сервера (§033) |

**Ключевое:** «строковые» типы (`text`/`secret`/`enum`/`outbound`/`dns_servers`)
больше **не угадываются** — даже если значение выглядит как `123`/`true`, оно
остаётся строкой. Только `bool` и `int` коэрсятся, и только по объявленному типу.

### Поток типа до резолва

Сейчас (тип теряется):
```
template.vars (WizardVar{type}) ──┐
                                  ├─→ Map<String,String> vars ──→ _resolveVar (гадает)
settings.userVars (String) ───────┘
```

Станет (тип доезжает):
```
template.vars (WizardVar{type}) ──→ Map<String, WizardVar> byName ──┐
                                                                    ├─→ _resolveVar(node) (coerce по node.type)
settings.userVars (String) ─── значение ────────────────────────────┘
```

Реализация — `_substituteVars`/`_resolveVar` получают доступ к `Map<String,
WizardVar>` (имя → нода), а значение по-прежнему из плоского `vars` (state +
default). Coerce — функция `coerceVarValue(String raw, String type) → dynamic`.

```dart
dynamic coerceVarValue(String raw, String type) {
  switch (type) {
    case 'bool': return raw == 'true';          // строго; 'false'/прочее → false
    case 'int':  return int.tryParse(raw) ?? raw; // не-число → строка + warn
    default:     return raw;                     // text/secret/enum/outbound/dns_servers
  }
}
```

> **Var без объявления в шаблоне** (приходят из `userVars` вне `template.vars` —
> например legacy `clash_api`/`clash_secret`, см. [`build_config.dart:96`](../../../app/lib/services/builder/build_config.dart#L96)):
> при отсутствии ноды тип неизвестен → coerce как `text` (дословно строкой).
> Это **строже** текущего (не коэрсит), безопасно: clash_api/secret — строки.

### Persistence — НЕ меняется

`settings.userVars` по-прежнему `Map<name → String>`. Миграции нет, обратная
совместимость не требуется (решено с заказчиком): старые сохранённые значения
читаются тем же `userVars[name]`, просто теперь коэрсятся по `node.type`, а не по
содержимому. В состоянии хранится **только значение**; вся типизация — из шаблона.

### Ref-vars (§265)

Var-запись в `vars[]` может быть не декларацией, а **ссылкой** на уже
объявленную глобальную var:

```jsonc
{ "ref": "resolve_strategy" }
```

**Семантика.** Это не новый тип var, а **generic-механизм переиспользования**:
запись `{"ref":"<global-name>"}` не несёт собственных метаданных — `type` /
`options` / `title` / `tooltip` / `default` **НЕ дублируются**, а берутся из
целевой глобальной var. Значение живёт в **глобальном `userVars`** (не в
`rule.varsValues` пресета) — единый источник правды: правит его секция-владелец
глобали, а ref-запись лишь подключает ту же var в другом месте.

| Аспект | Обычная var | Ref-var `{"ref":"X"}` |
|---|---|---|
| Метаданные (`type`/`options`/…) | своя декларация | из глобали `X` (`WizardTemplate.globalVar("X")`) |
| Хранилище значения | `settings.userVars[name]` / `rule.varsValues` пресета | глобальный `settings.userVars["X"]` |
| Кто правит | владелец записи | секция-владелец глобали |
| Рендер в UI | обычный | **не рендерится** в редакторе-владельце ссылки |

**Модель.** `WizardVar` получил поле `ref` + геттер `isRef`;
`WizardVar.fromJson` парсит форму `{"ref":...}`; `WizardTemplate.globalVar(name)`
находит глобальную ноду по имени. Ref-var с `isRef==true` несёт только имя цели —
за метаданными всегда идём в глобаль.

**Билдер.** `expandPreset` получил параметр `globalVars`. В цикле по
`varsValues` пресета ref-vars **пропускаются** (у них нет локального значения) и
**подмешиваются из `globalVars`**, так что `@ref` в теле пресета резолвится
глобально — тем же значением, что видит секция-владелец.

**UI.** Ref-var **не рендерится** в редакторе правила: её метаданные и значение
принадлежат секции-владельцу глобали, там она и правится (иначе — два поля на одну
var с рассинхроном).

**Первое применение (§264).** Пресет `traffic-processing` ссылается на глобаль
`resolve_strategy` (осталась в секции Network) через `{"ref":"resolve_strategy"}`
вместо собственной копии — режим resolve и его стратегия остаются единым
источником правды.

### Изменения в шаблоне (Часть 1)

- `tun_mtu` — `type: "text"` → **`type: "int"`** (фактически уже int).
- Аудит всех `@var`, резолвящихся в config, на соответствие объявленного типа
  фактическому (карта собрана — единственный mismatch: `tun_mtu`).

---

## Часть 2 — `#if`-конструкт

Дизайн портирован из SPEC 067 (десктоп), адаптирован под Dart. Берём
**подмножество v1**, достаточное для §119-кейса и поглощения `enabled:"@var"`.
**НЕ берём** (vs 067): `params[]`-механику (решено — не нужна), `@runtime.*`
globals (у нас одна платформа — Android; нет нужды в platform/arch predicates).

### Naming-дисциплина

| Префикс | Что | Где |
|---|---|---|
| `#` | control-construct / predicate (`#if`, `#in`, `#not`, `#notEmpty`, `#isEmpty`, `#notIn`, `#matches`) | gateway-ключи + предикаты в `and`/`or` |
| `@` | var-ref (только имена из `vars[]`) | placeholder в значениях, ключ предиката |
| bare | inner-ключи тела `#if` (`and`/`or`/`value`/`else`) | только внутри `#if` |

Неизвестный `#*`-ключ → warn + drop (forward-compat).

### Форма

```jsonc
"#if": {
  "and":   [<predicate>, ...],   // взаимоисключающе с or
  "or":    [<predicate>, ...],   // взаимоисключающе с and
  "value": <any JSON>,           // then-ветка (обязательно)
  "else":  <any JSON>            // else-ветка (опционально)
}
```

- Ровно один из `and`/`or` присутствует и непустой (иначе template-load error).
- `and` — все true (short-circuit на первом false). `or` — хотя бы один true.

### Предикаты (подмножество v1)

| Форма | Семантика |
|---|---|
| `"@var"` | bool-var → `value == "true"` |
| `{"@var": "literal"}` | equality: `trim(value) == "literal"` |
| `{"@var": "#notEmpty"}` | text → `len(trim) > 0`; bool → `== "true"` |
| `{"@var": "#isEmpty"}` | инверсия `#notEmpty` |
| `{"@var": {"#in": ["a","b"]}}` | `trim(value)` ∈ списке |
| `{"@var": {"#notIn": ["a","b"]}}` | `trim(value)` ∉ списке |
| `{"@var": {"#matches": "^re$"}}` | `trim(value)` матчит RegExp |
| `{"#not": <predicate>}` | унарная негация (рекурсивно) |

Тип `@var` в предикате проверяется по `node.type` (Часть 1): bare-bool-форма —
только для `bool`-var; `#in`/`#matches`/equality — для `text`/`enum`. `#notEmpty`/
`#isEmpty` — read-only проверка длины, допустима для `text`/`secret`/`enum`/`bool`
(для `secret` это безопасно — длина не раскрывает и не коэрсит значение).
Mismatch → template-load error.

### Порядок резолва (top-down, lazy)

Walker сначала вычисляет предикат **внешнего** `#if`, выбирает ветку
(`value`/`else`/drop), и **только потом** рекурсивно подставляет vars и резолвит
вложенные `#if` **внутри выбранной ветки**. Отброшенная ветка **не обходится** —
ни warn, ни выполнение предикатов из неё (предикат-валидация и так на template-
load, но runtime-обход дропнутой ветки = лишняя работа + ложные warn). Это ровно
семантика прообраза 067. Array-compaction (длина −1 при drop) выполняется при
обходе списка, **до** рекурсии в тела уцелевших элементов. Гарантия — никаких
повторных обходов уже подставленной ветки (single-pass, см. требование
производительности).

### Два режима размещения

**Map-spread** — `#if` как ключ внутри объекта. true → поля `value` (обязан быть
объектом) мерджатся в родителя; false+else → поля `else`; false без else → ключ
просто удаляется. Ключ `#if` всегда снимается.

> **Коллизия ключей (находка E).** Ключи `value`/`else` **не должны** совпадать
> с уже присутствующими ключами родителя — ни с литеральными, ни с привнесёнными
> сиблинг-`#if`-спредом, ни с ключами объемлющего `#if` (вложенность). Коллизия —
> **template-load error** (`#if map-spread value key X collides with parent key
> X`), не silent overwrite (дисциплина «невалидный шаблон = баг разработчика на
> load»). Проверка коллизий выполняется **после** резолва вложенных `#if`, чтобы
> ключи nested-спреда были видны.

```jsonc
{ "type": "@proxy_type", "tag": "mixed-in",
  "listen": "@proxy_listen", "listen_port": "@proxy_port",
  "#if": { "and": ["@proxy_auth"], "value": {
    "users": [{"username": "@proxy_user", "password": "@proxy_pass"}]
  }}
}
```

**Array-element** — `#if` как единственный ключ объекта-элемента массива. true →
элемент заменяется на `value`; false+else → на `else`; false без else → элемент
**выпадает** (длина −1).

```jsonc
"inbound": [
  {"#if": {"and": [{"@vpn_mode": {"#in": ["vpn", "vpn_proxy"]}}],   "value": "tun-in"}},
  {"#if": {"and": [{"@vpn_mode": {"#in": ["proxy", "vpn_proxy"]}}], "value": "mixed-in"}}
]
```

### Поглощение `enabled:"@var"`

Существующий гейт `selectable_rules` `enabled:"@var"`
([`preset_expand.dart:122`](../../../app/lib/services/builder/preset_expand.dart#L122))
— частный случай array-element `#if` с bare-bool-предикатом. После §120 он
становится синтаксическим сахаром / переписывается на `#if` (фрагмент = элемент,
`enabled:false` → выпадение). **Не оставляем два механизма** — `#if` единственный.

---

## §119 `mixed-in`/`tun-in` → декларативно (применение Части 1+2)

Цель заказчика: `tun | mixed` — данные в шаблоне, не код. `applyVpnMode`
**удаляется целиком**.

### Новые vars

| name | type | значения |
|---|---|---|
| `vpn_mode` | `enum` | `vpn` / `proxy` / `vpn_proxy` |
| `proxy_type` | `text` | `mixed` / `http` / `socks` (зажат в storage) |
| `proxy_listen` | `text` | `127.0.0.1` / `0.0.0.0` (зажат в storage) |
| `proxy_port` | `int` | порт (default 2080) |
| `proxy_user` | `text` | username |
| `proxy_pass` | `secret` | password |
| `proxy_auth` | `bool` | **эффективный** auth-флаг (см. ниже) |

Одна enum-var `vpn_mode` — единый источник правды (не два булевых флага).
Значения родные из [`VpnModeConfig`](../../../app/lib/services/settings_storage/vpn_mode.dart#L79),
ноль маппинга.

> **Два правила, иначе ломается load/runtime (находки D, B, C, J ревью):**
>
> 1. **Объявление нод (D).** Все эти vars **обязаны быть объявлены как
>    `WizardVar`-ноды** в `wizard_template.json` (`sections[].vars[]` блок) с
>    указанным `type` — иначе `#if`-предикат над ними → template-load error
>    «несуществующая var» (валидатор требует существующую ноду с совместимым
>    типом, см. §«Валидация»). Метаданные (type) живут в ноде; `VpnModeConfig`
>    поставляет только **значения**.
>
> 2. **`proxy_type`/`proxy_listen` = `text`, не `enum` (J).** `_getVpnMode`
>    ([`vpn_mode.dart:28`](../../../app/lib/services/settings_storage/vpn_mode.dart#L28))
>    уже зажимает `proxyProtocol ∈ {mixed,http,socks}` и `proxyListen ∈
>    {127.0.0.1,0.0.0.0}` на чтении из storage — template-side enum-валидация
>    избыточна. `text` (дословная строка) — корректно и не плодит мёртвый
>    optionValues-список, который пришлось бы синхронизировать с константами.
>
> 3. **Проброс — прямым присваиванием в плоский `vars`, НЕ в `userVars` (B).**
>    `vpn_mode`/`proxy_*` сегодня живут в `settings.vpnMode` (typed
>    `VpnModeConfig`), а **не** в `settings.userVars`. Значения кладутся в
>    плоский `vars`-map **прямым `vars[k]=v`** на этапе сборки (между
>    `_ensureClashApiDefaults` и `_substituteVars`, см. §«Фазировка») —
>    **не** `putIfAbsent` и **не** через line-92 userVars-first merge: live
>    `VpnModeConfig` обязан побеждать любой залежавшийся flat-userVar
>    (иначе сохранённый `vpn_mode`-userVar затенил бы реальный режим).
>    При `settings.vpnMode == null` → `vars['vpn_mode'] = 'vpn'` (degrade
>    к tun-only; иначе оба inbound-`#if` дропнутся → пустой `inbounds[]`).
>
> 4. **`proxy_auth` несёт `effectiveAuth && proxyPassword.isNotEmpty`, не просто
>    `effectiveAuth` (C).** Текущий `applyVpnMode` добавляет `users` только при
>    `effectiveAuth && proxyPassword.isNotEmpty`
>    ([`vpn_mode.dart:50`](../../../app/lib/services/builder/post_steps/vpn_mode.dart#L50))
>    — пустой пароль при включённом auth (в т.ч. 0.0.0.0, где auth форсится)
>    **не** должен порождать `users:[{...,password:""}]` (защита 067, см.
>    Открытые вопросы). Поэтому в `vars['proxy_auth']` кладётся
>    `(effectiveAuth && proxyPassword.isNotEmpty) ? 'true' : 'false'` —
>    одно-предикатный гейт `{"and":["@proxy_auth"]}` в шаблоне остаётся как есть
>    и воспроизводит поведение точно.

### Шаблон — `inbounds[]`

```jsonc
"inbounds": [
  {"#if": {"and": [{"@vpn_mode": {"#in": ["vpn", "vpn_proxy"]}}], "value": {
    "type": "tun", "tag": "tun-in",
    "interface_name": "@tun_name", "address": "@tun_address", "mtu": "@tun_mtu",
    "auto_route": "@tun_auto_route", "strict_route": "@tun_strict_route", "stack": "@tun_stack"
  }}},
  {"#if": {"and": [{"@vpn_mode": {"#in": ["proxy", "vpn_proxy"]}}], "value": {
    "type": "@proxy_type", "tag": "mixed-in",
    "listen": "@proxy_listen", "listen_port": "@proxy_port",
    "#if": {"and": ["@proxy_auth"], "value": {
      "users": [{"username": "@proxy_user", "password": "@proxy_pass"}]
    }}
  }}}
]
```

### Шаблон — route-rules `inbound` (Форма A через `#in`)

```jsonc
"rules": [
  { "action": "resolve",
    "inbound": [
      {"#if": {"and": [{"@vpn_mode": {"#in": ["vpn", "vpn_proxy"]}}],   "value": "tun-in"}},
      {"#if": {"and": [{"@vpn_mode": {"#in": ["proxy", "vpn_proxy"]}}], "value": "mixed-in"}}
    ],
    "strategy": "@resolve_strategy" },
  { "action": "sniff",
    "inbound": [
      {"#if": {"and": [{"@vpn_mode": {"#in": ["vpn", "vpn_proxy"]}}],   "value": "tun-in"}},
      {"#if": {"and": [{"@vpn_mode": {"#in": ["proxy", "vpn_proxy"]}}], "value": "mixed-in"}}
    ],
    "timeout": "1s" },
  { "protocol": "dns", "action": "hijack-dns" }
]
```

Результат по режимам:

| `vpn_mode` | `inbounds[]` | `inbound` в rules | `users` |
|---|---|---|---|
| `vpn` | `[tun-in]` | `[tun-in]` | — |
| `proxy` | `[mixed-in]` | `[mixed-in]` | по `@proxy_auth` |
| `vpn_proxy` | `[tun-in, mixed-in]` | `[tun-in, mixed-in]` | по `@proxy_auth` |

> **scalar→array (находка H).** Раньше `inbound` был **скаляром** (`"tun-in"`),
> теперь — **массив** (`["tun-in"]`/`["mixed-in"]`/`["tun-in","mixed-in"]`).
> sing-box `route.rules[].inbound` — `Listable[string]`: 1-элементный массив
> `["mixed-in"]` трактуется тождественно скаляру `"mixed-in"`. Поэтому
> post-collapse в скаляр **не нужен**; различие структурное, но семантически
> инертное (см. acceptance: сверять по нормализованной форме, не байт-в-байт).
> `docs/TEMPLATE.md` §463-описание обновить под array-вид.

`@proxy_auth` уже несёт эффективный bool (`effectiveAuth && proxyPassword
непуст`, правило 4 выше) — шаблон не вычисляет ничего, только гейтит. 0.0.0.0
форсит `effectiveAuth=true` на storage-стороне
([`vpn_mode.dart:125`](../../../app/lib/services/settings_storage/vpn_mode.dart#L125)).

### `sniff_enabled`

Сегодня sniff-rule удаляется отдельным шагом ([`build_config.dart:107`](../../../app/lib/services/builder/build_config.dart#L107))
при `sniff_enabled == 'false'`. Переводится на `#if` array-element: весь
sniff-rule оборачивается `{"#if": {"and": ["@sniff_enabled"], "value": {...}}}`.
Шаг-removal удаляется.

> **Обновлено §264.** Механика `#if` над `sniff_enabled` осталась той же, но сам
> **var-объявление переехало из секции Network в locked-пресет
> `traffic-processing`** (см. [§264 Traffic Processing preset](#264-traffic-processing-preset)).
> Вместе с ним переехали базовые правила `sniff`/`hijack-dns`/`resolve` из
> `config.route.rules` шаблона (теперь `[]`) — каждое под своим `#if` **внутри
> пресета**. `resolve_enabled` также переехал в пресет собственным var;
> `resolve_strategy` **осталась** в секции Network, пресет ссылается на неё через
> ref-var `{"ref":"resolve_strategy"}` (см. [Ref-vars (§265)](#ref-vars-265)).
> Сам `#if`-движок не меняется — меняется только **владелец** объявления var.

---

## §264 Traffic Processing preset (применение Части 2 + §265)

Базовые правила обработки трафика (`sniff` / `hijack-dns` / `resolve`) переезжают
из хардкода `config.route.rules` шаблона в **новый locked/pinned пресет
`traffic-processing`** — первый в `selectable_rules`. Это делает раскладку sniff
и resolve видимой и настраиваемой в UI, но защищённой от поломки (locked/pinned).

### Метаданные пресетов → объект `ui`

Плоские `label`/`description`/`default` у пресета **заменены** на объект:

```jsonc
"ui": { "label": "...", "description": "...", "default": true,
        "locked": true, "pinned": 0 }
```

- **Все 8 пресетов** переведены на `ui`; плоские `label`/`description`/`default`
  из шаблона **убраны**, fallback в `SelectableRule.fromJson` **снят** — читается
  **только** `ui`.
- `locked: true` — свич disabled, пресет нельзя удалить и нельзя двигать (в UI
  нет drag-handle).
- `pinned: 0` — пресет всегда на позиции 0 и в списке, и в `route.rules`
  (критично: `sniff` обязан быть первым правилом).

### `config.route.rules` → пустой

`config.route.rules` в шаблоне теперь `[]`. Правила `sniff`/`hijack-dns`/`resolve`
**переехали в пресет** `traffic-processing`, каждое под своим `#if` (та же
`#if`-механика Части 2 — array-element/gate).

### Vars пресета `traffic-processing`

| name | type | прим. |
|---|---|---|
| `sniff_enabled` | `bool` | переехал из секции Network |
| `sniff_timeout` | `enum` | **новая**: `100ms`/`300ms`/`500ms`/`1s`/`3s` (был хардкод `timeout:"1s"`) |
| `hijack_dns_enabled` | `bool` | **новая**: WARNING-тултип — off ломает FakeIP |
| `resolve_enabled` | `bool` | переехал из секции Network |
| `{"ref":"resolve_strategy"}` | — | ref-var на глобаль (§265); стратегия остаётся в Network |

Из секции Network (chapter core) **убраны** vars `sniff_enabled` и
`resolve_enabled` (переехали в пресет собственными vars). `resolve_strategy`
**осталась** в Network — пресет ссылается на неё через ref-var (§265).
`auto_detect_interface` осталась в Network.

### Нормализация pinned-пресета

`normalize_pinned_presets.dart` гарантирует **наличие и позицию** pinned-пресета
в `selectable_rules` — на fresh-конфиге, restore из backup и upgrade со старой
раскладки (upgrade-safe): если пресет отсутствует, добавляется; если не на
позиции `pinned`, переставляется.

### Debug API

`serializers/rules.dart`: в сериализацию пресета добавлены поля `locked` и
`pinned` (симметрия read с новой моделью).

### §263 superseded

§263 (тумблер `resolve_enabled` в секции Network) **вытеснен** этой фичей:
`resolve_enabled` теперь var пресета `traffic-processing`, а не отдельный тумблер
Network. Механика гейта (`inbound:tun-in` по `@resolve_enabled`) сохраняется —
меняется только владелец var.

---

## Фазировка (критично — порядок с post-steps)

`#if`-walker исполняется **внутри** `_substituteVars`
([`build_config.dart:104`](../../../app/lib/services/builder/build_config.dart#L104))
— это фаза подстановки, **до** post-steps:

```
 91  vars = { template.vars merge + userVars putIfAbsent }   (стр. 91-98)
101  _ensureClashApiDefaults(vars, generated)
─── НОВЫЙ ШАГ (между 101 и 104, прямое присваивание — НЕ putIfAbsent) ───
     if (settings.vpnMode != null) {
       final cfg = settings.vpnMode!;
       vars['vpn_mode']     = cfg.mode;
       vars['proxy_type']   = cfg.proxyProtocol;
       vars['proxy_listen'] = cfg.proxyListen;
       vars['proxy_port']   = '${cfg.proxyPort}';
       vars['proxy_user']   = cfg.proxyUsername;
       vars['proxy_pass']   = cfg.proxyPassword;
       vars['proxy_auth']   = (cfg.effectiveAuth && cfg.proxyPassword.isNotEmpty) ? 'true' : 'false';
     } else {
       vars['vpn_mode'] = 'vpn';   // degrade к tun-only (иначе пустой inbounds[])
     }
────────────────────────────────────────────────────────────────────────
103  config = deepCopyJson(template.config)
104  _substituteVars(config, vars, byName)   ← #if резолвится ЗДЕСЬ
107  (sniff-removal — УДАЛЯЕТСЯ, переехал в #if)
291  applyVpnMode(...)                       ← УДАЛЯЕТСЯ целиком
301  applyTunPackages(config, ...)           ← §046, ищет tun-in в ГОТОВОМ inbounds[]
304  validateConfig(config)
```

К моменту §046 (`applyTunPackages`, строка 301) `inbounds[]` уже финальный: в
режиме `proxy` `tun-in` физически отсутствует (`#if` его выкинул) → §046
корректно no-op'ит (он ищет по `type=='tun'`,
[`tun_packages.dart:24`](../../../app/lib/services/builder/post_steps/tun_packages.dart#L24),
а не по тегу — устойчиво). **Порядковая зависимость, ради которой `applyVpnMode`
стоял до §046, сохраняется автоматически** — подстановка идёт перед post-steps.
Спец-кода не нужно.

> **Проброс — прямым присваиванием (находка B).** Шаг выше идёт **после**
> `_ensureClashApiDefaults` и **до** `_substituteVars`, через `vars[k]=v`
> (НЕ `putIfAbsent`): live `VpnModeConfig` побеждает любой сохранённый
> flat-userVar. `null`-vpnMode → `vpn_mode='vpn'` (сохраняет сегодняшнее
> `null==vpn` поведение `applyVpnMode`).

> **`#matches` RegExp — компилировать один раз (находка F).** Walker исполняется
> на `deepCopyJson(template.config)` каждый `buildConfig`; наивная реализация
> звала бы `RegExp(pattern)` на каждом проходе. Держать `static
> Map<String,RegExp> _matchCache` на уровне модуля `build_config`, заполняемый
> лениво по паттерну (RegExp immutable — шарить безопасно даже при deepCopy).
> Никаких `RegExp(...)` per-node внутри walker.

### Два движка подстановки — важно (находка из map-фазы)

В проекте **два разных** substitution-движка:
- `_substituteVars`/`_resolveVar` ([`build_config.dart:459`](../../../app/lib/services/builder/build_config.dart#L459))
  — мутирует на месте, void, coerce bool/int; зовётся на `config` (стр.104) и на
  `preset.options` (стр.420).
- `substituteVars` ([`preset_expand.dart:376`](../../../app/lib/services/builder/preset_expand.dart#L376))
  — возвращает значение, `Map<String,dynamic>`, уже имеет drop-семантику через
  sentinel `_Dropped` (optional-vars §033); зовётся на `preset.ruleSets`/`rule`/
  `dnsRule`/`dnsServers`.

`#if`-walker, добавленный в `_substituteVars`, **автоматически** покроет `config`
и `preset.options`, но **НЕ** тела пресетов (`ruleSets`/`rule`/…) — они идут
через `substituteVars`. Поглощение `enabled:"@var"` (§045) живёт именно там.
**Решение:** вынести `#if`-walker и predicate-eval в общий хелпер, вызываемый из
обоих движков (не дублировать логику). `substituteVars` уже имеет `_Dropped` —
array-element-drop `#if` ложится на него естественно.

---

## Валидация шаблона (на load, не на config)

`validateConfig` ([`validator.dart:15`](../../../app/lib/services/builder/validator.dart#L15))
работает на **готовом** config (post-substitution) — он остаётся как есть.
Валидация **`#if`-форм и типов vars** — это **template-load-time** проверка,
живёт в `TemplateLoader`/`WizardVar.fromJson` (другой слой). Проверяет:

- ровно один из `and`/`or`, непустой;
- `value` присутствует;
- map-spread `value`/`else` — объект (иначе нечего мерджить);
- map-spread `value`/`else` не вносит ключ, уже существующий у родителя
  (литеральный или от сиблинг/вложенного `#if`-спреда) → error (находка E);
- предикат ссылается на **существующую** var (нода в `template.vars`); тип var
  совместим с формой предиката (находка D — `vpn_mode`/`proxy_*` обязаны быть
  объявлены как ноды);
- `#matches` — RegExp компилируется без ошибок;
- bare-bool-предикат — только `bool`-var; `#in`/equality/`#matches` — не для
  `bool`-var.

**Разграничение unknown-`#*` (находка I):**
- неизвестный `#*`-ключ как **сиблинг** `#if` в map (не один из `{#if}`) →
  **warn + drop** (forward-compat, безвреден);
- неизвестный **bare inner-ключ** в теле `#if` (не из `{and,or,value,else}`) →
  **template-load error** (схема тела закрыта);
- неизвестный `#*`-**предикат-оператор** (напр. `#frobnicate` в `{"@v":{...}}`) →
  **template-load error** (никогда не трактовать предикат как vacuously
  true/false — иначе тихий misroute).

Невалидный `#if` в bundled-шаблоне → assert/исключение на load (баг разработчика,
не runtime юзера — шаблон зашит в asset).

---

## Затронутые файлы

| Файл | Изменение |
|---|---|
| `app/lib/models/parser_config.dart` | var-type: задокументировать enum + `int`; helper-классификатор «строковый ли тип» |
| `app/lib/services/builder/build_config.dart` | `_resolveVar`/`_substituteVars` → принимают `Map<String,WizardVar> byName`, coerce по `node.type`; `#if`-walker (map-spread + array-element + predicates); проброс `vpn_mode`/`proxy_*` в `vars`; убрать вызов `applyVpnMode` + sniff-removal-шаг |
| `app/lib/services/builder/preset_expand.dart` | `enabled:"@var"` → поглощается `#if` (единый механизм) |
| `app/lib/services/builder/post_steps/vpn_mode.dart` | **удаляется** |
| `app/lib/services/builder/post_steps.dart` | снять `part` vpn_mode |
| `app/lib/services/template_loader.dart` | template-load-time валидация `#if` + типов предикатов |
| `app/assets/wizard_template.json` | `tun_mtu`→`int`; `inbounds[]` tun/mixed через `#if`; route-rules `inbound` через `#if`; sniff-rule через `#if`; новые vars `vpn_mode`/`proxy_*` |
| `docs/TEMPLATE.md` | раздел про `#if` + var-types + coerce-семантику; обновить §119-описание (mixed-in теперь в шаблоне) |
| `docs/ARCHITECTURE.md` | Parser v2 pipeline: `#if`-walker в substitution-фазе |
| **§265 ref-vars** | |
| `app/lib/models/parser_config.dart` | `WizardVar.ref` + `isRef` + `fromJson({"ref":...})`; `WizardTemplate.globalVar(name)` |
| `app/lib/services/builder/preset_expand.dart` | `expandPreset` принимает `globalVars`; ref-vars пропускаются в `varsValues`-цикле, подмешиваются из `globalVars` |
| *(UI редактора правила)* | ref-var не рендерится (правится в секции-владельце глобали) |
| **§264 traffic-processing preset** | |
| `app/assets/wizard_template.json` | новый locked/pinned пресет `traffic-processing` первым в `selectable_rules`; метаданные всех 8 пресетов → объект `ui{label,description,default,locked,pinned}`; плоские label/description/default убраны; `config.route.rules`→`[]` (sniff/hijack-dns/resolve переехали в пресет под `#if`); из секции Network убраны vars `sniff_enabled`/`resolve_enabled` (`resolve_strategy` осталась); vars пресета: `sniff_enabled`/`sniff_timeout`(enum,новая)/`hijack_dns_enabled`(bool,новая)/`resolve_enabled`/`{"ref":"resolve_strategy"}` |
| `app/lib/models/…` `SelectableRule` | чтение `ui.{label,description,default,locked,pinned}`; fallback на плоские поля СНЯТ |
| `app/lib/services/builder/normalize_pinned_presets.dart` | **НОВЫЙ** — гарантирует наличие+позицию pinned-пресета (fresh/restore/upgrade-safe) |
| `app/lib/…/serializers/rules.dart` | Debug API: `locked`/`pinned` в сериализацию пресета |
| *(UI списка пресетов)* | locked → свич disabled, нет удаления, нет drag-handle; pinned → позиция 0 |

---

## Тесты (acceptance)

### Часть 1 — типизация
- `coerceVarValue`: `bool`/`int`/`text`/`secret`/`enum` — корректный тип.
- `secret`/`text` со значением `12345`/`true` → остаётся String (НЕ коэрсится).
- `int`-var с не-числом → строка + warn (не throw).
- var без ноды (legacy `clash_secret`) → String.
- golden: `tun_mtu` в config — число (как раньше), но через `type:"int"`.

### Часть 2 — `#if`
- map-spread: and-true+value → merge; and-false без else → ключ снят; and-false+else → else merged.
- array-element: true → replace; false без else → drop (len−1); false+else → else.
- predicates: equality, `#in`, `#notIn`, `#notEmpty`/`#isEmpty`, `#matches`, `#not` (в т.ч. двойная негация).
- **вложенный `#if` порядок (G):** (a) outer-true → внутренний `#if` в `value` резолвится; (b) outer-false → внутренний `#if` в отброшенной (then) ветке **не** вычисляется (ни warn, ни predicate-eval); (c) `#if` во взятой `else`-ветке резолвится.
- **коллизия merge (E):** map-spread value-ключ совпадает с литеральным ключом родителя → template-load error; то же для else-ветки и nested-спреда.
- **unknown `#*` (I):** сиблинг `#*`-ключ → drop+warn; bare inner-ключ (`xor`) в теле `#if` → load-error; unknown предикат-оператор (`#frobnicate`) → load-error.
- template-load: оба `and`+`or` → error; ни одного → error; `value` нет → error; map-spread scalar value → error; predicate на несуществующую var → error; type-mismatch предиката → error; `#matches` битый regex → error.

### §119-интеграция (golden, **семантическая** эквивалентность)

> **НЕ byte-identity к `applyVpnMode` (находки A, H).** Новый шаблон даёт **одно**
> resolve/sniff-правило на действие с `inbound` как **массивом**, против прежней
> раскладки `applyVpnMode` (в `vpn_proxy` prepend'ились 2 отдельных mixed-in-
> правила → 5 правил со scalar `inbound`). Эквивалентность гарантируется тем, что
> sing-box трактует `inbound:"x"` ≡ `inbound:["x"]` (`Listable[string]`), а
> порядок resolve/sniff/hijack-dns для разных inbound-наборов инертен. Goldens
> сверяют **явную ожидаемую форму per-mode** (ниже), НЕ diff против legacy-output.
> Допустимые расхождения с прежним: (a) `inbound` всегда array; (b) `vpn_proxy` —
> 3 правила вместо 5; (c) `strategy` покрывает оба inbound одной resolve-rule.

- `vpn_mode=vpn` → `inbounds:[tun-in]`; rules: resolve+sniff с `inbound:["tun-in"]`, нет mixed.
- `vpn_mode=proxy` → `inbounds:[mixed-in]`; rules `inbound:["mixed-in"]`; **нет** правила с `inbound`, ссылающимся на `tun-in` (нет dangling); `applyTunPackages` no-op.
- `vpn_mode=vpn_proxy` → `inbounds:[tun-in, mixed-in]`; rules `inbound:["tun-in","mixed-in"]`.
- `proxy_auth=true` + `proxy_pass="x"` → `users:[{user,x}]` присутствует.
- `proxy_auth=false` → `users` отсутствует.
- **`proxy_auth=true` + `proxy_pass=""` → `users` отсутствует** (защита 067, парирует `[{"":""}]`); **особенно `proxy_listen=0.0.0.0`** (effectiveAuth форсится) — всё равно нет `users`. (Соответствует [`vpn_mode_test.dart:208`](../../../app/test/builder/vpn_mode_test.dart#L208).)
- `proxy_pass="1234"` → `password:"1234"` (строка, не int — Часть 1).
- `settings.vpnMode==null` → `inbounds:[tun-in]` (degrade к vpn, не пустой массив).

### Регрессия
- существующие parser/builder/pipeline_e2e тесты зелёные.
- `vpn_mode_test.dart` (23 теста) — переписать под декларативный путь: тесты строят шаблон с `#if`-inbounds/rules и `BuildSettings(vpnMode:...)`, проверяют ту же семантику (вместо вызова удалённого `applyVpnMode`).
- `selectable_rules` `enabled` через `#if` даёт тот же результат, что прежний гейт ([`preset_expand.dart:121`](../../../app/lib/services/builder/preset_expand.dart#L121)).
- `tun_packages_test.dart` — `applyTunPackages` находит tun по `type=='tun'`, не по индексу; conditional-tun не ломает.
- `selectable_rules` `enabled` через `#if` даёт тот же результат, что прежний гейт.

---

## Открытые вопросы / out of scope

- **`secret`-UI рендеринг.** Урок из 067 (§«type:secret UI rendering»): на
  десктопе `secret`-vars кроме `clash_secret` **молча невидимы** в UI → юзер не
  вводит пароль → `users:[{"":""}]` (сломанный auth). У нас `proxy_pass` вводится
  в [`vpn_mode_tab.dart`](../../../app/lib/screens/vpn_mode_tab.dart) (не через
  generic var-форму), поэтому риск не повторяется — но **проверить**, что ни одно
  `secret`-поле не теряется, если когда-нибудь будет рендериться generic-формой.
  Маскирование пароля (`•••`) — отдельная UI-задача, не в scope.
- **Predicates v2** (`#gt`/`#lt`/`#startsWith`/…) — YAGNI, не реализуем до кейса.
- **`@runtime.*` globals** — не нужны (одна платформа). Если появится desktop-
  parity — заводить тогда.
- **`params[]`-механика** — решено НЕ делать; условность через `#if`.
- **Единый формат шаблона с лаунчером** — не цель; top-level ключи остаются наши
  (`sections`/`preset_groups`/`selectable_rules`). Унификация — по дизайну
  (`#if`, predicates, naming), не по файлу.
