# 274 — detour-канал: роль → разрешение (канал снова доступен целям правил)

| Поле | Значение |
|------|----------|
| Статус | РЕЛИЗ v2.15.6 (2026-07-15); device-verified на CPH2411 (сборка 2.15.5-dev.5) |
| Дата старта | 2026-07-15 |
| Дата завершения | 2026-07-15 |
| Коммиты | develop, 15.07.2026 (один атомарный коммит кода+тестов+доков) |
| Связанные spec'ы | features/248 (detour-каналы — базовая семантика, частично отменяется), tasks/254 (fatal-детектор циклов — становится единственным замком), features/125 (модель каналов), features/201-контекст (§201 block-first fallback), tasks/238 (Debug API /channels) |

## Проблема

Пользователь: «Если я разрешаю использовать канал как detour, то он перестаёт
быть доступен в выборе для правил — это ошибка логики (хотя UI явно это
говорит)».

§248 ввёл взаимоисключение ролей: обычный канал = цель правил, detour-канал =
цель detour. Технически ограничение искусственное — канал в собранном конфиге
это просто selector-outbound, ядру всё равно, кто на него ссылается (правило
или detour-поле ноды). Взаимоисключение служило дешёвой профилактикой
detour-циклов, но §254 дал честный fatal-детектор с минимальным набором
виновников — страховка пережила настоящий замок.

Дополнительные свидетельства неполноты старой доктрины:

- DNS-пикер (`dns_settings_screen.dart:146`) никогда не фильтровал по
  `isDetour` — detour-канал и так выбирался как DNS-detour в обход
  «взаимоисключения».
- Комментарий «единственная точка» над `outboundOptions` был неточен по той
  же причине.

Связанный запрет «detour × includeBlock» (§248 Q1) — та же категория:
решение за пользователя, снимается вместе с ролью.

## Решение (согласовано с владельцем 15.07.2026)

1. **`isDetour` = разрешение**, не роль: «канал можно выбирать как
   detour-мишень» (пикер §239). Доступность канала целям правил (route_final /
   custom-rule outbound) — ортогональна и не зависит от флага.
2. **vpn-1 остаётся без detour-галки** (UI-гейт, парс-коэрция, 409 в Debug
   API). Обоснование переформулируется: продуктовое решение — главный канал
   является дефолтной мишенью всего и heal-резервом; detour в него тривиально
   замыкает циклы.
3. **detour × includeBlock разрешены полностью** — без предупреждений,
   попапов и валидаторов. Снимаются все три входа: парс-гейт, UI-редактор,
   Debug API (409 + dropBlock-нормализация).
4. **flagSet-heal отключается**: установка галки больше не переписывает
   rules-ссылки на vpn-1. flagUnset/disable/delete-heal сохраняются (снятая
   галка убирает канал из пикера §239 → detour-ссылки → '').
5. **Циклы — только §254**: детектор структурный (detour-рёбра + группа→член),
   route_final/правила рёбер не создают, новых классов циклов разрешение не
   открывает. Правок в детекторе нет.
6. **Fallback пустого канала унифицируется**: `[block, direct-out]` с
   `default=block` для ВСЕХ каналов (отмена §248 Q1-fallback `[direct]` у
   detour). Warning-текст один и честный. Плюс новое исчезающее уведомление
   снизу (SnackBar на Home по паттерну §166): канал не нашёл узлов —
   проверьте фильтр.
7. **⚙ живёт в самом label (storage)** — как ⚙-метка в тегах detour-серверов
   §080/§090 (решение владельца: «как в отметках серверов — просто
   переименовывать»). Смена флага переименовывает канал:
   `Channel.normalizeLabel` в `copyWith` (редактор, Debug API, storage) и
   `fromJson` (restore/ручная правка) — set → `⚙ <label>`, unset → префикс
   срезается; юзер стёр ⚙ при включённой галке → нормализация вернёт
   (маркер зарезервирован). Пустой label не трогается. `displayLabel`
   (label-или-tag + страховочный префикс с дедупом) остаётся единой точкой
   display-имени — покрывает пустой label и объекты, созданные прямым
   конструктором мимо нормализации. Пять ручных подстановок
   `kDetourTagPrefix` переходят на него; новые места (пикеры правил,
   DNS-пикер) получают маркер автоматически.

## Карта изменений

### Модель — `app/lib/models/channel.dart`

| Строки | Было | Стало |
|---|---|---|
| 254-259 | doc: «исключён из целей правил… инварианты (vpn-1, detour⇒includeBlock=false)» | doc: «разрешение выбирать как detour-мишень; роль в правилах ортогональна; инвариант один — vpn-1 не detour» |
| 305-308, 315 | `includeBlock: !isDetour && (…)` (парс-гейт Q1) | `includeBlock: (…)` — гейт снят |
| новое | — | `static normalizeLabel(label, isDetour)` — переименование при смене флага; применяется в `copyWith` и `fromJson` |
| новое | — | `String get displayLabel`: `label.isNotEmpty ? label : tag`, с `kDetourTagPrefix` при `isDetour` (дедуп по `startsWith`) — страховка для пустого label / прямого конструктора |

vpn-1-коэрция `detour` (309) — не трогается.

### Пикеры правил — `app/lib/screens/routing_screen/routing_screen_helpers.dart`

| Строки | Было | Стало |
|---|---|---|
| 39-45 | doc: «detour-канал не цель правил… роли взаимоисключающие» | doc переписан: все enabled-каналы — опции; ⚙ в label по флагу |
| 51 | `if (c.isDetour) continue;` | строка удалена |
| 53-54 | `label: c.label.isNotEmpty ? c.label : c.tag` | `label: c.displayLabel` |

Одна точка накрывает route final, тайлы правил, редактор правила, preset
outbound-var, Action & Resolve (routing_screen.dart:459/511/700/726 —
без правок).

### Редактор канала — `app/lib/screens/channel_edit_screen.dart`

| Строки | Было | Стало |
|---|---|---|
| 340-344 | коммент «block в прослойке запрещён…» | переписан |
| 353-356 | subtitle «detour target for servers and folders — removed from rule targets» | `'can be picked as a detour target for servers and folders'` |
| 360 | `if (_isDetour) _includeBlock = false;` | удалено |
| 363 | `if (!_isDetour)` скрывает Include block | галка видна всегда |

Гейт видимости detour-галки `if (!c.isRequired)` (345) — остаётся.

### Storage — `app/lib/services/settings_storage/channels.dart`

| Строки | Было | Стало |
|---|---|---|
| 13-15, 61-65 | комменты heal-матрицы с flag-set | rules-heal только disable/delete |
| 69 | `final flagSet = …` | удалено (иначе unused-warning, CI analyze — весь проект) |
| 73-75 | `if (disabling \|\| flagSet \|\| flagUnset)` / `if (disabling \|\| flagSet) rules = …` | `if (disabling \|\| flagUnset)` / `if (disabling) rules = …` |
| 101-108 | doc `_healChannelRefs`: «…ИЛИ стал detour-прослойкой (§248 flag-set)… симметрия с validFinals-гейтом» | сужен до удалён/выключен; упоминание validFinals-гейта убрано (гейт снесён) |

`_healChannelRefs` и `_healDetourChannelRefs` сами по себе остаются.

### Билдер — `app/lib/services/builder/build_config.dart`

| Строки | Было | Стало |
|---|---|---|
| 384-405 | `detourChannelTags` + `..removeAll(…)` + detour-ветка warning route_final | блок снят; остаётся §219-механика validFinals из фактических presetOutbounds и warning «no longer exists» |
| 600-602 | `if (c.includeBlock && !c.isDetour)` | `if (c.includeBlock)` |
| 605-617 | fallback ветвится: detour → `[direct]`, обычный → `[block, direct]` | всегда `[kBlockOutboundTag, kDirectOutboundTag]` |
| 618-628 | warning раздвоен (detour: «falls back to direct») | один текст: `'Channel "X" (tag): node filter matched no nodes — traffic is blocked (default). Check its node filter.'` |
| 636-638 | `selector['default'] = c.isDetour ? direct : block` | всегда `kBlockOutboundTag` |

Сопутствующие расчёты (выключенный detour-канал как route_final после сноса
блока идёт обычным путём «no longer exists → vpn-1») — поведение
консистентно, отдельных правок нет. `healDanglingDetours` (§172),
AWG-advisory, §254-валидатор — не трогаются.

Комбинация include-галок × 0 нод (emptyFallback НЕ срабатывает — список
непуст, default не ставится, ядро берёт ПЕРВУЮ опцию): при
`include_direct=true` первой стоит `direct-out` → трафик идёт мимо VPN —
это осознанный выбор юзера (галка), но warning обязан говорить правду.
Поэтому текст warning вычисляется по фактическому исходу (адверсарное
ревью, finding: старый единый текст «blocked (default)» врал для этого
входа): `traffic is blocked (default)` при effective=block /
`traffic goes direct (no VPN hop)` при effective=direct-out.

### Исчезающее уведомление «канал без узлов» (новый механизм)

Сегодня `emitWarnings` уходят только в `AppLog`
(subscription_controller.dart:1399) — в UI ничего (тот же паттерн-дефект,
что чинил §254).

- `BuildResult` получает поле `channelsWithoutNodes: List<String>`
  (display-имена каналов, у которых непустой node_filter отсёк все ноды —
  то же условие, что warning на 621).
- `SubscriptionController` сохраняет последнее значение
  (`lastChannelsWithoutNodes`) после каждой успешной сборки и дёргает
  notifyListeners (существующий канал уведомлений).
- `home_screen` при смене значения (и непустом списке) показывает floating
  SnackBar по паттерну §166 (строка ~287): один канал —
  `'Channel "X" matched no nodes — check its node filter.'`; несколько —
  `'N channels matched no nodes — check their node filters.'`. Уведомление
  транзиентное, ничего не персистится.
- Строка в `emitWarnings`/AppLog остаётся (диагностика).

### Debug API — `app/lib/services/debug/handlers/channels.dart`, `help.dart`

| Место | Было | Стало |
|---|---|---|
| channels.dart:245-250 | 409 «a detour channel cannot include block» | снят |
| channels.dart:251, 270 | dropBlock-нормализация include_block при detour:true | снята |
| channels.dart:240-243 | 409 vpn-1+detour, текст «is the fallback rule target and cannot be…» | остаётся; текст/rationale переписаны (решение №2) |
| channels.dart:12-16, 88-90, 233-238 | комменты старой семантики | переписаны |
| help.dart:203-208, 211, 217-219 | «leaves rule targets (refs → vpn-1)… cannot include block (409…)» | переписаны: detour = разрешение; healed.rules — только disable/delete |
| help.dart:485-486 | краткие описания PATCH/DELETE | синхронно |

Контракт ломается осознанно (Debug API — root-by-design, персональный):
PATCH `{detour:true, include_block:true}` → 2xx; `healed.rules` при
flag-set — честный 0 (формат ответа не меняется).

### Мёртвые ветки снекбаров heal

| Место | Что |
|---|---|
| routing_screen.dart:395 | `ruleLead: … 'is now a detour channel'` — недостижима после отключения flagSet-heal; упростить до disable-ветки |
| routing_screen.dart:254-256, 275-280, 293-295, 379-380, 391-392 | комменты «rules-ссылки лечатся и при flag-set» — переписать |
| node_list.dart:437-444 | rules-часть healedParts недостижима из этого пути; код на счётчиках — не менять, коммент 437-438 уточнить |

Лид `'is no longer a detour target'` (303) и detours-счётчики — живые,
остаются.

### ⚙ — централизация display-префикса

Все ручные подстановки `kDetourTagPrefix` для КАНАЛОВ переходят на
`Channel.displayLabel`:

| Место | Примечание |
|---|---|
| routing_group_tile.dart:45 | тайл канала на Routing |
| home_controller.dart:174-178 | home-dropdown/заголовки; коммент «а не канал правил» переписать; бонус: пустой label теперь падает на tag |
| detour_target_picker.dart:42, 122, 283 | display канала в пикере/шапке |
| outbound_view_screen.dart:311 | хоп-заголовок; семантика уточняется: ⚙ по флагу канала (source-of-truth), а не по факту «хоп — канал» |
| routing_screen_helpers.dart:53 | новые места — пикеры правил (см. выше) |
| dns_settings_screen.dart:146-152 | DNS outbound-пикер — label через displayLabel |

НЕ трогать: `tag_resolver.dart` / `server_list_build.dart:83` /
`ConfigNode.isMarkedDetour` — это ⚙ в тегах detour-СЕРВЕРОВ (§080/§090),
другой концепт. `ConfigNode.isDetour` (структурный, detourRefCount>0) —
другой концепт, не трогать.

## Совместимость

- **Даунгрейд**: новый бэкап с `detour:true + include_block:true` на старой
  версии молча коэрсит include_block=false (данные в файле целы, теряется
  поведение); route_final → detour-канал деградирует в vpn-1 с warning.
  Принято как стандартная деградация, без кода.
- **Даунгрейд label с ⚙**: storage-label detour-канала несёт `⚙ ` — старые
  версии лепят display-префикс поверх → «⚙ ⚙ Relay» в списках; снятие галки
  на старой версии префикс из label не срежет (правится ручным rename).
  Косметика, данные целы — принято (finding адверсарного ревью).
- **Уже вылеченные пользователи**: у кого flagSet-heal ранее переписал
  правила на vpn-1 — восстановлению не подлежит (heal необратим by design,
  Решение B §202). Отметить в релиз-нотес.
- Старые бэкапы на новой версии — беспроблемны (старые писатели физически
  не могли сохранить detour+include_block).

## Риски и edge cases

- Пустая прослойка теперь блокирует детурящийся флот (block-first) вместо
  тихого «no hop» — осознанная отмена §248 Q1: видимый отказ + SnackBar
  лучше тихой утечки rule-трафика мимо VPN (§201). Зафиксировано владельцем.
- route_final = detour-канал, который детурится сам через свои ноды, — не
  цикл (route_final не ребро графа); настоящие кольца ловит §254 fatal.
- ⚙ в outbound_view сместился с «канальный хоп» на «флаг канала» — при
  ссылке на не-флагнутый канал через Debug API шестерёнки не будет
  (консистентно с новой семантикой).

## Тесты

Инверсии (фиксируют новый контракт позитивно, не удаляются):

| Файл | Что меняется |
|---|---|
| test/services/routing_outbound_options_test.dart:9-18 | detour-канал ПРИСУТСТВУЕТ в опциях (с ⚙-label); остальные 3 теста — без правок |
| test/models/channel_detour_test.dart:18-28, 41-46 | include_block выживает при detour:true; roundtrip расширить парой detour+includeBlock; vpn-1/copyWith — остаются |
| test/builder/detour_channel_gates_test.dart | 73-85: block ЭМИТИТСЯ; 87-106: пустой detour-канал → `[block, direct]` default=block; 414-447: route_final=vpn-2 и vpn-2-auto ОСТАЮТСЯ без warning; 358-380: переименовать (штатное поведение, не деградация); §254-группа (121-355), AWG, омонимия — без правок |
| test/migration/detour_channel_heal_test.dart:167-220 | flag-set = no-op: ссылки не тронуты, res.rules==0; flag-unset/disable/delete (114-165) — без правок |
| test/services/debug/channels_handler_test.dart:255-301 | combo → 2xx, оба поля сохранены; include_block на уже-detour → 2xx; нормализация — убрана; healed при flag-set → `{'rules': 0, 'detours': 0}`; vpn-1→409 и DELETE-healed — без правок |

Новые кейсы:

- backup roundtrip `detour:true + include_block:true` — оба поля живы
  (test/services/backup_service_test.dart, рядом с 347).
- route_final = detour-канал → конфиг собирается, `route.final` не тронут,
  warnings пусты.
- `Channel.displayLabel`: флаг+label, флаг+пустой label→tag, дедуп ⚙,
  без флага.
- `BuildResult.channelsWithoutNodes`: непустой фильтр + 0 матчей → канал в
  списке; пустой фильтр / пустой selectorTags → нет.

## Docs to update

- `docs/STORAGE.md` 820-826 (семантика `detour`: разрешение;
  include_block-инвариант снят; vpn-1-коэрция остаётся) + 850-860
  (heal-матрица: «включение detour-роли» убрать из rules-триггеров).
- `docs/USER_GUIDE_RU.md` 357-362 («перестаёт быть пунктом назначения» →
  переписать).
- `docs/api/debug-api-reference.md` 447-478 (409-quirks убрать, пример с
  `healed.rules:1` перезаписать, heal-триггеры).
- `docs/spec/features/248 detour-channels/spec.md` — update-блоки
  (blockquote-прецедент §254 там же, строки 72-78) в секции: роли (34-36),
  Q1/инварианты (48-55, 62-70), validFinals (99-103), «одна точка» (125-128),
  heal-матрица (160-166), SnackBar-матрица (188-198), Debug API (220-231),
  restore-деградации (238-248), таблица файлов (274-287), тесты (299-316),
  критерии готовности (322-328). Шапку-статус дополнить ссылкой на §274.
- `docs/spec/features/README.md:79` — описание 248: убрать «исключён из
  целей правил» и мёртвый «edge-strip» (умер ещё в §254).
- `CHANGELOG.md` — секция Unreleased.

## Верификация

- `flutter analyze` — весь проект (CI-правило, включая test/): чисто.
- `flutter test` — полный прогон: 1873/1873 зелёные (инверсии + новые кейсы:
  displayLabel ×4, channelsWithoutNodes, backup roundtrip detour+include_block,
  route_final=detour-канал валиден + граничный «auto-двойник без эмита →
  vpn-1», flag-set no-op, PATCH combo 2xx).
- Адверсарное ревью диффа (4 измерения × независимая проверка находок) —
  см. итог в секции ниже.
- Ручная проверка на устройстве (по команде владельца): канал с галкой
  detour виден в route final и пикере правила с ⚙; галки detour и
  Include block сосуществуют; установка галки не трогает существующие
  правила; канал с фильтром-без-матчей показывает SnackBar снизу и падает
  в block.

## Нерешённое / follow-up

- Комментарий detour_target_picker.dart:58 упоминает мёртвый edge-strip
  §248 — вычищен попутно при реализации.
- features/125 spec.md:390 («detour-ссылки → vpn-1») устарел ещё при §248 —
  вне скоупа, по желанию отдельной микроправкой.
- ~~**Pre-existing (§248-эра, не §274)**: Debug API `_create`
  (handlers/channels.dart:~91-96) не зовёт `syncDetourChannelRefsCleared`
  при `healed.detours > 0` (в отличие от `_update`/`_delete`) — re-create
  тега после restore может дать воскрешение вылеченного storage из
  in-memory `_entries`. Найдено адверсарным ревью §274, вынесено отдельной
  задачей.~~ → **закрыто [§275](275-channel-mutations-detour-resync.md)**
  (v2.15.6): достижимость подтверждена пробником и на устройстве (`POST
  /channels {"enabled": false}` → disabling-переход → `detours: 1`); мутации
  каналов переведены на `ChannelMutations` (heal + ресинк одной операцией),
  голый storage закрыт `@visibleForTesting`.
- UI-слой уведомления «канал без узлов» (stamp/listener/dedup в
  home_screen) покрыт только ручной верификацией — юнитов на
  ChangeNotifier-цепочку нет (билдер-слой покрыт).
