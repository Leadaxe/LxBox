# §248 — Detour channels (канал как detour-прослойка)

> **СТАТУС: РЕАЛИЗОВАНО, device-verified** (06.07.2026, CPH2411). Согласована с
> владельцем (Q1–Q4), прошла адверсарную ревизию спеки (циклы через
> auto-двойник, exempt-семантика разрыва, омонимия тегов, restore-обходы) и
> адверсарное ревью реализации (блокер: heal обязан зеркалиться в in-memory
> `_entries` контроллера — см. Heal). Тесты: builder
> `detour_channel_gates_test.dart`, storage `detour_channel_heal_test.dart`,
> модель `channel_detour_test.dart` + Debug API/backup/ресинк-кейсы.
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
   сломал бы деградацию.
2. **`detour` ⇒ `includeBlock == false`** (Q1: block в прослойке запрещён —
   «upstream недоступен» не должен превращаться в «весь флот мёртв»).
3. **Точка принуждения инвариантов 1–2 — parse (`Channel.fromJson`)**:
   `tag == 'vpn-1'` коэрсит `detour → false`; `detour == true` коэрсит
   `includeBlock → false`. Restore из backup и ручная правка файла пишут raw
   JSON мимо UI/storage/API (`_replaceRaw`) — только read-time нормализация
   закрывает все пути. UI дополнительно прячет галки (block — при detour,
   detour — у vpn-1), Debug API отклоняет явные конфликты (ниже).
4. **Состав не ограничен** (Q2): любые ноды, включая WG/AWG-endpoint'ы.
   Известный риск AWG→WG прикрыт advisory-warning'ом билдера (см. Билдер),
   не запретом.

## Билдер (`_buildChannelGroups`, build_config.dart)

Selector и auto-двойник эмитятся как у обычного канала, кроме:

- **block не эмитится никогда** у detour-канала (parse-нормализация п.3
  делает `include_block: true` недостижимым; билдер-гейт —
  defense-in-depth);
- **пустой node-set → fallback `["direct-out"]`, `default: direct-out`**
  (Q1). У обычного канала остаётся §201-поведение `[block, direct-out]`
  c default=block. Warning (self-contained, EN):
  `Detour channel "<label>" (<tag>): no nodes matched — detour falls back to direct (no hop).`

### Разрыв detour-циклов (ОБЯЗАТЕЛЬНЫЙ гейт, для ВСЕХ каналов)

Circular outbound dependency — **fatal старта sing-box**, не мягкий dangling.
Цикл возникает, когда узел n входит в node-set канала C, а detour-цепочка n
достигает C.

- **Семантика разрыва — edge-strip (exempt, как §239), НЕ исключение из
  node-set**: n остаётся в C, но эмитится без цикл-образующего detour —
  билдер снимает поле `detour` с уже собранного outbound/endpoint
  (build-output-only, storage не трогается — как разрыв циклов
  `FolderDetourPlan`). Почему не исключение: типовой кейс — relay-ноды живут
  в ТОЙ ЖЕ подписке, на которую повешен `overrideDetour = C` (override
  применяется ко всем членам, включая сами relay'и) → исключение опустошило
  бы C и превратило фичу в no-op; edge-strip даёт «флот → C → relay
  (напрямую)» — ровно намерение пользователя.
- **Граф достижимости**: узел → его detour-тег; **тег канала и тег его
  auto-двойника `<tag>-auto` — алиасы одной вершины-канала** (двойник
  содержит те же ноды — ссылка на него образует тот же цикл); канал → его
  члены. Значение detour, равное bare-тегу члена той же папки, резолвится в
  члена (зеркало приоритета `FolderDetourPlan`, см. Омонимия).
- Гейт применяется ко **всем** эмитируемым каналам, не только detour-flagged:
  detour-ссылка на обычный канал (Debug API — root by design; правленный
  backup) даёт тот же fatal — деградируем одинаково.
- Каналы обрабатываются в порядке эмиссии, после каждого снятия граф
  обновляется (межканальные циклы не пере-рвутся лишний раз);
  детерминированность обязательна, минимальность снятий — best-effort.
- Селектор и auto-двойник канала используют один и тот же member-set —
  не разъезжаются.
- Warning: `Channel "<label>" (<tag>): removed detour from N node(s) to break a routing loop (they connect directly): <tags>.`

### Прочие билдер-гейты

- **Деградация route_final**: из validFinals исключаются тег detour-канала
  **и его `<tag>-auto`** (validFinals собирается из всех presetOutbounds —
  двойник туда попадает) → fallback vpn-1. Отдельный warning — существующий
  «no longer exists» здесь ложен (канал существует):
  `Route final "<tag>" is a detour channel and cannot be a rule target — switched to vpn-1.`
- **AWG→WG advisory** (Q2-риск): если узел AmneziaWG детурится через канал,
  чей node-set содержит WireGuard-ноды, — эмитится warning (известный кейс
  «AWG с detour на wireguard вешает ядро на Android»; прямую ссылку §130-гейт
  пикера прячет, канальная её обходит — предупреждаем, не запрещаем):
  `Node "<tag>" (AmneziaWG) detours via channel "<label>" which contains WireGuard node(s) — this can hang the tunnel on Android.`

Философия — §172/§121: деградировать с warning, не ронять конфиг.

## Пикеры

- `showDetourTargetPicker` (widgets/detour_target_picker.dart): новая секция
  **Channels** (каналы с `enabled && isDetour`), выше Standalone servers.
  Значение = `channel.tag` (стабильный `vpn-N` — переживает rename label,
  как все канальные ссылки). Отображение: `⚙ <label>`. Секция видна и при
  `excludeWireguard: true` — состав канала не ограничен (Q2), риск прикрыт
  билдер-advisory (выше). Автоматически появляется во всех трёх контекстах:
  Node Settings одиночки/члена (§237), настройки подписки и папки
  (`detour_policy.overrideDetour`).
- **Отображение сохранённого значения**: в Node Settings / настройках
  подписки и папки уже выбранный канальный detour рендерится как
  `⚙ <label>` (lookup tag→label по каналам; канал не найден → сырой тег).
- `_outboundOptions()` (routing_screen.dart) — detour-каналы пропускаются.
  Одна точка закрывает route final, тайлы правил, редактор правила и
  outbound-var пресетов. Кэш-инвалидация (§219) уже срабатывает на любую
  мутацию каналов.

### Омонимия канальных тегов и bare-тегов членов

Тег канала (`vpn-N`) и bare-тег члена папки живут в одном строковом
пространстве `FolderMember.detour`. Правила (обратная совместимость — интра
побеждает):

- Резолюция НЕ меняется: значение, равное bare-тегу члена той же папки, —
  интра-ссылка на члена (существующий приоритет `bareIndex` в
  `FolderDetourPlan`), даже если существует одноимённый канал.
- Пикер в контексте папки (member и folder-настройки): канал, чей tag
  совпадает с bare-тегом члена этой папки, в секции Channels **скрывается**
  (однозначно закодировать выбор невозможно).
- Heal detour-ссылок (ниже) пропускает значения, матчащие bare-тег члена той
  же папки, — это интра-ссылки, канал тут ни при чём.
- Пикер и heal сверяются по ВСЕМ распарсенным членам, **включая
  выключенных** (консервативный superset: toggle члена-тёзки не должен
  молча менять смысл сохранённой ссылки), тогда как `bareIndex` билдера
  строится только по enabled-членам. Остаточная деградация осознанна:
  ссылка-тёзка при ВЫКЛЮЧЕННОМ члене резолвится билдером как канальная
  (детурит через канал, пока тёзка выключен) и переживает heal — добивается
  билдер-гейтами (edge-strip/§172) без падения конфига.

## Ссылочная целостность (heal, Q3)

Правило (расширение Решения B §202): канал перестал быть валидной мишенью
данного рода → ссылки этого рода лечатся сразу в storage, **необратимо**.
Ссылка «на канал» = его тег ИЛИ тег его auto-двойника `<tag>-auto`
(UI-пикеры двойник не предлагают, но Debug API / правленный backup могут
записать что угодно).

| Событие | Rules-ссылки: route_final, custom-rule outbound (inline/srs/preset `varsValues['outbound']`) | Detour-ссылки: `DetourPolicy.overrideDetour` (одиночка/подписка/папка), `FolderMember.detour` |
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
- В рамках фичи `_healChannelRefs` дополнительно учится матчить autoTag
  (`route_final == '<tag>-auto'` — возможен только через restore/API,
  но heal обязан быть симметричен validFinals-гейту).
- `_healDetourChannelRefs` пропускает интра-омонимы (см. Омонимия).
- **Зеркальный ресинк контроллера (ОБЯЗАТЕЛЕН)**: storage-heal сам по себе
  фикция — владелец server_lists в рантайме — in-memory
  `SubscriptionController._entries` (грузится один раз в init), от него идут
  и `generateConfig()`, и каждый `_persist()` (rename/toggle/авто-refresh),
  который воскресил бы вылеченную ссылку на диске. Общее ядро сброса —
  `clearDetourChannelRefs` (server_list.dart); storage-heal и
  `SubscriptionController.syncDetourChannelRefsCleared(tag)` зеркальны.
  Все вызыватели `updateChannel`/`deleteChannel` при `healed.detours > 0`
  обязаны звать ресинк (routing_screen `_resyncHealedRefs`, node_list,
  Debug-handler через `ctx.registry.sub`).
- **Обратная связь (Q3: heal «с warning»)**: heal молчаливым не бывает —
  UI показывает SnackBar со счётчиками, self-contained EN. Фактическая
  матрица (реализация покрывает больше кейсов, чем черновые два текста:
  disable/delete лечат ОБА рода):
  - вводная по событию: `Channel "<label>" disabled` / `… deleted` /
    `… is now a detour channel` (rules > 0), `Channel "<label>" is no longer
    a detour target` (только detours);
  - части счётчиков: `N rule reference(s) switched to vpn-1`,
    `M detour reference(s) reset to None` — оба ненулевые склеиваются в один
    SnackBar через запятую;
  - Home-путь редактора: префикс `Saved channel "<label>" — <части через ;>`.
  Мутация через Debug API — счётчики healed-ссылок в теле ответа
  (паттерн «снапшот в ответе» §238).
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
  - `vpn-1` + `detour: true` → **409 Conflict** (в контракте Debug API нет
    422 — sealed-иерархия errors.dart; паттерн vpn-1-инвариантов);
  - явный `include_block: true` вместе с `detour: true` в одном body, либо
    на уже detour-канале → **409 Conflict**;
  - `detour: true` на канале с сохранённым `include_block: true` →
    include_block нормализуется в false (merge-философия §238);
  - heal-побочки те же, что в UI; счётчики healed-ссылок — в теле ответа.
- `docs/api/debug-api-reference.md` — обновить.

## Storage / Backup

- Новое поле живёт **внутри** существующего top-level ключа `channels` —
  §221 backup-симметрия не затрагивается (channels уже в allowlist и
  export-категории), инвариант-тест allowlist⊆export не требует правок.
- **Restore не ре-гоняет heal'ы** (raw-запись по allowlist). Принятые
  деградации, фиксируем осознанно:
  - восстановленная rules-ссылка на detour-канал РАБОТАЕТ через прослойку
    (селектор существует, конфиг валиден; route_final прикрыт
    validFinals-гейтом, custom-rule outbound — нет). Лечится при следующей
    мутации этого канала; пикер правила показывает визуальный fallback §219;
  - восстановленная detour-ссылка на выключенный/удалённый канал деградирует
    билдером (§172: селектор не эмитится → dangling → срезана с warning) и
    остаётся видимой в Node Settings до правки.
  - Инварианты модели (vpn-1, include_block) restore НЕ обходит —
    parse-гейт (Модель, п.3).
- `docs/STORAGE.md` — дополнить схему канала полем `detour`.
- `wizard_template.json` не меняется (seed-каналы без флага, parse-default
  false) — vc-бамп не нужен.

## Краевые случаи

- **Каналы не ссылаются на каналы**: член detour-канала — всегда узел.
  Цикл возможен только через detour-поля узлов; edge-strip покрывает и
  транзитивные цепочки (узел→узел→канал), и межканальные
  (узел→C2, член C2→…→C1), и ссылки на auto-двойники.
- Контроллерный цикл-чек `setMemberDetour` работает только intra-folder;
  канальные циклы ловятся билдером. Advisory-подсветка потенциального цикла
  прямо в пикере — вне скоупа v1.
- `FolderDetourPlan` (§239): exempt/разрыв интра-циклов и register-гейты
  (они про узлы) не меняются; канальная ссылка проходит как внешняя, КРОМЕ
  омонимии с bare-тегом члена (см. Омонимия — интра побеждает, пикер
  коллизию не создаёт).
- AWG-узел → detour-канал с WG-нодами: не запрещаем (Q2), билдер эмитит
  advisory (см. Билдер). Прямые AWG→WG ссылки §130-гейт пикера прячет
  как и раньше.

## Файлы

| Слой | Файл | Изменение |
|---|---|---|
| model | `models/channel.dart` | `isDetour` + JSON `detour`; parse-гейт fromJson (vpn-1 → detour=false, detour → includeBlock=false) |
| model | `models/server_list.dart` | `clearDetourChannelRefs` — общее ядро сброса detour-ссылок (storage-heal + контроллерный ресинк) |
| controller | `controllers/subscription_controller.dart` | `syncDetourChannelRefsCleared` — зеркальный ресинк in-memory `_entries` после storage-heal |
| storage | `services/settings_storage/channels.dart` | `_healDetourChannelRefs` (4 вида detour-ссылок, tag+autoTag, пропуск интра-омонимов); heal при flag-set/unset/disable/delete; `_healChannelRefs` + autoTag; healed-счётчики наружу |
| builder | `services/builder/build_config.dart` | `_buildChannelGroups`: block-гейт, direct-fallback пустого detour-канала, edge-strip циклов для всех каналов (доступ к detour-полям собранных outbounds/endpoints и составам папок), AWG→WG advisory; validFinals без detour-канала и его autoTag + отдельный warning |
| UI | `screens/channel_edit_screen.dart` | чекбокс Use as detour, скрытие Include block, скрытие для vpn-1; SnackBar heal-уведомлений при flag-set/unset |
| UI | `screens/routing_screen.dart` + `screens/routing_screen/widgets/routing_group_tile.dart` (класс `RoutingChannelTile`) | `_outboundOptions()` пропускает detour-каналы; ⚙ на тайле; SnackBar heal-уведомлений при disable/delete |
| UI | `widgets/detour_target_picker.dart` | секция Channels; скрытие омонимов в контексте папки |
| UI | `screens/node_settings_screen.dart`, `subscription_detail_screen/widgets/subscription_settings_tab.dart` | рендер сохранённого канального значения как `⚙ <label>` |
| UI | `controllers/home_controller.dart` | ⚙ в `_channelLabels` |
| debug | `services/debug/handlers/channels.dart` | поле `detour`, 409-отказы, нормализация include_block, healed-счётчики в ответе, ресинк контроллера |
| debug | `services/debug/handlers/help.dart` | self-doc: поле detour, 409-инварианты, healed-счётчики, сброс detour-ссылок |
| docs | `STORAGE.md`, `api/debug-api-reference.md`, `spec/features/README.md` | схема, API, индекс |
| тесты | `test/…` | см. ниже |

## Тесты

- **Builder / циклы**: прямой цикл (S ∈ C, S.detour=C) → detour у S снят,
  S ОСТАЛСЯ в C, warning; цикл через auto-двойник (S.detour=`<tag>-auto`) —
  то же; транзитивный через цепочку узлов; межканальный через C2; цикл со
  ссылкой на ОБЫЧНЫЙ канал (Debug API-сценарий) — рвётся так же;
  флагман-кейс «relay в той же подписке под overrideDetour=C» → relay без
  detour, остальные едут через C; селектор и двойник согласованы;
  омонимия в `FolderDetourPlan`: member.detour = тег канала-тёзки →
  интра-ребро на члена (существующее поведение, regression-страховка).
- **Builder / гейты**: block не эмитится у detour-канала; пустой detour-канал
  → `[direct-out]` default=direct-out + warning (обычный канал — прежний
  §201); route_final на detour-канал И на его `<tag>-auto` → vpn-1 +
  новый warning-текст; AWG→канал с WG-нодой → advisory.
- **Model/parse**: fromJson коэрсит vpn-1+detour → false и
  detour+include_block → block=false (путь restore из правленного backup).
- **Storage/heal**: flag-set лечит route_final (tag и autoTag) + custom-rule
  outbounds (inline/srs/preset — kind-agnostic путь из `bcf9414`) → vpn-1;
  flag-unset чистит overrideDetour одиночки/подписки/папки и
  FolderMember.detour (tag и autoTag) → `''`; disable и delete detour-канала
  — то же; heal НЕ трогает интра-омоним (член папки с bare-тегом = тегу
  канала); повторное включение НЕ воскрешает ссылки (Решение B);
  healed-счётчики возвращаются.
- **UI-опции**: `_outboundOptions()` без detour-каналов; пикер detour
  содержит канальную секцию (и при excludeWireguard); омоним-канал скрыт в
  контексте папки с членом-тёзкой.
- **Debug API**: roundtrip `detour`; vpn-1 → 409; include_block-конфликт →
  409; нормализация include_block при detour=true; healed-счётчики в ответе.
- **Backup**: roundtrip канала с `detour`; restore с rules-ссылкой на
  detour-канал не роняет билд (принятая деградация).

## Критерий готовности (сценарий)

Канал `vpn-2` «Relay»: node_filter по релейным нодам, галки detour + auto →
подписка X с `detour_policy.overrideDetour = vpn-2`, **relay-ноды внутри той
же X** → relay'и едут напрямую (edge-strip), остальной флот — через
выбранный в vpn-2 relay; переключение vpn-2 на Home мгновенно пересаживает
флот; auto-режим самонаводится по urltest; vpn-2 отсутствует в выборе целей
правил и route final; снятие галки detour чистит overrideDetour подписки
(None/direct) с уведомлением о числе сброшенных ссылок и без падения конфига.

## Что НЕ делаем

- Канал в составе канала (прослойки содержат только узлы).
- Ограничения состава по типу нод (Q2 — «может быть любым»; AWG→WG — только
  advisory).
- Advisory-детект цикла в момент выбора в пикере (билдер рвёт; v2 по жалобам).
- Отдельный лимит на detour-каналы — общий `kMaxChannels = 10`.
- Heal-проход по ссылкам при restore из backup (принятые деградации — см.
  Storage / Backup).
- Изменения ядра/шаблона — не требуются.

## Связанные

- §125 configurable channels (базовая механика каналов).
- §018 detour server management, §237 member Node Settings, §239 folder detour
  symmetry (существующая detour-механика, пикер, exempt-прецедент).
- §172 heal dangling detours, §202 heal при disable (Решение B), §201 пустой
  канал, §219 кэш опций.
- §221 backup-симметрия (не затронута), §238 Debug API /channels.
- §130 excludeWireguard-гейт пикера (канальная секция его осознанно обходит,
  прикрыто билдер-advisory).
