# §652 — Регидрация подписок: выключенные лениво, разбор вне UI-потока

| Поле | Значение |
|------|----------|
| Тип | P (производительность) + D (дефект: UI замирает на старте) |
| Статус | D (done): A+B+C — A+B 89d162c4 (CI 38649166029, проверено владельцем 15.10.2026); C — доработка того же дня |
| Фича | [001-SUBSCRIPTIONS](../features/001-SUBSCRIPTIONS/) |
| Дата | 2026-10-15 |
| Связанные | §101 (гонки регидрации), §283 (регидрация не сигнал «узел ушёл»), §302 (import-rules на кэше), §400 (миграция legacy-ключей), §478 (вердикты ядра), §515 (stale-контроллер слота), §561 (`dropped`), §615 (`nodesNotLoaded`) |

## Проблема

Жалоба с 4PDA (k-dmitriy, 14.10.2026): после старта экран ~20 с не отвечает —
кнопки не нажимаются, меню не открывается. В логе последняя строка
`Re-hydrated 3925 nodes from cache: https://github.com/***` через 22 с после
`status=disconnected`. Подписка при этом **выключена**.

Причина в `SubscriptionController._rehydrateFromCache`
(`app/lib/controllers/subscription_controller.dart` ~319–420):

1. цикл идёт по **всем** `SubscriptionServers`, `enabled` не проверяется;
2. `decode` → `parseAll` → `_applyRulesToNodes` → `migrateLegacyDisabledKeys` →
   `stampStoredVerdicts` выполняются в основном isolate.

Узлы выключенной подписки в конфиг не попадают (`ServerListBuild.build`
выходит при `!enabled`), разбирать их на каждом старте незачем.

## Решение

### A. Ленивая регидрация выключенных подписок

1. Тело цикла регидрации одной записи вынести в метод
   `Future<void> ensureHydrated(SubscriptionEntry entry)`:
   - идемпотентен: если у `entry.list` уже есть `nodes` — сразу выход;
   - конкурентные вызовы на одну запись делят одну `Future` (не два разбора);
   - сохраняет все существующие guard'ы цикла: `stale` (§515), «entry ещё в
     `_entries`, тот же `url`, `nodes` всё ещё пуст» (§101), `_markBodyCacheMissing`
     (§615), лог пустого разбора с `diagnoseEmptyParse`, `_persist(keepDirtyFlag: true)`
     после миграции (§400), `stampStoredVerdicts` (§478), `summaryDropped` (§561);
   - регидрация **не поднимает** `configDirty` (как сейчас).
2. На старте `_rehydrateFromCache` регидрирует только записи с `enabled == true`.
   `rehydrationDone` завершается после них — HomeScreen bootstrap-пересборка и
   автоподключение ждут ровно то, что попадает в конфиг.
3. Выключенная запись догружается через `ensureHydrated` в точках:
   - (а) `toggleAt` при включении — **до** `_persist`/`notifyListeners`;
   - (б) начало `generateConfig()` — для всех `enabled`-записей без узлов, **до**
     `_compositionSignature()` (иначе подпись изменится и `configDirty` не
     снимется). Это же закрывает включение через Debug API (`PATCH enabled`);
   - (в) `_fetchEntryByRef` — **до** чтения `current.nodes`: иначе
     `refreshSubscriptionVerdicts(oldBodies: …)` с пустым списком снимет вердикты
     `core_rejected`, а `_compositionKey` всегда скажет «состав изменился»;
   - (г) `SubscriptionDetailScreen` при открытии (до `_loadNodes(cacheOnly: true)`),
     на время загрузки — индикатор вместо «No nodes found»; вкладки Nodes /
     Filters / сводка `dropped` получают узлы из того же вызова.
4. Принятое поведение (не дефект): у **неоткрытой выключенной** подписки на плитке
   остаётся «N nodes» из `lastNodeCount`, но нет пометки cached, «+N⚙» и значка
   предупреждений; Debug API `/subs` отдаёт пустые `warnings`, `/nodes` по тегу
   такой подписки — 404; дамп — пустые `_node_tags`. Появляется после открытия
   экрана подписки, включения или обновления.

### B. Разбор кэша в отдельном isolate

1. Чистая часть регидрации одной записи (`decode`, `parseAll`, применение
   import-rules, `migrateLegacyDisabledKeys`, `stampStoredVerdicts`,
   `summaryDropped`, `diagnoseEmptyParse`) — top-level функция, вход/выход только
   данные: тело (строка, прочитанная на main — `HttpCache` использует
   `path_provider`), `activeImportRules`, `disabledHashes`, `nodeWarnings`;
   выход — узлы, мигрированные хеши, `dropped`, hint пустого разбора.
   `_applyRulesToNodes` / `_remapAutoSelectSynonyms` вынести из экземпляра в
   top-level (замыкание поймало бы контроллер).
2. Запуск через `Isolate.run`. Мутации контроллера (`_replaceList`, `status`,
   `nodeCount`, `_persist`, логи `Re-hydrated…`) — только на main после возврата.
3. **Синглтоны.** В новом isolate `ContractRegistry.I` и `MapperSections.I`
   пусты, а разбор без них **не падает, а молча деградирует** (коды и санитайзер
   пропускаются, тип endpoint определяется неверно, черновые секции пусты).
   Воркер обязан инициализировать оба из данных, прочитанных на main
   (`ContractRegistry.load(loader:, lister:)` уже принимает инъекцию; для
   `MapperSections` — добавить вход «из готовых текстов»). Тексты читать на main
   один раз и переиспользовать. Если инициализация в воркере не удалась — это
   ошибка воркера, а не тихий разбор.
4. Логи, которые разбор пишет через `AppLog.I` (`uri_utils.dart` ~256, ~497),
   в воркере не теряются: собираются и воспроизводятся на main.
5. Отказ воркера (исключение, ошибка инициализации) → разбор этой записи на main
   по старому пути + `warning` в лог с причиной. Регидрация не должна остаться
   без узлов из-за воркера.
6. Записи разбираются последовательно (как сейчас), по одному `Isolate.run` на
   запись; `notifyListeners()` — после каждой записи, чтобы плитки оживали по
   мере готовности, а не разом в конце.

### C. Разбор ответа сети в отдельном isolate (доработка 15.10.2026)

По решению владельца — в этой же задаче, без отдельного номера.

Сейчас `_fetchEntryByRef` после сетевого ответа зовёт `parseFetched`
(`app/lib/services/subscription/sources.dart` ~115: inline-заголовки, мета,
`decode`, `parseAll(dropped:)`) и затем `applyRulesToNodes` — синхронно на main.
Для включённой подписки на тысячи узлов это то же замирание UI, что было на
старте, только при автообновлении или ручном Update.

1. Сеть (`_fetch`, ретраи) остаётся на main — это ожидание I/O, не счёт.
   Разделить `parseFromSource` на «получить `FetchResult`» и «разобрать».
2. Разбор ответа (`parseFetched`) + `applyRulesToNodes` с правилами на момент
   старта — в воркере, тем же механизмом, что B: `Isolate.run`,
   `ParseEnvSnapshot` (реестр + черновики), перехват `AppLog` с воспроизведением
   на main, отказ воркера → тот же разбор на main + `warning`.
   Вход/выход — только данные; проверить, что `DecodedBody`, `SubscriptionMeta`
   и всё в `ParseResult` пересылаемы (если что-то нет — пересылать то, из чего
   оно строится, и достраивать на main).
3. Всё, что читает или пишет состояние контроллера, — на main после возврата, в
   прежнем порядке: миграция legacy-ключей, `refreshSubscriptionVerdicts`, GC
   отметок, ключ состава, relink, `_replaceList`, `_persist`, события.
   Guard'ы после возврата из воркера те же, что сейчас после `await` фетча
   (entry ещё в списке, тот же url, `stale`). Если import-правила записи
   сменились, пока работал воркер, — правила применяются заново на main к
   свежему разбору (как B.3 для регидрации).
4. Через воркер идут все пути, разбирающие **тело подписки**
   (`SubscriptionServers`): сетевой fetch, повторный разбор снапшота файловой
   подписки и ответа того же URL в проходе автообновления (`pre` →
   `parseFetched`), первое добавление подписки по URL / из файла, если они
   разбирают тело тем же `parseFetched`/`parseAll`. Разбор одного узла
   (`UserServer`, ввод ссылки/JSON вручную, редактор) остаётся на main —
   там нечего ускорять.
5. Замер: на теле ~4000 узлов из корпуса/фикстур — время основного потока на
   один refresh до и после (сколько остаётся на main после воркера:
   вердикты, sha256 identity, ключ состава, `_persist`). Цифры — в раздел
   «Реализация». Если остаток на main > ~200 мс — записать, что именно его
   держит, но **не** оптимизировать в этой задаче.

### Реализация (15.10.2026)

Файлы (от `app/`):

- `lib/controllers/subscription_controller/cache_rehydrate.dart` (новый) —
  `CacheParseInput` / `CacheParseResult`, чистая `parseCachedBody`,
  `parseCachedBodyInIsolate` (`Isolate.run`, замыкание строится в top-level
  функции), `ParseEnvSnapshot` (снимок реестра и черновиков main и их установка
  в воркере), `replayCapturedLogs`; сюда же вынесены `applyRulesToNodes` и
  `_remapAutoSelectSynonyms` (раньше методы контроллера).
- `lib/controllers/subscription_controller.dart` — `_rehydrateFromCache` идёт
  только по `enabled`, `notifyListeners()` после каждой записи;
  `ensureHydrated` + `_hydrateEntry` (все guard'ы цикла сохранены) +
  `_parseCachedBody` (воркер → откат на main с warning `Re-hydrate: worker
  failed for … — parsing on main`); точки догрузки: `toggleAt` при включении
  (а), `_hydrateEnabledEntries()` в начале `generateConfig` до
  `_compositionSignature()` (б), начало `_fetchEntryByRef` (в); тест-шов
  `cacheParseWorkerForTesting`.
- `lib/controllers/subscription_controller/subscription_entry.dart` — поля
  `_hydration` / `_hydrationUrl` (общая `Future` и URL, для которого она
  запущена).
- `lib/screens/subscription_detail_screen.dart` — (г): `_loadNodes(cacheOnly:
  true)` ждёт `ensureHydrated`, пока `_loading` (полоса прогресса; пустой список
  при `loading` не рисует «No nodes found»).
- `lib/services/contract/registry.dart` — `_load` запоминает прочитанные
  тексты и состав протоколов; `snapshot` (`RegistrySnapshot`) и
  `loadFromSnapshot`.
- `lib/services/parser/engine/section_loader.dart` — тексты черновиков
  сохраняются при загрузке; `draftTexts` (незагруженный черновик сначала
  догружается с диска, как при первом разборе) и `loadDraftsFromTexts`.
- `lib/services/app_log.dart` — `capture`: перехват записей вместо буфера
  (ставит воркер; записи `uri_utils.dart` воспроизводятся на main).
- Тесты: `test/subscription/lazy_rehydration_test.dart` (пп. 1–5, 7),
  `test/subscription/rehydrate_worker_equivalence_test.dart` (п. 6: 8 самых
  маленьких тел `public_subscriptions` + фикстуры форматов, REPLACE-правило,
  legacy-ключ и вердикт на первом узле; сравниваются emit-JSON, identity,
  предупреждения, патч, `dropped`, миграция, подсказка).

Отступления и уточнения:

1. Реестр в воркере грузится не через `load(loader:, lister:)`, а новым
   `loadFromSnapshot` поверх того же `_load`: `load` приклеивает префикс
   ассетов и листинг манифеста, а снимок хранит пути от корня контракта и
   работает одинаково для `load` и `loadFromDirectory` (тесты). Тексты не
   перечитываются — это те, что прочитала загрузка на main.
2. `ensureHydrated` не повторяет попытку для того же URL после неудачи (тела
   нет, 0 узлов, ошибка): иначе каждый `generateConfig` заново читал бы кэш и
   писал тот же warning. Новый URL (Edit source) — новая попытка.
3. Если пока работал воркер у записи сменились `disabledHashes`,
   `nodeWarnings` или import-правила, разбор повторяется на main по текущим
   (раньше окно было только на чтение файла, теперь — на весь разбор).
4. (в) стоит в самом начале `_fetchEntryByRef`, до проверки `inProgress`:
   догрузка обязана прочитать кэш до того, как фетч перезапишет его ответом
   (иначе старое и новое тела совпали бы и вердикт держался бы ложно).
5. Отметка конвейера `markPipelineParsed` (Expando) через границу isolate не
   переезжает. Она читается только внутри `parseAll` (`parse_warnings.dart`),
   после разбора не нужна.
6. П. 1 «тело выключенной не читалось» проверяется через тест-шов воркера (тело
   на разбор не передавалось), а не счётчиком чтений `HttpCache`.
7. П. 8: `nodes_not_loaded_test` («тела нет: признак в памяти…») держал
   подписку выключенной и ждал признак сразу после старта — теперь признак
   ставится при догрузке, тест зовёт `ensureHydrated`. Остальные перечисленные
   файлы (вкл. golden_* из `storage_migration`, экраны подписки) зелёные без
   правок.

### Реализация C (15.10.2026)

Файлы (от `app/`):

- `lib/controllers/subscription_controller/cache_rehydrate.dart` — общий
  запуск `_runInWorker` (установка `ParseEnvSnapshot`, перехват `AppLog`),
  через него теперь идут и `parseCachedBodyInIsolate`, и новый
  `parseFetchedInIsolate`; `FetchParseInput` (`FetchResult` + правила) /
  `FetchParseResult` (`ParseResult` + отметки правил + логи); чистая
  `parseFetchedWithRules` = `parseFetched` + `applyRulesToNodes`.
- `lib/services/subscription/sources.dart` — `parseFromSource` =
  `parseFetched(await fetchRaw(...))` (C.1: сетевая половина — уже
  существовавший `fetchRaw`).
- `lib/controllers/subscription_controller.dart` — `_parseFetchedBody`
  (воркер → откат на main с warning `Parse: worker failed for … — parsing on
  main`, воспроизведение логов), тест-шов `fetchParseWorkerForTesting`.
  Через воркер: `_fetchEntryByRef` (сеть и `pre` — снапшот файловой / ответ
  того же URL в проходе), `addFileSubscription`, `updateSourceAt` (Edit source,
  URL и файл). Первое добавление по URL идёт через `_fetchEntryByRef`. На
  main остались одиночные узлы (`addFromInput` без URL, `_addJsonNodes`,
  `_addUriLines`, `updateConnectionAt`, WARP) и папки
  (`addMembersToFolder`, `addUrlSnapshotToFolder` — `FolderServers`, не тело
  подписки по C.4).
- Тесты: `test/subscription/fetch_parse_worker_test.dart` (пп. 9 через
  контроллер, 10, 11), `test/subscription/rehydrate_worker_equivalence_test.dart`
  (п. 9 на корпусе п. 6: узлы, `dropped`, мета из заголовков, rawBody,
  заголовки, отметки REPLACE/DISABLE).

Пересылаемость: `ParseResult` (узлы, `DecodedBody`, `SubscriptionMeta`,
`dropped`, тело, заголовки) — обычные данные, уходят из воркера как есть;
достраивать на main ничего не пришлось.

Замер (п. C.5): тело `public_subscriptions/bodies/27-github-ru-white-all-white`
целиком — 4025 узлов; refresh через контроллер с `MockClient`, `flutter test`
(JIT, debug — абсолюты выше релиза), 3 прогона после прогрева; «занятость
main» — сумма пауз цикла событий > 4 мс по heartbeat-таймеру.

| | refresh всего | разбор | занятость main | самая длинная пауза main |
|---|---|---|---|---|
| до (разбор на main) | 1,83–1,88 с | 1,66–1,70 с на main | 1,82–1,86 с | 1,81–1,86 с |
| после (isolate) | 2,12–2,17 с | 1,91–1,98 с в воркере | 0,23–0,25 с | 0,13–0,16 с |

Остаток на main ~240 мс (> 200 мс), что его держит: `bodiesByIdentity` ×2
(старые и новые узлы для вердиктов) ~70 мс; приём результата воркера и снимок
окружения ~30 мс; `sourceNodeIdentities` ~2 мс; остальное (~140 мс, порознь
не мерилось) — `_compositionKey` ×2 (контент-хеш каждого узла старого и
нового списка), миграция и GC отметок, `stampStoredVerdicts`, `_persist`.
По ТЗ не оптимизировалось.

Отступления и уточнения C:

1. Guard'ы после воркера: кроме `stale` (он был и после фетча) добавлены
   «запись ещё в списке, тот же URL» — после фетча их не было, хотя спека
   называла их существующими. Окно расширилось на время разбора, а Edit
   source в это окно иначе записал бы узлы старого URL поверх нового
   источника. Результат отбрасывается (`debug`-лог), плитке возвращается
   статус по текущим узлам.
2. Правила для воркера берутся после сети, перед разбором («на момент старта
   разбора»). Сменились (`importRules` / `importRulesEnabled` не те же), пока
   воркер работал, — `applyRulesToNodes` с текущими на main; отметки берутся
   из этого прогона.
3. `updateSourceAt` и `addFileSubscription` правила не применяли и не
   применяют (вход с пустыми правилами), поведение то же.
4. Отдельный тест-шов `fetchParseWorkerForTesting` вместо общего с
   `cacheParseWorkerForTesting`: входы и выходы разные.

## Вне объёма

- `_compositionSignature()` хеширует узлы всех записей (вкл. выключенные) дважды
  на каждый `generateConfig` — после A выключенные без узлов из него выпадают
  сами; отдельная оптимизация не делается.
- Зависание `stopping` после простоя из той же жалобы — отдельно, ждём полный лог.

## Риски

- Пропущенная точка догрузки → включённая подписка без узлов молча не попадёт в
  конфиг. Поэтому (б) — страховка на всех путях пересборки.
- Расхождение разбора в воркере и на main из-за неинициализированного синглтона
  — молчаливая порча узлов. Закрывается тестом эквивалентности (ниже).
- Гонки: включение/удаление/перетаскивание записи, переключение слота (§515)
  во время разбора в воркере — guard'ы §101/§515 проверяются **после** возврата
  из воркера.

## Проверка

Unit (точечно, только затронутые файлы):
1. Старт с одной включённой и одной выключенной подпиской: после
   `rehydrationDone` у включённой есть узлы, у выключенной `nodes` пуст, тело
   выключенной не читалось.
2. `toggleAt` включает выключенную → узлы есть до `notifyListeners`;
   `generateConfig` после этого содержит её outbounds и снимает `configDirty`.
3. Включение через сеттер `enabled` (путь Debug API) + `generateConfig` → узлы в
   конфиге.
4. `_fetchEntryByRef` по выключенной неразобранной подписке с узлом в
   `core_rejected` → вердикт сохраняется (сейчас снимался бы).
5. Два параллельных `ensureHydrated` на одну запись → один разбор.
6. Эквивалентность: разбор в воркере и на main на корпусе тел подписок
   (существующие фикстуры) даёт одинаковые узлы (emit-JSON, identity),
   `dropped`, мигрированные хеши, вердикты.
7. Отказ воркера → узлы получены разбором на main, в логе warning.
8. Существующие тесты регидрации зелёные: `rehydrate_race_test`,
   `nodes_not_loaded_test`, `file_subscription_test`,
   `dropped_summary_tails_test`, `fetch_dirty_flag_test` (там `boot(enabled: false)`
   — ожидания поправить под ленивую загрузку, если тест полагался на старт).

Эмулятор (Sonnet по сценарию): большая публичная подписка (~4000 узлов),
выключена → холодный старт, UI отвечает сразу, в логе нет `Re-hydrated` для неё;
включить → узлы появились, конфиг собирается; та же подписка включена →
холодный старт, во время регидрации экран прокручивается, меню открывается.

Доработка C (unit, точечно):
9. Refresh с подменённым воркером: узлы, `dropped`, мета, отметки правил те же,
   что при разборе на main (эквивалентность на том же корпусе, что п. 6).
10. Отказ воркера на refresh → узлы получены разбором на main, warning в логе.
11. Правила записи сменились во время разбора в воркере → на запись легли узлы
    с новыми правилами.
12. Существующие тесты fetch-пути зелёные: `fetch_dirty_flag_test`,
    `auto_updater_pass_test`, `stuck_updating_and_ttl_gc_test`,
    `file_subscription_test`, `emoji_tag_prefix_test`, `chain_hop_heal_test`,
    тесты вердиктов ядра на refresh (`core_reject_*`).
