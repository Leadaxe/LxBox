# §125 — Настраиваемые каналы (Configurable Channels)

> **СТАТУС: РЕАЛИЗОВАНО (27.06.2026).** Все фазы F0→F4 + regex (F2) + default
> (F3) реализованы в ветке `feat/configurable-channels-125`. План и трассировка
> — [`plan.md`](plan.md). Числа/имена ключей storage финализированы (см.
> [STORAGE.md → channels](../../../STORAGE.md#channels--125)). Все развилки
> решены (см. «Решения», бывшие open questions). Покрыто тестами
> (`channel_test.dart`, `channels_migration_test.dart`, `channel_groups_test.dart`).

## Контекст

Сейчас «каналы» роутинга (`vpn-1..vpn-4` + `✨auto`) — это `preset_groups[]`
из [`wizard_template.json`](../../../app/assets/wizard_template.json). Они **статичны**:
юзер может только **включить/выключить** канал тоглом в Routing → таб Channels.
Всё остальное (label, default-выбор, набор нод, тип) зашито в template и не редактируется.

Модель: [`PresetGroup`](../../../app/lib/models/parser_config.dart#L105) (`tag`, `type`,
`label`, `defaultEnabled`, `options`, `addOutbounds`). Runtime-снимок от ядра —
[`CcGroup`](../../../app/lib/vpn/cc_channel.dart) (`selected`, `items`).

Билдер: [`_buildPresetGroups`](../../../app/lib/services/builder/build_config.dart#L412)
эмитит для каждого активного канала outbound-группу. Сейчас **все** selector-каналы
получают **один общий** список нод `selectorTags`
([build_config.dart:433](../../../app/lib/services/builder/build_config.dart#L433));
urltest-канал (`✨auto`) — `autoTags` (тот же набор, минус `excludedNodes` глобального
фильтра §048). Per-channel набор нод — **нет**, это самый тяжёлый кусок фичи.

Что **уже** персистится per-channel:
- `enabled_groups[]` — какие каналы включены ([STORAGE.md](../../STORAGE.md)).
- `ping_options.groups[tag]` — per-group ping url/timeout (§008).

Что зашито в template и **НЕ** редактируется: `label`, `type`, `options.default`,
`add_outbounds`, набор нод (общий), само существование канала (vpn-1..vpn-4 фиксированы).

## Цель

Превратить каналы из статичных template-сущностей в **полноценно настраиваемые
пользователем** объекты с CRUD и per-channel конфигурацией:

1. **CRUD** — создавать новые каналы и удалять (кроме vpn-1). Лимит **10 каналов**.
2. **Тайтл** — менять отображаемое имя канала.
3. **Опции селектора (галки)**:
   - **direct** — добавить `direct-out` опцией в селектор канала.
   - **auto** — сгенерировать парный urltest-двойник `<tag>-auto` (набор = ноды
     канала по regex, **без** direct/auto) и добавить его опцией в селектор канала.
4. **Regex-фильтр нод** — одна regex по **итоговому tag ноды как он есть** (один-в-один
   с фильтром на главной §048: `n.tag.contains`, без bare/display-преобразований); в
   канал попадают только ноды, чей tag матчит. Пусто/невалидно → все ноды (текущее
   поведение).
5. **Default-regex** — одна regex; первая (по порядку) нода, чей тег матчит,
   становится `options.default`. Не матчит / пусто → default не выставляется
   (sing-box сам берёт первую опцию группы).

## Нецели

- **reject как опция селектора.** В шаблоне нет `block`/`reject`-outbound (reject
  существует только как `action` в правилах, [custom_rule.dart:259](../../../app/lib/models/custom_rule.dart#L259)).
  selector с членом-reject семантически не имеет смысла → не делаем.
- **Несколько regex** (allow-list из N штук). Одна regex на фильтр, одна на default.
- **Произвольный `type`-пикер** (selector/urltest вручную). Канал всегда `selector`;
  urltest появляется только как авто-сгенерированный двойник через галку auto.
- **Иконка/цвет канала**, drag-reorder каналов — отдельная тема.

---

## Модель данных (proposal)

Ключевая смена парадигмы: **каналы переезжают из template в storage**. Template
перестаёт быть source-of-truth для состава каналов — он становится **seed'ом**
(значения по умолчанию при первом запуске / для свежей установки). После первого
запуска каналы живут в `lxbox_settings.json` и редактируются юзером.

```dart
/// Пользовательский канал роутинга. Хранится в storage (channels[]).
/// На первом запуске seeded из template.presetGroups.
class Channel {
  final String tag;          // 'vpn-1'..'vpn-10' — АВТОГЕНЕРИРУЕМ системой,
                             // immutable, юзер НЕ редактирует (правит только label).
                             // Стабильный ключ ссылок: route_final / ping_options /
                             // custom-rule outbound / detour / autoTag.
  final String label;        // отображаемое имя ("Моя Германия") — единственное,
                             // что юзер вводит как «имя».
  final bool enabled;        // вкл/выкл (заменяет enabled_groups[]; vpn-1 всегда true)

  // selector
  final bool includeDirect;  // галка: direct-out опцией в селектор
  final String nodeFilter;   // regex по ИТОГОВОМУ tag ноды (§048-style n.tag.contains);
                             // '' → все ноды
  final String defaultFilter;// regex; первая matched нода → options.default; '' → нет
  final bool interruptExistConnections; // selector.interrupt_exist_connections (deflt true)

  // auto-двойник (urltest). null → галка ВЫКЛ, <tag>-auto не эмитится.
  final ChannelAuto? auto;

  String get autoTag => '$tag-auto';   // ПРОИЗВОДНЫЙ, в storage НЕ хранится.
  // ping остаётся в ping_options.groups[tag] — не дублируем.
}

/// Параметры urltest-двойника канала. tag НЕ хранится — производный (channel.autoTag).
class ChannelAuto {
  final String url;          // urltest test endpoint
  final String interval;     // duration ("5m")
  final int tolerance;       // ms, uint16 (§161 — вне диапазона роняет ядро)
  final String idleTimeout;  // duration ("30m")
  final bool interruptExistConnections; // urltest.interrupt_exist_connections (deflt false)
}
```

`tag` и `autoTag` — **производные/системные**: `tag` автогенерируется при создании
(первый свободный `vpn-N`, N∈1..10) и immutable; `autoTag = "${tag}-auto"` вычисляется,
в storage не лежит. Юзер вводит только `label`. immutable `tag` ⇒ ссылки стабильны
by design (нет переименования → нет рассинхрона).

`✨auto` (глобальный urltest) **уходит из модели каналов и из выборов** — он больше
не глобальный канал. Каждый selector-канал теперь делает свой встроенный auto-двойник
через `auto`. Любая существующая ссылка на `✨auto` (route_final / Home-pin /
custom-rule outbound) **деградирует на vpn-1** наравне с прочими dangling-ссылками
(см. «Удаление канала» ниже).

### Резолюция канала в outbound-группы (билдер)

Каждый **включённый** канал `C` эмитит:

```
nodesC = allNodeTags, отфильтрованные C.nodeFilter (regex по итоговому tag, §048-style)
         (C.nodeFilter == '' → nodesC = allNodeTags)

selector C.tag:
  outbounds = [ ...nodesC,
                (C.includeDirect ? 'direct-out' : —),
                (C.auto != null  ? C.autoTag   : —) ]   // '<tag>-auto'
  default   = первая нода из nodesC, чей tag матчит C.defaultFilter
              (если defaultFilter != '' и есть match) иначе default НЕ выставляется
  interrupt_exist_connections = C.interruptExistConnections

if C.auto != null → дополнительно эмитим:
  urltest C.autoTag:
    outbounds = nodesC        // ТОЛЬКО ноды канала, БЕЗ direct/auto
    url          = C.auto.url
    interval     = C.auto.interval
    tolerance    = C.auto.tolerance
    idle_timeout = C.auto.idleTimeout
    interrupt_exist_connections = C.auto.interruptExistConnections
```

Инвариант auto-двойника: `<tag>-auto` **никогда** не содержит `direct-out` или
другой auto в `outbounds` — чистый urltest по нодам канала, чтобы urltest не
«сваливался» в прямой доступ. У urltest нет поля `default` (он сам выбирает
быстрейший) — поэтому `default_filter` имеет смысл только для selector.

Граничный случай — `nodesC` пуст (regex не матчит ни одной ноды, или нет нод вообще):
- selector с пустым набором нод → fallback на `direct-out` (как сейчас в
  [build_config.dart:458-461](../../../app/lib/services/builder/build_config.dart#L458)),
  чтобы канал не был пустой группой (fatal в sing-box).
- auto-двойник с пустым `nodesC` → **не эмитим** (urltest без нод недопустим;
  как сейчас для `✨auto`, [build_config.dart:439](../../../app/lib/services/builder/build_config.dart#L439)).
  Тогда selector тоже не получает `<tag>-auto` опцией (двойника нет).

---

## UX (proposal)

Идиома проекта для редактирования сложных сущностей — **полноэкранный редактор**
по `Navigator.push(MaterialPageRoute)` с back-guard `PopScope` (как
[`custom_rule_edit_screen.dart`](../../../app/lib/screens/custom_rule_edit_screen.dart),
[`dns_server_edit_screen.dart`](../../../app/lib/screens/dns_server_edit_screen.dart)).

### Routing → таб Channels (сейчас)
```
┌─ Channels ─────────────────────────────┐
│ ▣ VPN ①   selector · vpn-1 · required  │   ← только тогл вкл/выкл
│ ☐ VPN ②   selector · vpn-2             │
│ ☐ VPN ③   selector · vpn-3             │
│ ☐ VPN ④   selector · vpn-4             │
│ ▣ Include Auto  urltest · ✨auto       │
└────────────────────────────────────────┘
```

### Routing → таб Channels (proposal)
Тогл слева; тап по телу тайла → редактор. Внизу — кнопка **＋ Add channel**
(disabled при 10 каналах). `✨auto` как отдельный канал убран из списка.
```
┌─ Channels ─────────────────────────────┐
│ ▣ Моя Германия   vpn-1 · 12 нод · auto ▸│   ← required, неудаляемый
│ ☐ Стриминг       vpn-2 · 4 ноды        ▸│
│ ☐ VPN ③          vpn-3 · all нод       ▸│
│ ☐ VPN ④          vpn-4 · all нод       ▸│
│ ─────────────────────────────────────── │
│        ＋  Add channel   (4/10)          │
└────────────────────────────────────────┘
```
Subtitle подсказывает count нод (после фильтра) и наличие auto-двойника.

### ChannelEditScreen (новый)
```
┌─ Edit channel · vpn-2 ───────── [🗑] [✓]─┐   🗑 = delete (нет для vpn-1), ✓ = save
│ vpn-2                          (read-only)│   ← tag показан, НЕ редактируется (системный)
│ Title         [ Стриминг              ] │   ← TextField, label — единственное «имя»
│                                          │
│ ▣ Include direct-out                     │   ← галка: direct опцией селектора
│ ▣ Interrupt connections on switch        │   ← selector.interrupt_exist_connections
│                                          │
│ Node filter (regex)                      │
│   [ 🇩🇪|🇳🇱                          ]   │   ← одна regex по итоговому tag; пусто = все
│   matched: 4 / 30 nodes          [test▸] │   ← live-превью count + список
│                                          │
│ Default (regex)                          │
│   [ Premium                          ]   │   ← первая matched нода → default
│   → "🇩🇪 Premium #1"                     │   ← live-превью какая нода выбрана
│                                          │
│ ▣ Include auto (urltest)                 │   ← наличие = auto != null → эмит <tag>-auto
│   ├ Test URL    [ …/generate_204      ]  │   ← раскрывается когда галка ВКЛ
│   ├ Interval    [ 5m                  ]  │
│   ├ Tolerance   [ 30 ] ms                │   ← uint16 (§161)
│   ├ Idle timeout[ 30m                 ]  │
│   └ ▣ Interrupt connections on switch    │   ← auto.interrupt_exist_connections
│                                          │
│ Ping (§008)         url / timeout      ▸ │   ← опц.: свернуть per-group ping сюда
└──────────────────────────────────────────┘
```
- **Delete** (🗑): подтверждение → удалить канал из `channels[]`. Скрыт для `vpn-1`.
  Любая ссылка на удалённый канал (route_final / Home-pin / custom-rule outbound /
  detour) **переводится на `vpn-1`** (см. «Удаление канала → vpn-1» ниже).
- **Add channel**: создаёт `Channel` с авто-tag (первый свободный `vpn-N`, N∈2..10 —
  система, не юзер), label = `VPN ⑤` (или просто tag), пустые фильтры, direct=off,
  auto=null (выкл), interrupt=true, enabled=true → сразу открывает редактор.
- **Back-guard**: при dirty — диалог Save / Keep editing / Discard.
- **Live-превью regex**: компилируем regex on-the-fly, показываем count и какие
  ноды матчатся (по текущему снимку нод подписки). Невалидная regex → ошибка
  в поле, не сохраняем.

### Home dropdown
Заодно чиним давний баг: dropdown канала на Home
([`home_controls.dart`](../../../app/lib/screens/home/widgets/home_controls.dart))
показывает `tag` («vpn-1»), а должен — `label`. После фичи юзер видит «Моя Германия».

---

## Storage (proposal)

Замена `enabled_groups[]` на полноценный `channels[]` в `lxbox_settings.json`
([STORAGE.md](../../STORAGE.md)). `tag` хранится как системный immutable-ключ
(автогенерируется, юзер не правит); `auto` — вложенный nullable-объект (null = галка
выкл); `auto.tag` НЕ хранится (производный `${tag}-auto`).

```jsonc
"channels": [
  {
    "tag": "vpn-1",                       // системный immutable id (не редактируется)
    "label": "Моя Германия",
    "enabled": true,
    "include_direct": true,
    "node_filter": "🇩🇪|🇳🇱",
    "default_filter": "Premium",
    "interrupt_exist_connections": true,  // selector
    "auto": {                             // null → галка auto ВЫКЛ
      "url": "https://cp.cloudflare.com/generate_204",
      "interval": "5m",
      "tolerance": 30,
      "idle_timeout": "30m",
      "interrupt_exist_connections": false
    }
  },
  {
    "tag": "vpn-2",
    "label": "Стриминг",
    "enabled": false,
    "include_direct": true,
    "node_filter": "",
    "default_filter": "",
    "interrupt_exist_connections": true,
    "auto": null
  }
]
```

Схема (нотация [STORAGE.md](../../STORAGE.md)):
```
├─ channels[]                            list     §125 — каналы роутинга (template→storage)
│   └─ <item>                            object
│       ├─ tag                           string   СИСТЕМНЫЙ immutable id 'vpn-1'..'vpn-10';
│       │                                          автоген, юзер НЕ правит; vpn-1 неудаляем
│       ├─ label                         string   отображаемое имя (юзер вводит)
│       ├─ enabled                       bool     вкл/выкл (vpn-1 всегда true)
│       ├─ include_direct                bool     direct-out опцией селектора
│       ├─ node_filter                   string   regex по итоговому tag ноды; '' = все
│       ├─ default_filter                string   regex; первая matched → default; '' = нет
│       ├─ interrupt_exist_connections   bool     selector.interrupt_exist_connections
│       └─ auto                          object?  null = галка ВЫКЛ; object = ВКЛ → urltest.
│                                                  tag двойника НЕ хранится (производный <tag>-auto)
│           ├─ url                       string   urltest test endpoint
│           ├─ interval                  string   duration ("5m")
│           ├─ tolerance                 int      ms, uint16 (§161)
│           ├─ idle_timeout              string   duration ("30m")
│           └─ interrupt_exist_connections  bool  urltest.interrupt_exist_connections
```

- **Миграция** (one-shot в `SettingsStorage`): если `channels` отсутствует —
  seed из template.presetGroups (vpn-1..vpn-N):
  - `enabled_groups[]` ∋ tag (или `default_enabled`) → `enabled`; vpn-1 форсим true.
  - `add_outbounds` ∋ `direct-out` → `include_direct`.
  - `add_outbounds` ∋ `✨auto` → `auto = {url/interval/tolerance из @urltest_* vars,
    idle_timeout="30m", interrupt_exist_connections=false}` (был глобальный auto в
    опциях → теперь свой двойник). Иначе `auto = null`.
  - `options.interrupt_exist_connections` → `interrupt_exist_connections` (template = true).
  - `options.default` → **не** мигрируется в `default_filter` (старый default — фикс. tag,
    не regex). После миграции `default_filter = ''` (см. Решение 6). `node_filter = ''`.
  - Глобальный `✨auto`-preset_group в channels **не** попадает (он не selector).
- API в `settings_storage/` (по образцу `network.dart` getGroupPing):
  `getChannels()`, `setChannels(List<Channel>)`, `addChannel()` (→ throws при 10),
  `updateChannel(Channel)`, `deleteChannel(tag)` (+ перевод dangling-ссылок на vpn-1).
- `enabled_groups[]` после миграции **депрекейтится** (читается только миграцией;
  на диске остаётся безвредным мусором — §159).

---

## Билдер (proposal)

[`build_config.dart`](../../../app/lib/services/builder/build_config.dart):
`_buildPresetGroups` переписывается с `presets: List<PresetGroup>` (из template) на
`channels: List<Channel>` (из storage). Ключевые изменения:

1. **Per-channel node-set.** Сейчас все selector делят общий `selectorTags`
   ([:433](../../../app/lib/services/builder/build_config.dart#L433)). Станет: для
   каждого канала фильтруем `selectorTags` по `channel.nodeFilter` (regex по
   **итоговому tag** ноды). Это снимает «один набор на всех» — самый нетривиальный кусок.
2. **direct/auto членство** — из `channel.includeDirect` / `channel.auto != null`,
   не из template `add_outbounds`.
3. **auto-двойник** — если `channel.auto != null` (и `nodesC` непуст), эмитим
   urltest-группу `channel.autoTag` (`<tag>-auto`) с `outbounds = nodesC` (без
   direct/auto). Параметры url/interval/tolerance/idle_timeout/interrupt_exist_connections
   берём из `channel.auto` (не из глобального template).
4. **default через regex** — `options.default` = первая нода из `nodesC`, чей
   **итоговый tag** матчит `channel.defaultFilter`. Существующая §141-валидация
   ([:470](../../../app/lib/services/builder/build_config.dart#L470)) остаётся
   как защита (default ∈ outbounds), но теперь default назначается нами, а не
   из template.
5. **interrupt_exist_connections** — selector и auto-двойник получают свои значения
   из `channel.interruptExistConnections` / `channel.auto.interruptExistConnections`
   (не из template).
6. **regex по итоговому tag.** Матчим regex по **финальному tag ноды как он есть**
   (member-tag в outbound-группе), один-в-один как §048 на главной (`n.tag.contains`).
   Без `TagResolver` bare/display-преобразований: что видно в имени — то и матчится
   (эмодзи-флаги, любой префикс — часть tag'а).

⚠ Per-channel outbounds — самый тяжёлый кусок: меняет фундаментальное допущение
билдера «все selector видят один набор нод».

---

## Снятие хардкодов (вне template → storage)

CRUD требует снять захардкоженные предположения о наборе каналов:

| Место | Сейчас | Станет |
|---|---|---|
| [`build_config.dart:421`](../../../app/lib/services/builder/build_config.dart#L421) | `if (p.tag == 'vpn-1') return true` (всегда активен) | vpn-1 всегда `enabled` инвариантом модели |
| [`node_filter_screen.dart:104`](../../../app/lib/screens/node_filter_screen.dart#L104) | `groupTags = {'vpn-1'..'vpn-4', ✨auto, direct-out}` хардкод | строить из `channels[].tag` динамически |
| [`routing_srs_cache.dart:40,42`](../../../app/lib/screens/routing_screen/routing_srs_cache.dart#L40) | `add('vpn-1')` required + `_routeFinal='vpn-1'` fallback | vpn-1 из channels (required-инвариант) |
| [`routing_group_tile.dart:26`](../../../app/lib/screens/routing_screen/widgets/routing_group_tile.dart#L26) | `isRequired = tag == 'vpn-1'` | оставить (vpn-1 неудаляем — продуктовое решение) |
| [`dns_settings_screen.dart:144`](../../../app/lib/screens/dns_settings_screen.dart#L144) | `add('vpn-1')` required | из channels |
| tag-генерация | — | первый свободный `vpn-N`, N∈2..10; лимит 10 |

`vpn-1` остаётся продуктово-привилегированным: всегда `enabled`, неудаляемый,
дефолт `route_final`. Это **намеренный** хардкод (продуктовое решение юзера),
не технический долг.

---

## Удаление канала → деградация ссылок на `vpn-1`

Решение юзера: **любая** ссылка на несуществующий канал (удалённый, либо legacy
`✨auto`) **всегда переводится на `vpn-1`**. `vpn-1` неудаляем → всегда валидная мишень.

Места, где может жить ссылка на канал-tag, и что делаем при удалении / на старте билда:
- `route_final` (`getRouteFinal`) — если ∉ существующих каналов → `vpn-1`.
- Home-pin / выбранный канал на главной (`home_state`) — → `vpn-1`.
- custom-rule `outbound` ([custom_rule.dart](../../../app/lib/models/custom_rule.dart),
  кроме `kOutboundReject`/`direct-out`) — → `vpn-1`.
- detour-ссылки на канал-tag — heal в `vpn-1` (паттерн уже есть для outbound'ов:
  [§172 heal-dangling-detour](../../tasks/172-heal-dangling-detour.md)).

Реализация: одна точка нормализации в билдере (резолвит набор валидных channel-tag'ов
и схлопывает все dangling-ссылки в `vpn-1` перед сборкой), плюс немедленная
правка storage в `deleteChannel(tag)` для UI-консистентности. `✨auto` после
удаления глобального auto-канала автоматически попадает под то же правило — отдельный
спец-кейс не нужен.

---

## Объём / фазовка (proposal)

| Фаза | Что | Риск |
|---|---|---|
| **F0 — Модель + storage** | `Channel` model, `channels[]` storage, миграция из `enabled_groups[]`, API | средний |
| **F1 — Title + галки** | редактор: label + include_direct + interrupt + auto-объект (url/interval/tolerance/idle/interrupt); билдер: членство из галок + эмит auto-двойника | средний (билдер) |
| **F2 — Regex node-filter** | per-channel node-set в билдере + live-превью в редакторе | **высокий** (ломает «общий набор нод») |
| **F3 — Default-regex** | default = первая matched нода + превью | низкий (поверх F2) |
| **F4 — CRUD** | Add/Delete + tag-генерация + лимит 10 + dangling-ref хэндлинг + снятие хардкодов | высокий (хардкоды по коду) |
| **Home-dropdown fix** | label вместо tag | низкий |

Рекомендация: F0 → F1 (виден результат, конфиг почти не трогаем) → F4 (CRUD на
галках, ещё без regex) → F2 → F3. Regex-фильтр (F2) последним — он самый рискованный
для билдера и его проще верифицировать, когда CRUD уже даёт каналы для теста.

---

## Связанные спеки

- [§048 home-node-filters](../048%20home-node-filters/spec.md) — текущий **глобальный**
  node-filter (`excluded_nodes`, ручные чекбоксы). **Остаётся** как песочница:
  юзер экспериментирует с набором нод глобально, а удачный результат портирует в
  per-channel regex. Per-channel regex его **не удаляет** — это независимые
  слои (глобальный экспериментальный + per-channel боевой).
- [§195 save-home-filter-to-channel](../../tasks/195-save-home-filter-to-channel.md) —
  мост песочница→канал: кнопка 💾 в regex-поле на главной сохраняет текущий regex
  в `node_filter`/`default_filter` активного канала (раньше — только вручную через
  редактор канала).
- [§008 ping and node management](../008%20ping%20and%20node%20management/spec.md) —
  per-group ping (`ping_options.groups[tag]`); образец per-channel storage и место,
  куда сворачивается ping-настройка в редакторе.
- [§184 add-vpn4-channel](../../tasks/184-add-vpn4-channel.md) — добавил vpn-4
  одной записью в template; показал что каналы динамичны. Эта фича переносит
  динамику из template в storage.
- [§141 deep-code-audit](../../tasks/141-deep-code-audit-hardening.md) — валидация
  `default ∈ outbounds`; остаётся как защита.
- [§122 commandclient-migration](../122%20commandclient-migration/spec.md) — `CcGroup`
  runtime-модель (UI читает реальный состав групп от ядра).

## Docs to update — [deferred till release]

При реализации обновить:
- `docs/STORAGE.md` — ключ `channels[]`, депрекейт `enabled_groups`.
- `docs/TEMPLATE.md` — `preset_groups[]` становится seed'ом, не source-of-truth.
- `docs/ARCHITECTURE.md` — data-flow билдера по нодам (F2 меняет «общий набор»).
- `CHANGELOG.md` — user-visible.

## Решения (бывшие open questions — закрыты юзером 27.06.2026)

1. **§048 глобальный фильтр — оставляем как песочницу.** Юзер экспериментирует с
   набором нод глобально (§048), удачный результат портирует в per-channel regex
   вручную. Per-channel regex его не вытесняет — независимые слои.
2. **Dangling reference при удалении → всегда `vpn-1`.** Любая ссылка на удалённый
   канал (route_final / Home-pin / custom-rule outbound / detour) деградирует на
   `vpn-1`. См. секцию «Удаление канала → деградация ссылок». Удаление не
   запрещается, не требует предупреждения о ссылках — просто перевод.
3. **`✨auto` больше не глобален и убран из выборов.** Каждый канал делает свой
   auto-двойник через галку. Существующие ссылки на `✨auto` деградируют на `vpn-1`
   по правилу из решения 2 (отдельный спец-кейс не нужен).
4. **Regex матчит итоговый tag как есть.** По финальному tag ноды один-в-один с
   фильтром §048 на главной (`n.tag.contains`), без bare/display-преобразований.
   Эмодзи-флаги и любой префикс — часть tag'а, по которому идёт match.
5. **Лимит каналов — 10**, vpn-1 неудаляем. *(Тех. детали, разумные дефолты —
   подтвердить в `plan.md`, не блокеры):* tag нового канала — первый свободный
   `vpn-N` (N∈2..10); при переиспользовании освободившегося tag'а его старые stale-
   ссылки и так схлопнутся в vpn-1 при удалении, так что переиспользование безопасно.
6. **Миграция template `default: ✨auto`.** *(Тех. деталь — `plan.md`):* поскольку
   глобального `✨auto` больше нет, при миграции vpn-1 `default_filter` оставляем
   пустым (юзер задаёт regex заново) ИЛИ, если у vpn-1 после миграции `auto != null`,
   default неявно укажет на собственный `vpn-1-auto`. Выбрать при реализации.

## Поля outbound selector/urltest (sing-box 1.14 — справка)

Зафиксировано из схемы ядра `v1.14.0-lx.1`, чтобы модель `Channel` ничего не упускала:
- **selector** — всего: `tag`, `outbounds[]` (обязат.), `default`, `interrupt_exist_connections`.
  Больше полей нет. Все четыре покрыты моделью.
- **urltest** (auto-двойник) — `tag`, `outbounds[]`, `url`, `interval`, `tolerance`,
  `idle_timeout`, `interrupt_exist_connections`. У urltest **нет** `default`. Все
  покрыты `ChannelAuto` (кроме `tag` — производный).
