# §655 — DNS вкладкой на экране Routing

| Поле | Значение |
|------|----------|
| Тип | U (интерфейс: перенос экрана) |
| Статус | D (done): 60c5af9d, CI 38809500428 зелёный; эмулятор 16.10.2026 (2.25.15-dev.41): меню, порядок вкладок, содержимое DNS, ⋮ только на Rules, пресет FakeIP ↔ DNS, перенос правки DNS ↔ Rules, ссылки `route:dns` и `route:routing/dns` — ок; переход из листа DNS-health не проверен (лист только при сбоях DNS под VPN) |
| Фича | [004-ROUTING](../features/004-ROUTING/), [005-DNS](../features/005-DNS/), [020-APP_SHELL](../features/020-APP_SHELL/) |
| Дата | 2026-10-15 |
| Связанные | §107 (staging LazyPersistMixin), §117 (DNS-опция правила, локи «used by»), §257 (`dns_enable` пресета), §262 (вход на Presets из DNS-health), §312 (живое состояние DNS-групп), §357 (support-ссылки `route:*`), §396 (меню ⋮ на вкладке Rules), §626 (несохранённые правки) |

## Проблема

DNS в приложении в основном отражает маршрутизацию:

- DNS-правила частично повторяют пресеты и правила маршрутизации;
- пресет `ru-direct` включает группу `dns_ru`, у пресетов есть DNS-переключатель (`dns_enable`);
- Hijack DNS, «Resolve destination IP» и DNS-опция правила живут в Routing.

Сейчас это два пункта бокового меню. Пользователь включает пресет на одном
экране, а результат видит на другом.

## Решение (владелец, 15.10.2026)

1. Экран Routing получает пятую вкладку **DNS** сразу после **Rules**.
   Порядок: Directions · Presets · Rules · **DNS** · Tunnel apps.
   Индексы: Rules остаётся 2 (гейт меню ⋮ §396 не меняется), DNS = 3,
   Tunnel apps = 4. Полоса вкладок уже прокручиваемая (`isScrollable: true`).
2. Содержимое вкладки DNS — нынешний экран DNS Settings **без изменений**:
   - те же блоки в том же порядке;
   - те же редакторы серверов и правил, диалоги, очистка кэша;
   - те же строки l10n.

   Своего AppBar у вкладки нет: заголовок экрана — «Routing». Индикатор
   загрузки — внутри вкладки, а не отдельным Scaffold.
3. Пункт бокового меню «DNS Settings» убирается. Подпись пункта Routing
   говорит, что там есть и DNS. Текст подписи: «Directions, rules and DNS»
   вместо «Directions and routing rules»; переводы ru/zh — в словари.
4. Все входы на экран DNS ведут на Routing, открытый на вкладке DNS:

   | Вход | Где | Было | Станет |
   |---|---|---|---|
   | боковое меню | `home/widgets/home_drawer.dart` | `DnsSettingsScreen` | пункта нет |
   | support-ссылка `route:dns` (§357) | `home_screen.dart` (`case 'dns'`) | `DnsSettingsScreen` | Routing, вкладка DNS |
   | support-ссылка `route:routing/dns` | там же (`case 'routing'`, `segs[1]`) | — (открывался Directions) | Routing, вкладка DNS |
   | лист DNS-health → «DNS settings» | `live_events_tab/dns_health_sheet.dart` `_openDnsSettings` | `DnsSettingsScreen` | Routing, вкладка DNS |

   `route:dns` остаётся в `kSupportRouteScreens`: ссылки в уже
   опубликованных support-сообщениях должны работать.
   Параметр `RoutingScreen.initialPresetsTab` заменяется параметром
   «начальная вкладка» (enum или индекс). Все текущие вызовы с
   `initialPresetsTab: true` переводятся на него, поведение §262 сохраняется.
5. Класс `DnsSettingsScreen` как отдельный маршрут больше не нужен. Его
   состояние переезжает в виджет вкладки (имя — на усмотрение исполнителя,
   например `DnsSettingsTab`) рядом с остальными вкладками Routing.
   Комментарии в `services/builder/post_steps/dns_rules.dart` и
   `dns_servers.dart` со ссылкой на класс обновить.

### Согласованность двух вкладок (главный риск)

Оба экрана держат свои буферы и сбрасывают их в `SettingsStorage._cache`
на каждую правку (`LazyPersistMixin.markDirty` → `stageChanges`, §107).
Пока это были разные маршруты, одновременно жил только один из них. На одном
экране они живут вместе, и буфер одной вкладки может затереть правку другой.

Пересечения по ключам хранилища:

| Кто пишет | Что | Чей буфер устаревает |
|---|---|---|
| Routing `stageChanges` | `custom_rules` (вместе с пресетами и DNS-опцией правил), `route_final`, Направления | DNS-вкладка: `_customRules`, зеркала, серверы и правила пресетов, `_presetDnsEnable`, варианты outbound |
| Routing: импорт правил (⋮ на Rules) | `dns_servers`, `dns_rules` напрямую | DNS-вкладка: `_servers`, `_rules` |
| DNS-вкладка: переименование сервера, локи «used by», `dns_enable` пресета (`dns_settings_screen.dart` ~389, ~914–959) | `custom_rules` напрямую | Routing: `_customRules` (и `_userVars`, если `dns_enable` идёт через vars) |
| DNS-вкладка `stageChanges` | `dns_servers`, `dns_rules`, стратегия, final, резолвер, кэш | Routing этих ключей не держит, кроме чтения при импорте/экспорте |

Обязательные инварианты:

- **И1.** При каждом входе на вкладку DNS она заново читает состояние из
  хранилища, как сейчас при открытии экрана (`_load` + `_pullDnsGroups`).
  Правки, сделанные на других вкладках, видны сразу.
- **И2.** При уходе с вкладки DNS её незаписанные правки дописываются в
  кэш (дождаться `_stagingInFlight`), затем Routing перечитывает из
  хранилища `custom_rules`, `route_final` и vars в свои буферы. Перечитывание
  **не** вызывает `markDirty`: только обновляет буферы и пересобирает экран.
  Иначе следующая правка на Rules/Presets затрёт переименование
  DNS-сервера или `dns_enable`.
- **И3.** Запись на диск (`flushToDisk`) — как сейчас: при закрытии экрана
  Routing и при `paused`. Отдельный flush при смене вкладки не нужен.
- **И4.** Свайп между вкладками не должен терять правку, если она пришла во
  время анимации. Граница — смена `TabController.index`, а не
  `animation.value`.

Как именно этого добиться, решает исполнитель. Один из вариантов: вкладка
DNS не держится живой (`TabBarView` без keep-alive уничтожает её при уходе,
её `dispose` дописывает буфер), а Routing на `index` ≠ 3 после ухода с 3
перечитывает буферы. Если у вкладки DNS остаётся свой `LazyPersistMixin`,
её `dispose` с flush на диск при каждом уходе с вкладки допустим, но тогда
И2 должен дождаться и его.

## Что не меняется

- Сборка конфига, ключи хранилища, Debug API `/settings/dns_options/*`,
  backup — без изменений.
- Плашка «Settings changed», пересборка при возврате на Home — как сейчас.
- Меню ⋮ экспорта/импорта видно только на Rules.
- Внешний вид блоков DNS не меняется. Новых кнопок Save нет.

## Риски и граничные случаи

- Неочевидный путь: правка на DNS, свайп на Rules, правка, назад на
  Home. Обе правки должны попасть в конфиг.
- Обратный путь: импорт правил с DNS-частью на Rules, затем вкладка
  DNS. Импортированные серверы и правила видны; правка на DNS их не стирает.
- Смена локали при открытой вкладке DNS (`onLocaleTemplateFetch`, §279).
  Сейчас это повторный `_load()`; в составе Routing не должно быть двойной
  загрузки или потери буфера.
- Открытый полноэкранный редактор DNS-сервера или правила (§626) лежит
  поверх всего маршрута Routing. Вкладку при этом сменить нельзя, отдельной
  обработки не нужно.
- Тест `app/test/screens/dns_cache_settings_test.dart` поднимает
  `DnsSettingsScreen` напрямую — перевести на новый виджет вкладки.

## Проверка

- Точечно: тест `dns_cache_settings_test.dart` (обновлённый) и новый
  виджет-тест на И2: правка `custom_rules` на вкладке DNS, затем правка на
  Rules — в хранилище оба изменения. Полный прогон — CI.
- Эмулятор:
  1. боковое меню без «DNS Settings», у Routing новая подпись;
  2. Routing → DNS: все блоки на месте, переименование сервера с локом
     «used by» отражается в правиле на Rules;
  3. включить пресет `ru-direct` на Presets → вкладка DNS показывает `dns_ru`;
  4. ссылки `lxbox://route:dns` и `lxbox://route:routing/dns` открывают
     вкладку DNS;
  5. Live → лист DNS-health → переход открывает вкладку DNS, переход к
     FakeIP — вкладку Presets.

## Документация

- `features/004-ROUTING/FEATURE{,.ru}.md` — вкладка DNS в составе экрана,
  граница с 005 (экран общий, функции DNS описаны в 005).
- `features/005-DNS/FEATURE{,.ru}.md`, `FUNCTIONS/dns-servers{,.ru}.md` —
  «экран DNS Settings» → «вкладка DNS экрана Routing».
- `features/020-APP_SHELL/FUNCTIONS/navigation{,.ru}.md` — состав
  бокового меню (строка «Настройка»), support-маршруты.
- `features/024-TEMPLATE/FUNCTIONS/config-template.ru.md`, `docs/TEMPLATE.md`,
  `docs/ARCHITECTURE.md` — упоминания экрана.
- `docs/USER_GUIDE.md`, `docs/USER_GUIDE.ru.md` — путь «Routing → DNS»
  по редполитике.
- §357 — строка таблицы `route:dns` (новое назначение).
- Старые release notes и закрытые задачи не правим.

## Реализация

- `screens/dns_settings_tab.dart`: `DnsSettingsTab` (бывший
  `DnsSettingsScreen`, блоки и строки те же) и `DnsTabWrites` — реестр
  записей вкладки: staging `LazyPersistMixin` и прямые записи
  `custom_rules`/каскада `on_change`.
- `RoutingScreen`: `enum RoutingTab` и параметр `initialTab`; свой
  `TabController` вместо `DefaultTabController`.
- И1: вкладка без keep-alive, каждый вход монтирует её заново (`_load` +
  `_pullDnsGroups`).
- И2/И4: на смену `TabController.index` с DNS и на каждую завершённую запись
  вкладки при индексе не на DNS Routing ждёт `DnsTabWrites.settle()` и
  перечитывает `custom_rules`, `route_final`, vars (`_refreshSrsCache`) без
  `markDirty`; повторные запросы сливаются в один проход.
- И3: flush на диск — как был: dispose вкладки DNS (уход с неё), dispose
  Routing, `paused`.
- Тесты: `test/screens/dns_cache_settings_test.dart` на `DnsSettingsTab`,
  `test/screens/routing_dns_tab_sync_test.dart` — И2.

## Открытое

Нет.
