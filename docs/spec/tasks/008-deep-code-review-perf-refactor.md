# 008 — Deep code review: performance, упрощения, кандидаты на рефакторинг

| Поле | Значение |
|------|----------|
| Статус | Done (отчёт, обновлённое глубокое чтение) |
| Дата старта | 2026-04-20 |
| Дата завершения | 2026-04-20 |
| Коммиты | — (только документация) |
| Связанные spec'ы | [`003 home screen`](../features/003%20home%20screen/spec.md), [005](./005-optimization-pass.md), [007](./007-peer-review-tasks-001-006.md), [009](./009-p0-correctness-fixes.md) |
| Объём ревью | Пошаговое чтение целых горячих модулей: `home_screen.dart` (drawer/build/list), `home_controller.dart` (init/heartbeat/reload/mass ping), `subscription_controller.dart` (init/rehydrate/fetch/generate/persist), `clash_api_client.dart` (+ `TrafficSnapshot`), `clash_endpoint.dart`, `build_config.dart` (deep copy), `settings_storage.dart` (кэш/save), `app_log.dart`; Kotlin не разбирался |

## Статус выполнения (2026-04-21)

| Секция | Приоритет | Статус |
|--------|-----------|--------|
| §A (A1 animation, A2 timer, A3 dispose) | **P0** | ✅ Closed в коммите `2593152`, см. [009](./009-p0-correctness-fixes.md) |
| §B (heartbeat reduce fetchProxies) | P1 | Открыто — отложено до 1.4.1+ (требует design review по свежести UI vs battery) |
| §C (Listenable.merge split) | P1 | Открыто — отложено до 1.4.1+ (архитектурная правка, высокий риск сломать reactive зоны без re-test) |
| §D1 (кэш route.final) | P2 | Открыто |
| §D2 (mass-ping batched emit) | P2 | Открыто |
| §D3 (displayNodes кэш) | P2 | Открыто |
| §D5 (параллельный rehydrate) | P3 | Открыто |
| §E (SettingsStorage batched save) | P3 | Открыто |
| §H (разрез файлов / контроллеров) | P4 | Открыто |

P0 — закрыто перед релизом 1.4.0. P1+ идут отдельными task'ами с design review по каждой.

---

## Методология (что сделано по-настоящему)

1. **Прочитаны большие непрерывные куски** `home_screen.dart` (init, `build`, drawer, controls, status chip, node list builder), не только grep.
2. **Прослежен полный steady-state цикл** «туннель поднят»: `_startHeartbeat` → `_checkHeartbeat` → `fetchTraffic` + опционально `fetchProxies` → `_emit` → что пересобирается в UI.
3. **Прослежен** `reloadProxies` / `ClashEndpoint` — сколько раз парсится весь конфиг.
4. **Просмотрены** `pingAllNodes`, `SubscriptionController._rehydrateFromCache`, `_generate` / `buildConfig` вход, `_persist` / `SettingsStorage._save`.

Профиль **DevTools / Timeline** здесь по-прежнему не снимался: ниже — выводы из **структуры алгоритмов и частоты вызовов**, которые профиль почти наверняка подтвердит как «красные», если их замерить.

---

## A. Критично: корректность и анти-паттерны Flutter

### A1. Побочные эффекты внутри `build`

**Файл:** `app/lib/screens/home_screen.dart`, `_buildStatusChip` (около строк 641–648).

Внутри метода, который вызывается из `AnimatedBuilder` → фактически из **`build`**, вызываются `_connectingAnim.repeat()` / `stop()` / `reset()` в зависимости от `isConnecting`. Это нарушает правило «build чистый»: лишние вызовы при любом родительском rebuild, риск предупреждений framework'а, лишняя работа на каждом кадре уведомлений от контроллера.

**Рекомендация:** перенести управление `AnimationController` в `didUpdateWidget`, listener контроллера по `tunnel == connecting`, или отдельный `TickerMode` / виджет, где `initState`/`dispose` владеют анимацией.

### A2. Планирование `Timer` из `build` через `Builder`

Тот же файл, блок `state.lastError` (около 387–414): внутри `Builder` при смене `state.lastError` создаётся `_errorTimer`. Любой rebuild с тем же `lastError` не должен дублировать, но логика завязана на проход `build` — хрупко при агрессивных rebuild'ах.

**Рекомендация:** перенести в `didUpdateWidget` или в listener `HomeController` с сравнением предыдущего `lastError`.

### A3. `HomeController` не `dispose()`-ится из `HomeScreen`

**Файл:** `app/lib/screens/home_screen.dart`, `dispose` (строки ~139–145).

Вызываются `_autoUpdater.dispose()`, `removeListener`, `removeObserver`, но **нет** `_controller.dispose()`. `HomeController.dispose` отменяет `_statusSub`, heartbeat, transient timer — сейчас `HomeScreen` — корень `MaterialApp` и почти никогда не уничтожается, поэтому на проде процесс гасится ОС. Для **тестов, hot restart, возможного будущего** смены корневого виджета — это дыра в контракте владения.

**Рекомендация:** явно `unawaited`/`await` `_controller.dispose()` (и при необходимости жизненный цикл для `SubscriptionController`, если появятся подписки/таймеры).

---

## B. Steady-state: heartbeat — главный скрытый «двигатель» нагрузки

**Файл:** `app/lib/controllers/home_controller.dart`, `_checkHeartbeat` (~220–258).

Каждые **`_heartbeatInterval` (20 s)** при поднятом туннеле:

1. **`fetchTraffic()`** — HTTP `GET /connections`, затем **`TrafficSnapshot.fromConnectionsJson`** проходит **весь** массив `connections`: суммы, `byRule`, `byApp` с мапами. Для сотен активных соединений это заметный CPU на UI-isolate, хотя на главном экране в traffic bar используются в основном агрегаты (`upload`/`download`/`activeConnections`/memory).
2. Опционально **`fetchProxies()`** — второй полноразмерный JSON (весь каталог прокси), затем **`_emit`** с заменой `proxiesJson`.

После этого срабатывает **`notifyListeners`** на `HomeController` → см. раздел **C**.

**Точки роста (по убыванию важности):**

| # | Что | Почему больно |
|---|-----|----------------|
| B1 | Полный разбор `/connections` каждые 20 s | Много аллокаций Map + цикл по всем conn даже если UI не показывает byRule/byApp на Home |
| B2 | `fetchProxies` каждые 20 s вместе с traffic | Удваивает трафик и JSON decode на localhost при большом числе outbounds |
| B3 | После emit — полный rebuild Home | См. C |

**Идеи (нужна оценка продукта):**

- Лёгкий эндпоинт / отдельный запрос только для totals, если когда-нибудь появится в API ядра; иначе — **реже** вызывать `fetchProxies` (например, раз в N heartbeat'ов или только если `nodes`/`urltest now` подозрительно stale).
- Разделить модель: «лёгкий снимок для chip» vs «полный снимок для Statistics» — не тащить `byApp`/`byRule` на главный экран каждые 20 s.

---

## C. Радиус поражения rebuild: `Listenable.merge([_controller, _subController])`

**Файл:** `app/lib/screens/home_screen.dart`, корневой `AnimatedBuilder` (~172–197).

Любой **`notifyListeners()`** с **любого** из двух контроллеров пересобирает **весь** `Scaffold`: drawer, кнопки, группа, **весь** `ListView.separated` нод.

Следствия:

1. **Heartbeat** (раздел B) → каждые 20 s полная перерисовка списка нод + все closure в `itemBuilder`.
2. **`SubscriptionController`** при `_rehydrateFromCache`, fetch подписок, `notifyListeners` в конце `_fetchEntryByRef` и т.д. — **тоже** качает Home, даже если пользователь на главном экране и не трогал список подписок.
3. Сочетается с **mass ping** (многие `_emit`/сек) — эффект усиливается.

**Это главный архитектурный рычаг производительности**, сильнее чем микро-оптимизации в `NodeRow`.

**Направления работы:**

- Разнести подписки: например **`Listenable.merge` только на зону статуса/трафика**, список нод — `Selector<HomeController, …>` / отдельный `AnimatedBuilder` только на `_controller` с `child:` для статичного дерева — или хранить «лёгкий» `ValueNotifier` для списка нод.
- Либо ввести **слой ViewModel** с более гранularными notifiers (tunnel, traffic, nodes, subscriptions metadata).

---

## D. Пиковые и фоновые нагрузки (кроме уже известного mass ping)

### D1. `reloadProxies`: повторный полный **json5Decode** конфига

**Файлы:** `app/lib/controllers/home_controller.dart` (`reloadProxies` ~587–618), `app/lib/config/clash_endpoint.dart`.

В `reloadProxies` после `fetchProxies` вызывается **`ClashEndpoint.routeFinalTag(_state.configRaw)`**, который снова делает **`json5Decode(trimmed)`** всего конфига — это **отдельный полный разбор** того же JSON, который уже лежит в памяти как строка и частично кэшируется в `ConfigCache` только для outbounds/endpoints, не для `route.final`.

Параллельно **`ClashEndpoint.fromConfigJson`** при `_rebuildClashEndpoint` тоже гоняет json5 по конфигу при смене endpoint.

**Точка роста:** кэшировать распарсенный `route.final` (или весь мелкий «индекс» из experimental + route) при `saveParsedConfig` / смене `configRaw`, чтобы не парсить мегабайтный JSON лишний раз на каждый reload.

### D2. Mass ping — не только emit (уже было в первой версии отчёта), но контекст C

Каждый завершённый ping → новый `HomeState` → **пересортировка** `sortedNodes` (новый инстанс state) → **полный** rebuild по **C**. Итог: сочетание **D2 + C** даёт основной визуальный jank при mass ping на больших списках.

### D3. `displayNodes`: новый список на каждый rebuild

**Файл:** `home_screen.dart` ~1174–1176.

```dart
final displayNodes = _showDetourNodes
    ? state.sortedNodes
    : state.sortedNodes.where((t) => !t.startsWith(kDetourTagPrefix)).toList();
```

При скрытых detour каждый rebuild (в т.ч. каждые 20 s от heartbeat) аллоцирует **новый `List`**, даже если состав не менялся.

**Рекомендация:** кэшировать `(bool showDetour, int nodesVersion)` → `List` в `State` виджета или derived поле в `HomeState` только при смене `nodes`/`sortMode`/флага.

### D4. `itemBuilder`: повторные вызовы `ClashApiClient.urltestNow` / `proxyEntry`

На каждую **видимую** строку каждый rebuild — несколько map-lookup по `proxiesJson`. Сложность линейна по числу видимых строк, не по всем нодам — приемлемо; узкое место именно **частота rebuild** из **C**, а не эти lookup сами.

### D5. `SubscriptionController._rehydrateFromCache`

Цикл по всем подпискам: последовательные `await HttpCache.loadBody` + `decode` + `parseAll`. На старте с многими подписками это **длинный критический путь** до первого `notifyListeners` после цикла (один раз в конце). Параллелить осторожно (ограничить concurrency 2–3), если станет заметно на слабых устройствах.

### D6. `buildConfig` / `_deepCopy`

**Файл:** `app/lib/services/builder/build_config.dart` — `jsonDecode(jsonEncode(s))` для копии шаблона.

Это **O(размер шаблона)** на каждую сборку конфига. Для GUI это ожидаемо; узкое место — частота вызова `generateConfig` (ручной rebuild, auto updater после триггеров). Не трогать без профиля сборки.

### D7. `_addJsonOutbounds`: `decode(jsonEncode(ob))`

**Файл:** `subscription_controller.dart` ~385–388.

Round-trip JSON ради нормализации — понятно по истории парсера, но дорого на больших paste. Альтернатива: явный «канонизатор» map без строкового round-trip, если парсер это позволит.

---

## E. `SettingsStorage`: полная перезапись файла

**Файл:** `app/lib/services/settings_storage.dart`, `_save`.

Каждый `setVar` / логически завершённое изменение ведёт к **`JsonEncoder.withIndent` всего `_cache`** и записи на диск. При пакетных обновлениях (debug API, генерация vars из `buildConfig`) — **много полных перезаписей подряд**.

**Точка роста:** батчить записи (очередь + debounce 100–300 ms) или API `setVars(Map)` с одним save.

---

## F. Остальное (средний / низкий приоритет)

| ID | Тема | Комментарий |
|----|------|-------------|
| F1 | `AppLog.notifyListeners` на каждую строку | Уже в первой версии; критично только при открытом Debug + шумном core |
| F2 | `AutoUpdater` + часовой таймер при paused app | Продуктово; нагрузка мала |
| F3 | `SpeedTestScreen` + `Timer.periodic` 500 ms | Таймер короткий; проверить отмену при `dispose`/`pop` во время теста |
| F4 | `pingNode` — два `_emit` | Мелочь |
| F5 | `http.Client` в `ClashApiClient` | Один на жизнь endpoint'а — ок |

---

## G. Что уже хорошо после 005 (не регрессировать)

- `ConfigCache` + `sortedNodes` как `late final` на инстансе `HomeState` — убрали **jsonDecode на каждый** item build.
- Батч `_emit` в `_handleStatusEvent` по VPN-переходам.
- Пауза таймеров Stats/Connections в background.

---

## H. Рефакторинг (структура кода, не только perf)

1. **Разрезать `home_screen.dart`** на модули (drawer / controls / node list / sheets) — снижает риск и ускоряет review.
2. **Выделить из `HomeController`** слои: (VPN статус + native), (Clash API + proxies state), (ping orchestration) — сужает публичную поверхность для тестов.
3. **Унифицировать парсинг конфига** для UI (detour/proto/route.final/clash port) — одна точка правды, меньше дублирующих json5/jsonDecode.

---

## Риски при внедрении

- Любой батчинг `_emit` при mass ping должен сохранять семантику `_massPingEpoch` и `cancelMassPing`.
- Узкие `AnimatedBuilder` — не сломать подписку на `_subController.configDirty` / баннеры rebuild.
- Кэш `route.final` должен инвалидироваться ровно при смене `configRaw`.

## Верификация отчёта

- Повторное чтение исходников с фиксацией номеров строк по grep/read (сессия 2026-04-20).
- Runtime-профиль по-прежнему рекомендуется для приоритизации B vs D2.

## Нерешённое / follow-up (приоритизировано)

| Приоритет | Действие |
|-----------|----------|
| **P0** | Исправить **A1** (анимация) и **A2** (timer) — корректность Flutter |
| **P0** | Добавить **`_controller.dispose()`** в `HomeScreen.dispose` — контракт владения |
| **P1** | Снизить радиус rebuild: разделить **C** (`Listenable.merge`) |
| **P1** | Heartbeat: ослабить **B1/B2** (реже proxies / легче snapshot для Home) |
| **P2** | Кэш **`route.final`** или индекс из конфига — **D1** |
| **P2** | Batched/throttled emit при mass ping + **D3** кэш filtered list |
| **P3** | Батч save в **E**; параллельный rehydrate **D5** — по метрикам старта |
| **P4** | Разрез файлов / контроллеров **H** |

После реализации — отдельные task-файлы с коммитами и критериями, см. [README](./README.md).
