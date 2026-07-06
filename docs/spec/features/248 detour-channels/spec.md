# §248 — Detour channels (канал как detour-прослойка)

> **СТАТУС: СПЕКА** (согласована 06.07.2026, вопросы Q1–Q4 решены с владельцем).
> Идея владельца: канал §125 с галкой «Use as detour» становится переключаемой
> detour-прослойкой для серверов/папок/подписок и исчезает из выбора целей
> правил. Ядро не трогаем.

## Зачем

1. Сейчас цель detour — конкретный узел (одиночка display-form или член папки
   голым тегом, `showDetourTargetPicker`). Смена upstream у флота из N серверов
   = N ручных правок Node Settings.
2. Канал уже компилируется в selector-outbound (§125,
   `_buildChannelGroups`), а `detour` в sing-box — ссылка на тег **любого**
   outbound'а, включая selector/urltest. То есть фича почти бесплатна:
   вся работа на стороне обвязки.
3. **Detour-канал = именованная точка перенаправления.** Переключил selected
   в канале (Home dropdown / kernel groups) — весь детурящийся через него флот
   мгновенно переехал на другой upstream. С auto-двойником (urltest) прослойка
   становится самонаводящейся. Папочная/подписочная `detour_policy` +
   detour-канал = «вся подписка через переключаемый relay» одной настройкой.

## Терминология (ЖЁСТКО)

- **Detour-канал** — канал §125 с флагом `detour`. В UI строка галки —
  **"Use as detour"**; маркер — префикс `⚙ ` (`kDetourTagPrefix`, та же
  семантика «узел-посредник», что у звеньев цепочек §234/§239).
- Роли канала в **применении** взаимоисключающие: обычный канал = цель правил
  (route_final / custom-rule outbound), detour-канал = цель detour. Механизмы
  состава (node_filter, invert, default, auto/urltest, include direct) — общие.

## Модель

`Channel.isDetour: bool`, JSON-ключ `detour`, default `false` (отсутствие
ключа в storage/backup читается как false — миграции нет).

Инварианты:

1. **`vpn-1` не может быть detour-каналом** — он резервная мишень всех
   heal-путей (`_healChannelRefs`, деградация route_final); detour-only vpn-1
   сломал бы деградацию. UI прячет галку, storage/API отклоняют.
2. **`detour` ⇒ `includeBlock == false`** (Q1: block в прослойке запрещён —
   «upstream недоступен» не должен превращаться в «весь флот мёртв»).
   UI скрывает и сбрасывает галку Include block; storage нормализует;
   API отклоняет явный конфликт (ниже).
3. **Состав не ограничен** (Q2): любые ноды, включая WG/AWG-endpoint'ы.
   `excludeWireguard`-гейт пикера (§130) на канальную секцию НЕ
   распространяется — осознанное решение, ответственность на пользователе.

## Билдер (`_buildChannelGroups`, build_config.dart)

Selector и auto-двойник эмитятся как у обычного канала, кроме:

- **block не эмитится никогда** — даже если в storage лежит legacy
  `include_block: true` (нормализация при сохранении может не успеть за
  restore из backup);
- **пустой node-set → fallback `["direct-out"]`, `default: direct-out`**
  (Q1). У обычного канала остаётся §201-поведение `[block, direct-out]`
  c default=block. Warning (self-contained, EN):
  `Detour channel "<label>" (<tag>): no nodes matched — detour falls back to direct (no hop).`
- **cycle-prune (ОБЯЗАТЕЛЬНЫЙ гейт).** Circular outbound dependency — это
  **fatal старта sing-box**, не мягкий dangling. Из node-set detour-канала C
  исключается каждый узел, из которого C достижим по detour-цепочке.
  - Граф: узел → его `detour`-тег (из уже собранных outbounds/endpoints —
    server lists строятся ДО каналов, детуры к этому моменту финальны);
    канал → его члены. Достижимость по каналам считаем на **непрунёных**
    member-set'ах — консервативно (можем исключить лишнее, но никогда не
    пропустим цикл) и детерминированно.
  - Прунится ОДИН набор на канал — его используют и selector, и
    auto-двойник (иначе twin разъедется с селектором).
  - Warning: `Detour channel "<label>" (<tag>): excluded N node(s) that route through this channel (loop): <tags>.`
  - Прунинг опустошил набор → fallback direct-out (пункт выше).
- **Деградация route_final**: detour-каналы исключаются из validFinals →
  fallback vpn-1 + существующий warning (симметрия с disabled/deleted).

Философия — §172/§121: деградировать с warning, не ронять конфиг.

## Пикеры

- `showDetourTargetPicker` (widgets/detour_target_picker.dart): новая секция
  **Channels** (каналы с `enabled && isDetour`), выше Standalone servers.
  Значение = `channel.tag` (стабильный `vpn-N` — переживает rename label,
  как все канальные ссылки). Отображение: `⚙ <label>`. Секция видна и при
  `excludeWireguard: true` (Q2). Автоматически появляется во всех трёх
  контекстах: Node Settings одиночки/члена (§237), настройки подписки и
  папки (`detour_policy.overrideDetour`).
- `_outboundOptions()` (routing_screen.dart) — detour-каналы пропускаются.
  Одна точка закрывает route final, тайлы правил, редактор правила и
  outbound-var пресетов. Кэш-инвалидация (§219) уже срабатывает на любую
  мутацию каналов.

## Ссылочная целостность (heal, Q3)

Правило (расширение Решения B §202): канал перестал быть валидной мишенью
данного рода → ссылки этого рода лечатся сразу в storage, **необратимо**.

| Событие | Rules-ссылки: route_final, custom-rule outbound (inline/srs), preset `varsValues['outbound']` | Detour-ссылки: `DetourPolicy.overrideDetour` (одиночка/подписка/папка), `FolderMember.detour` |
|---|---|---|
| `detour` false→true | → `vpn-1` (`_healChannelRefs`) | — |
| `detour` true→false | — | → `''` (None/direct), новый `_healDetourChannelRefs` |
| disable | → `vpn-1` (существующее §202) | → `''` (новое) |
| delete | → `vpn-1` (существующее) | → `''` (новое) |

- **Дыра preset-override — ЗАКРЫТА отдельной задачей, пункт снят из скоупа**
  (commit `bcf9414`, ветка `claude/sweet-germain-b47da9`, 06.07.2026):
  `_healChannelRefs` теперь kind-agnostic — матчит по общему getter'у
  `CustomRule.outbound` и лечит type-preserving `withOutbound`'ом, который
  для preset пишет `varsValues['outbound']`. Тесты — preset-кейсы в
  `channel_heal_refs_test.dart`. Колонка Rules-ссылок в таблице выше уже
  описывает итоговое (пофикшенное) поведение.
- Build-time страховка не меняется: `healDanglingDetours` (§172) как есть —
  тег detour-канала присутствует в config['outbounds'] к моменту post-step,
  ссылка валидна и не срезается. Новых fatal-проверок не добавляем
  (§247-стиль: advisory на UI, деградация на билде).

## UX

- **Редактор канала** (channel_edit_screen.dart): чекбокс "Use as detour"
  (блок сверху, рядом с Include direct-out / Include block). При включении:
  Include block скрывается и сбрасывается; Include direct-out остаётся —
  для прослойки это легитимная опция «без хопа». Для `vpn-1` галка не
  показывается.
- **Вкладка Channels**: тайл detour-канала получает префикс `⚙ ` перед label.
- **Home** (Q4): detour-канал НЕ прячем — управление им с главного экрана и
  есть смысл фичи. В `_channelLabels` (home_controller.dart) label получает
  префикс `⚙ `, чтобы в dropdown было видно: переключаешь прослойку, а не
  канал правил.
- Все видимые строки — английские, без номеров задач (постоянные правила).

## Debug API (§238-симметрия)

- `GET /channels`, `GET /channels/{tag}` — поле `detour` в JSON.
- `POST /channels`, `PATCH /channels/{tag}` — принимают `detour: bool`:
  - `vpn-1` + `detour: true` → 409 Conflict;
  - явный `include_block: true` в одном body с `detour: true`, либо на уже
    detour-канале → 422;
  - `detour: true` на канале с сохранённым `include_block: true` →
    include_block нормализуется в false (merge-философия §238);
  - heal-побочки те же, что в UI (задокументировать в reference).
- `docs/api/debug-api-reference.md` — обновить.

## Storage / Backup

- Новое поле живёт **внутри** существующего top-level ключа `channels` —
  §221 backup-симметрия не затрагивается (channels уже в allowlist и
  export-категории), инвариант-тест allowlist⊆export не требует правок.
- `docs/STORAGE.md` — дополнить схему канала полем `detour`.
- `wizard_template.json` не меняется (seed-каналы без флага, parse-default
  false) — vc-бамп не нужен.

## Краевые случаи

- **Каналы не ссылаются на каналы**: член detour-канала — всегда узел.
  Цикл возможен только через detour-поля узлов; cycle-prune покрывает и
  транзитивные цепочки (узел→узел→канал), и межканальные
  (узел→C2, член C2→…→C1).
- Контроллерный цикл-чек `setMemberDetour` работает только intra-folder;
  канальные циклы ловятся билдером. Advisory-подсветка потенциального цикла
  прямо в пикере — вне скоупа v1.
- `FolderDetourPlan` (§239) не меняется: канальная ссылка не матчит голые
  теги членов → проходит как внешняя; exempt/разрыв циклов папки и
  register-гейты (они про узлы) не затрагиваются.
- Узел с итоговым тегом вида `vpn-N` — существующая глобальная проблема
  уникальности тегов (дубль тега selector'а = ошибка sing-box уже сейчас),
  этой фичей не вводится и не решается.

## Файлы

| Слой | Файл | Изменение |
|---|---|---|
| model | `models/channel.dart` | `isDetour` + JSON `detour`, нормализация includeBlock, гейт vpn-1 |
| storage | `services/settings_storage/channels.dart` | `_healDetourChannelRefs` (4 вида detour-ссылок); heal при flag-set/unset/disable/delete; `_healChannelRefs` + preset varsValues |
| builder | `services/builder/build_config.dart` | `_buildChannelGroups`: block-гейт, direct-fallback пустого detour-канала, cycle-prune (нужен доступ к detour-полям собранных outbounds/endpoints); validFinals без detour-каналов |
| UI | `screens/channel_edit_screen.dart` | чекбокс Use as detour, скрытие Include block |
| UI | `screens/routing_screen.dart` + `widgets/routing_group_tile.dart` | `_outboundOptions()` пропускает detour-каналы; ⚙ на тайле |
| UI | `widgets/detour_target_picker.dart` | секция Channels |
| UI | `controllers/home_controller.dart` | ⚙ в `_channelLabels` |
| debug | `services/debug/handlers/channels.dart` | поле `detour`, Conflict/422, нормализация |
| docs | `STORAGE.md`, `api/debug-api-reference.md`, `spec/features/README.md` | схема, API, индекс |
| тесты | `test/…` | см. ниже |

## Тесты

- **Builder**: block не эмитится при legacy include_block=true; пустой
  detour-канал → `[direct-out]` default=direct-out + warning (обычный канал —
  прежний §201); прямой цикл (S.detour=C, filter C матчит S) → S исключён +
  warning; транзитивный через цепочку узлов; межканальный через C2;
  auto-двойник использует прунёный набор; прунинг в ноль → direct-fallback;
  route_final на detour-канал → vpn-1.
- **Storage/heal**: flag-set лечит route_final + inline + srs + preset
  varsValues → vpn-1; flag-unset чистит overrideDetour одиночки/подписки/папки
  и FolderMember.detour → `''`; disable и delete detour-канала — то же;
  повторное включение НЕ воскрешает ссылки (Решение B).
- **UI-опции**: `_outboundOptions()` без detour-каналов; пикер detour
  содержит канальную секцию (и при excludeWireguard).
- **Debug API**: roundtrip `detour`; vpn-1 → 409; include_block-конфликт →
  422; нормализация include_block при detour=true.
- **Backup**: roundtrip канала с `detour` (поле переживает export→restore).

## Критерий готовности (сценарий)

Канал `vpn-2` «Relay»: node_filter по релейным нодам, галки detour + auto →
подписка X с `detour_policy.overrideDetour = vpn-2` → все ноды X ходят через
выбранный в vpn-2 relay; переключение vpn-2 на Home мгновенно пересаживает
весь флот; auto-режим самонаводится по urltest; vpn-2 отсутствует в выборе
целей правил и route final; снятие галки detour чистит overrideDetour
подписки (None/direct) без падения конфига.

## Что НЕ делаем

- Канал в составе канала (прослойки содержат только узлы).
- Ограничения состава по типу нод (Q2 — «может быть любым»).
- Advisory-детект цикла в момент выбора в пикере (билдер прунит; v2 по жалобам).
- Отдельный лимит на detour-каналы — общий `kMaxChannels = 10`.
- Изменения ядра/шаблона — не требуются.

## Связанные

- §125 configurable channels (базовая механика каналов).
- §018 detour server management, §237 member Node Settings, §239 folder detour
  symmetry (существующая detour-механика и пикер).
- §172 heal dangling detours, §202 heal при disable (Решение B), §201 пустой
  канал, §219 кэш опций.
- §221 backup-симметрия (не затронута), §238 Debug API /channels.
- §130 excludeWireguard-гейт пикера (осознанно не распространён на каналы).
