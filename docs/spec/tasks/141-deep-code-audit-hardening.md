# 141 — Глубокий аудит кода: стабильность · рефакторинг · энергопотребление

| Поле | Значение |
|------|----------|
| Статус | **In progress** (P0 + большинство P1/P2/P3-low реализованы 2026-06-17; см. «Журнал реализации») |
| Дата старта | 2026-06-16 |
| Дата завершения | — |
| Тип | audit / hardening / refactoring-pass |
| Коммиты | — (ожидают ревью) |
| Полный отчёт | [`docs/research/2026-06-16-deep-code-research.md`](../../research/2026-06-16-deep-code-research.md) |
| Связанные spec'ы | §050/§128 (JNI no-throw), §072 (atomic write), §087/§119 (network reset), §089 (cohesion refactor), §116 (banner), §121 (routing-king/DNS-orphans), §026 (parser v2), §048 (home-node-filters), §070 (sort options), §140 (force-stop) |

---

## TL;DR

Multi-agent аудит всей кодовой базы (Flutter ~52k LOC + Kotlin ~3.6k LOC) по
трём осям: **стабильность · рефакторинг · энергопотребление**. 11 агентов-исследователей
→ 84 сырых находки → адверсариальная верификация против реального кода → **64
подтверждено** (26 стабильность, 22 рефакторинг, 16 энергия), 20 отсеяно как
ложные/завышенные.

**Главный вывод: кодовая база здоровая.** Критичных находок нет, потолок
серьёзности — `medium` на всех трёх осях. Подавляющее большинство — **пробелы в
уже существующих защитных контрактах** (одни call-site защищены, симметричные —
нет), а не дыры на ровном месте. Проект уже системно применяет правильные
паттерны (JNI fail-safe §050/§128, epoch-гейтинг в mass-ping, atomic write §072,
lifecycle-пауза polling в `connections_screen`/`stats_screen`).

Эта таска — **журнал находок + приоритизированный план**. Реализация — отдельными
коммитами/спеками по мере выполнения; нетривиальные пункты при необходимости
выносятся в собственные `docs/spec/tasks/NNN.md` (отмечено в таблицах).

---

## Методология аудита

- **Фаза 1 — исследование (11 агентов):** стабильность × 5 (Kotlin VPN-слой,
  Dart VPN-клиент/bridge, контроллеры, parser/builder, async/ошибки),
  энергопотребление × 3 (Dart-таймеры/polling, Kotlin native, traffic_profiler
  SSE + UI), рефакторинг × 3 (дублирование, структура/dead-code, тесты/качество).
- **Фаза 2 — адверсариальная верификация:** каждая находка проверена отдельным
  агентом-скептиком против реального кода (подтвердить evidence дословно, найти
  уже существующую защиту, проверить причинно-следственную связь, скорректировать
  серьёзность). Это понизило все исходно-`high` находки — в т.ч. **все** энергетические
  (главный «прожорливый» heartbeat работает на loopback → жжёт CPU из idle, но
  **не будит радио** = главная статья мобильной энергии).
- **Фаза 3 — синтез** в три приоритизированных раздела.

---

## Приоритеты

Находки сгруппированы по приоритету реализации (P0 → P3), не по оси. Внутри
группы — по рычагу/связности. Серьёзность (`sev`) указана после верификации.
Effort: `trivial` < `small` < `medium` < `large`.

---

## P0 — Корневые фиксы с наибольшим рычагом (делать первыми)

Несколько находок имеют общий корень; один фикс закрывает класс проблем.

### P0.1 — Блокирующий гейт fatal-валидации `[sev: medium · stability]`

| Поле | Значение |
|------|----------|
| Где | `app/lib/controllers/subscription_controller.dart` — `_generate()` (≈692-713) |
| Корень | `validator.dart:15-90` детектит все 5 fatal-классов, но результат **advisory-only**: при `hasFatal==true` функция только **логирует** issues и всё равно `return result.configJson`. Документированный контракт `validation.dart:3` («Fatal → UI отказывается запускать VPN») в коде НЕ реализован. |
| Эффект | Невалидный конфиг (dangling outbound · пустая urltest-группа · битый `dns.final` · dangling `dns.rules[].server` · detour-цикл) доезжает до `saveParsedConfig` → ядра → зацикленный фейл-старт без понятной диагностики ДО подключения + битый конфиг персистится как source-of-truth. **НЕ краш процесса** (`BoxService.startSingbox` обёрнут try/catch → graceful `stopAndAlert`). |
| Фикс | В `_generate()` при `hasFatal` не возвращать `configJson`, а пробрасывать сигнал ошибки → `generateConfig()` выставляет `_lastError` человекочитаемым перечнем `result.validation.fatal` и возвращает `null` (24+ callsite с `if (config != null)` корректно skip'нут save). Прокинуть через специализированное исключение в существующий try/catch + `humanizeError`. |
| Effort | small |
| Рычаг | **Корневой** — закрывает эксплуатируемость P1.6/P1.7/P1.8 (сейчас они логируются, но не блокируют). Делать ПЕРВЫМ. |

### P0.2 — Heartbeat не паузится в фоне `[sev: medium · energy]`

| Поле | Значение |
|------|----------|
| Где | `app/lib/controllers/home_controller/heartbeat.dart` (`_startHeartbeat`/`_checkHeartbeat`); старт `home_controller.dart:186`; resume-путь `_resyncOnResume` (≈662-680); lifecycle-хендлер `home_screen.dart:357-363` |
| Эффект | Пока VPN включён, `Timer.periodic(20s)` тикает безусловно (180×/час, foreground+background). На каждый тик — 2 loopback-HTTP (`fetchTraffic` + `fetchProxies`) + `notifyListeners`. `fetchTraffic` парсит ВЕСЬ список соединений. **Единственный always-on resident-drain.** Потолок ущерба — CPU из idle на loopback, радио НЕ будит. |
| Фикс | Сделать heartbeat lifecycle-aware: в `home_screen.didChangeAppLifecycleState` добавить ветку `paused/hidden → HomeController.onAppPaused()` → `_stopHeartbeat()`. Resume-половина уже есть (`_resyncOnResume`) — `onAppResumed` дополнить `_startHeartbeat`. Дед-туннель в фоне поймает native-broadcast путь. |
| Effort | small |
| Рычаг | Самый ценный фикс по оси энергии при минимальном риске. |

### P0.3 — Гейт `fetchProxies` по типу группы `[sev: low · energy]`

| Поле | Значение |
|------|----------|
| Где | `heartbeat.dart:53-67` |
| Эффект | `fetchProxies` нужен только чтобы поймать смену `now` у urltest-группы; при обычном Selector бесполезен, в фоне бесполезен всегда → лишний 2-й loopback-запрос каждые 20с. |
| Фикс | Гейтить по типу активной группы (`ClashApiClient.urltestNow(selectedGroup) != null`). Делать заодно с P0.2. |
| Effort | small |

---

## P1 — Стабильность (надёжность контрактов)

### P1.1 — JNI no-throw инвариант (§050/§128) применён непоследовательно `[sev: medium]`

Любой unchecked exception, пролетающий через JNI из Kotlin-колбэка в Go-ядро, =
`Runtime::Abort` всего процесса (краши старых API, Android 10). `PlatformInterfaceWrapper`
защищён — но не все колбэк-методы. Низкая вероятность, **catastrophic blast radius**.

| # | Где | Что не так | Фикс | Effort |
|---|---|---|---|---|
| a | `BoxService.kt` — `serviceReload()` (485-503), `getSystemProxyStatus()` (566-571), `setSystemProxyEnabled()` (573) | `BoxService` реализует `CommandServerHandler` (зовётся Go-ядром через JNI). `serviceReload` обёрнут `runCatching` только вокруг `cs.startOrReloadService`; внешнее тело (`notification.stop()`, `sendBroadcast`) — снаружи. Геттеры — без обёртки. | Обернуть внешние тела во внешний `runCatching` + `Log.e`; геттер возвращает пустой `SystemProxyStatus()` при сбое. | small |
| b | `DefaultNetworkMonitor.kt` — `notifySync()` (75-97) ← `setListener()` (70-73) ← JNI-колбэк `startDefaultInterfaceMonitor` | Тело НЕ обёрнуто (в отличие от соседнего `getInterfaces()` 98-103). Плюс `for(0..10){ ... Thread.sleep(50) }` блокирует Go-init-поток (worst-case ~500мс). **Прим.:** исполняется на Go-init-потоке, НЕ на main looper (исходный «риск ANR» неверен). | (1) обернуть тело в `runCatching` по паттерну `getInterfaces()`; (2) убрать `Thread.sleep`, резолвить index асинхронно через `s.launch(Dispatchers.IO)`. | medium |

### P1.2 — Гонки read/assign-after-await с disconnect-cleanup `[sev: medium→low]`

Системный класс: при tunnel-down контроллер обнуляет `_clash` и чистит state, но
in-flight async-операции читают/пишут после `await` без post-await гейта. Эталон —
`runMassUrltest` с epoch-проверкой (`ping_orchestration.dart:225/229/234`). Все
случаи self-healing (single-thread event loop), краша/порчи данных нет — transient
UI-glitch.

| # | Где | Фикс | Effort |
|---|---|---|---|
| a `[medium]` | `home_controller.dart` — `reloadProxies` (494-527), `applyGroup` (529-554), `switchNode` (556-572); `heartbeat.dart` `_checkHeartbeat` (44-67) | После КАЖДОГО await перед `_emit`: `if (!_state.tunnelUp \|\| _clash != clash) return;`. Чище — единый `connectionEpoch`, инкрементящийся во всех 3 down-путях. | small |
| b `[low]` | `cancelMassPing()` не зовётся из disconnected-ветки `_handleStatusEvent` (192-232); контраст с `heartbeat.dart` `_onTunnelDead` (87) | Добавить `cancelMassPing()` ПЕРЕД `_clash = null` (≈L201) — идемпотентно, единый контракт обоих down-путей. | trivial |
| c `[low]` | `ping_orchestration.dart` — `_scheduleAutoPing` (149-158): `_autoPingTimer=Timer(...)` после await оставляет таймер после disconnect | После await перед созданием Timer: `if (!_state.tunnelUp) return;`. | trivial |
| d `[low]` | `config_io.dart` — `saveParsedConfig` (51-106): `tunnelUp` читается до и после await → `needRestart` по устаревшему статусу | Снять снимок `final wasUp = _state.tunnelUp;` один раз (после await, консистентно с `changed`-диффом). | trivial |

### P1.3 — DefaultNetworkListener.Callback на main looper `[sev: medium]`

| Поле | Значение |
|------|----------|
| Где | `DefaultNetworkListener.kt` — `Callback` (63-67), `register()` (92-101) |
| Что не так | Все 3 `NetworkCallback` зарегистрированы с `mainHandler` → main thread, каждый `runBlocking { actor.send(...) }`. Остаточный риск: main-thread jank от `getLinkProperties`/`getByName` при пачках `onCapabilitiesChanged` (роуминг) + редкий worst-case ~1с в retry-цикле. **Прим.:** тяжёлый `updateDefaultInterface` уже offload в `Dispatchers.IO`; `Thread.sleep(100)` только в catch-ветке (исходная «цепочка 1с на main на каждый чих» преувеличена). Канонический upstream-паттерн, краша нет. |
| Фикс | Зарегистрировать `Callback` на фоновый `HandlerThread` вместо `mainHandler`; заменить `runBlocking { actor.send }` на `actor.trySend`. |
| Effort | medium |

### P1.4 — Stale `ClashApiClient` в StatsScreen/ConnectionsView после reconnect `[sev: medium]`

| Поле | Значение |
|------|----------|
| Где | `stats_screen.dart` (`StatsScreen.clash` field → `_refresh()` L115), `connections_screen.dart` (`ConnectionsView`) |
| Что не так | Экран опрашивает по снимку клиента. Reconnect при открытом экране создаёт НОВЫЙ клиент (новый порт+secret), snapshot остаётся мёртвым. **Последствие доброкачественное:** оба `_refresh()` в try/catch с mounted-гардами, lifecycle паузит таймеры в фоне → итог = stale-показ + тихий no-op close-кнопок до переоткрытия. НЕ краш/busy-loop. |
| Фикс | Передавать fetcher-closure `() => controller.clashClient` (как у `TrafficProfiler.bindRuntime`); при null показывать «tunnel down». **Исключить `PerAppTraceTab`** — его `widget.clash` нигде не разыменовывается (dead param, удалить отдельным мелким cleanup'ом). |
| Effort | medium |

### P1.5 — Гонка конкурентных `_save()` в SettingsStorage `[sev: medium]`

| Поле | Значение |
|------|----------|
| Где | `settings_storage/io.dart` — `_save()` (133-157), `_atomicSave()` (159-195, фикс. `_tmpFile()`); вызовы из `subscription_controller._persist`, AutoUpdater↔UI |
| Что не так | Два перекрывающихся `_save()` пишут в ОДИН `.tmp` → оба `tmp.rename(main)`; второй бросает `PathNotFoundException` (fire-and-forget = unhandled async). `_pendingSave=null` после первого обнуляет handle второго. **НЕ краш** (`PlatformDispatcher.onError` глотает; данные идентичны → потеря безвредна, вред = шумный лог). Тот же класс УЖЕ исправлен в `HttpCache` монотонным `_tmpSeq` — регрессия не закрыта здесь. |
| Фикс | Сериализовать цепочкой `_pendingSave.then(...)` + свежий снапшот `_cache` внутри `.then`; уникальный `.tmp`-суффикс (как HttpCache `_tmpSeq`); чистку осиротевших .tmp на glob-маску. Альтернатива — пакет `synchronized`. |
| Effort | small–medium |

### P1.6 — Валидатор не покрывает `dns.rules[].server` `[sev: medium · зависит от P0.1]`

| Поле | Значение |
|------|----------|
| Где | `builder/validator.dart` (50-69) — проверяет только `dns.final`/`route.default_domain_resolver`, итерации по `dns.rules` нет |
| Что не так | sing-box падает на старте если DNS-rule ссылается на несуществующий `server` (§121, реальный «server not found»). lifecycle-лок учитывает только routing-rule DNS, НЕ inline DNS-правила. Триггер узкий (ручное авторство inline DNS-rule + удаление сервера). |
| Фикс | В `validateConfig` итерировать `dns.rules`: `server is String && !dnsServerTags.contains(server)` → `DanglingDnsServerRef` (fatal). Опц. расширить lifecycle-лок на inline-правила. |
| Effort | small |

### P1.7 — Dangling `route.rules[].outbound` на выключенную группу `[sev: medium · зависит от P0.1]`

| Поле | Значение |
|------|----------|
| Где | `post_steps/custom_rules.dart` — `_outboundToRoute()` (525-529); UI toggle-хендлер `routing_screen.dart` (210-218) outbound правил не чистит |
| Что не так | Юзер создаёт правило `outbound=vpn-2`, затем выключает группу `vpn-2`. `_buildPresetGroups` не эмитит выключенную группу, но route-rule с `outbound: vpn-2` остаётся → dangling → фейл-старт. Нет orphan-cleanup/fallback-to-direct. |
| Фикс | (1) [покрывается P0.1] блокирующий гейт; (2) чище — маппить неизвестный outbound на `direct-out` с warning (прокинуть `knownTags` в `build_config.dart:401-406`); (3) UX — orphan-cleanup при выключении группы, симметрично DNS-orphan-cleanup. |
| Effort | medium |

### P1.8 — Прочие builder-hardening `[sev: low · зависит от P0.1]`

| # | Где | Фикс | Effort |
|---|---|---|---|
| a | `server_list_build.dart` `build()` (38-55): нет детекции циклов detour (включая self-ref) | DFS-проверка ацикличности графа detour (3-цветный обход) → `DetourCycle` (fatal); опц. в `_showOverrideDetourPicker` пропускать узлы редактируемой entry | medium |
| b | `build_config.dart` `_buildPresetGroups()` (422-423) + `validator.dart` (82-84): оба гейта `def is String` — не-строковый `default` обошёл бы оба (триггер недостижим data-driven, hardening) | Расширить на `if (def != null && (def is! String \|\| !tags.contains(def)))` | trivial |
| c | `settings_storage/sources_rules.dart` `_getServerLists()` (21-24): `.map(ServerList.fromJson)` без per-entry try/catch — одна битая запись роняет весь список | Per-entry try/catch + null-skip + `whereType`, по аналогии с `UserServer.fromJson` | trivial |

### P1.9 — Lifecycle async-колбэков и error-boundary `[sev: low]`

| # | Где | Фикс | Effort |
|---|---|---|---|
| a | `home_controller.dart` `reloadVpn()` (419-430): `Future.delayed` с `notifyListeners` без guard на dispose | Добавить `bool _disposed` (выставлять в `dispose()` перед `super`), проверять в callback — прикроет и другие async-колбэки | trivial |
| b | `home_controller.dart` `reloadVpn` (419-430): проглоченное исключение оставляет cooldown без surfacing | Обернуть в try/catch с `_emit(lastError)` по образцу start/stop, откатывать `_lastReloadTap` при неудаче | small |
| c | `main.dart`: error-boundary ставится ПОСЛЕ 4 init-await (22-37); нет `runZonedGuarded` (defense-in-depth, не текущий дефект) | Переместить `FlutterError.onError`/`PlatformDispatcher.onError`/`ErrorWidget.builder` сразу после `ensureInitialized()`, до init-await | small |
| d | `home_controller.dart` `init()` (124-131): синтетический pull `getVpnStatus` гонится с активной `_statusSub` → возможна двойная вибрация | Гейтить как `_resyncOnResume`: применять только если `pulled != _state.tunnel` | trivial |
| e | `home_controller.dart:124` (`.listen` без `onError`) + `box_vpn_client.dart:519-523` (broadcast без `.handleError`): зомби-подписка при будущем `EventSink.error` | Добавить `onError`/`.handleError` с логом (defensive hardening критического канала) | trivial |
| f | `clash_api_client.dart` `groupDelay()` (137-145): глотает non-Map как `{}`, маскируя сбой Clash (асимметрия с `delay()`/`fetchProxies()`) | Бросать `FormatException` на `j is! Map`; меняет наблюдаемое поведение → оформить мелкой task-спекой | trivial |
| g | `home_screen.dart` `initState()` (158-163): одноразовый `Timer(5s)` не сохраняется/не отменяется (mounted-guard нейтрализует — чистая гигиена) | Сохранить в `Timer? _updateCheckTimer`, `cancel()` в `dispose()` | trivial |
| h | `backup_service.dart` `applyImport()` (293-367): два отдельных write только в `merge=true` (restore-путь уже атомарен) | В `merge=true` записать одним `replaceRaw(merge=true)`; НЕ фреймить как restore-corruption баг | medium |

> **Подтверждённая сильная сторона (не трогать):** парсеры подписок устойчивы к
> битому вводу (URL/QR/base64 → null-skip, не throw). `normalizePacketEncoding`
> гасит xray-style мусор (иначе panic в libbox = краш .so). Действий не требуется.

---

## P2 — Рефакторинг и качество

Ни одного функционального бага — maintainability-долг + пробелы тестируемости.
Самое ценное — **тесты**, не дедупликация UI-кирпичей.

### P2.1 — Тестовый пробел Kotlin JNI-слоя `[sev: medium]`

| Поле | Значение |
|------|----------|
| Где | весь `app/android` (нет `src/test`/`src/androidTest`, нет тест-зависимостей); хрупкое — `PlatformInterfaceWrapper.kt`: `findConnectionOwner` (41-58), `getInterfaces` (90-103), `readWIFIState` (182), `systemCertificates` (203-218) + `WifiInfoReader` |
| Почему medium при нулевом покрытии | Документированный источник #1 крашей (Runtime::Abort, §050). Регрессия (кто-то уберёт catch / добавит бросающий вызов) пройдёт ревью, `flutter analyze` и весь Dart-набор незамеченной → всплывёт полевым крашем на недоступных устройствах. |
| Фикс | `src/test/kotlin` с Robolectric + MockK (`testImplementation(junit, robolectric, mockk)`). Целить fail-safe: `WifiInfoReader.read/readAsState`, `findConnectionOwner`, `getInterfaces`, `systemCertificates` — мокать framework-статику чтобы бросала → assert fail-safe возврат. |
| Effort | medium (мокать статику + синглтоны `BoxApplication.*` — закладывать время) |

### P2.2 — `HomeController` без DI-шва `[sev: medium]`

| Поле | Значение |
|------|----------|
| Где | `home_controller.dart:30` — `final BoxVpnClient _vpn = BoxVpnClient();`; `start/stop/reconnect` (379-477); `_onTunnelDead` (heartbeat.dart:85-116) |
| Что не так | Клиент создаётся внутри контроллера, не инжектится (в отличие от `AutoUpdater`). Инварианты state-машины (busy на reconnect, единый tunnel-down вид) не закреплены тестом → регрессия тихо ломает UX. |
| Фикс | `HomeController({BoxVpnClient? vpn, AutoUpdater? autoUpdater}) : _vpn = vpn ?? BoxVpnClient()`. Покрыть с фейк-клиентом: reconnect-делегирование, busy-удержание, единый финальный вид `_onTunnelDead` vs revoked. |
| Effort | medium |
| Прим. | `SubscriptionController` к находке НЕ относится — у него есть тест-швы и покрытие. |

### P2.3 — DRY: дублирование идиом `[sev: low]`

Реального функц.риска нет — код-гигиена + единая точка для будущих правок
(локализация §4PDA, haptic). Каждый нетривиальный → своя `docs/spec/tasks/NNN.md`.

| # | Что | Где (примеры) | Фикс | Effort |
|---|---|---|---|---|
| a | back/discard-flow двух edit-экранов | `custom_rule_edit_screen.dart` ↔ `dns_server_edit_screen.dart` (зеркальные `_handleBack`/`PopScope`/`_SaveIconButton`) | `DirtyAwareSaveAction` widget + back-guard mixin/helper (прецедент `lazy_persist_mixin.dart`) | small |
| b | `_addWarpObfuscated`/`_addWarpPlain` ~95% идентичны + хрупкий ручной re-build (молча теряет `chained`) | `subscription_controller.dart` (340-377, 380-416) | `_addWarpNode(...)` + `WireguardSpec.copyWith` (чинит потерю `chained`) + round-trip-тест | small |
| c | polling-таймер с lifecycle-awareness скопирован (энергокритичная идиома) | `connections_screen.dart` (18-83) ↔ `stats_screen.dart` (35-101); `live_events_tab.dart:67` уже БЕЗ lifecycle | `mixin LifecyclePollingMixin` (абстр. `pollInterval`/`poll()` + `restartPolling()`) | medium |
| d | нет общего хелпера SnackBar (~70 inline + 4 локальных) | 27 файлов | `extension SnackbarX on BuildContext` (через `maybeOf`), мигрировать постепенно. **НЕ как фикс use-after-dispose** | medium |
| e | копипаст «Clipboard.setData + Copied-снэк» (17-21 файлов) | `node_actions.dart`, `config_screen.dart`, … | `copyToClipboard(text, {toast})` (`if(!context.mounted) return` после await); не трогать `url_launcher.dart:16` | medium |
| f | 5 `_editX` identity-настроек (общий ~6-строчный хвост) | `app_settings_screen.dart` (490/516/536/549/562) | closure-based `_commitIdentityField(...)` + пропущенный `mounted`-check | small |
| g | UserServer-boilerplate (6 копий 8-арг конструктора) | `subscription_controller.dart` (469/492/512/573 + WARP 363/402) | `_buildPasteEntry({rawBody, nodes})` без внутр. persist | small |
| h | `_disposed`-guard в 3 контроллерах | `custom_rule_edit`, `dns_server_edit`, `node_filter_view_model` | `abstract class DisposableNotifier` (`isDisposed`/`safeNotify()`); НЕ для app-scoped синглтонов | small |
| i | InheritedNotifier Scope-классы копипаст | `CustomRuleEditScope` ↔ `DnsServerEditScope` | **Quick win:** удалить мёртвый `CustomRuleEditScope.read()` (0 call-sites); полное извлечение опц. (2 инстанса) | small |

### P2.4 — Структура / dead code / magic numbers `[sev: low]`

| # | Что | Где | Фикс | Effort |
|---|---|---|---|---|
| a | `_formatBytes` расходится с каноном (нет GB-разряда) | `connections_screen.dart:333-337` | импорт `format_utils` / флаг `shortUnit` | trivial |
| b | dead code: `_tunPacketRe` (no-op парсер) | `traffic_profiler.dart:540-541, 571-576` | удалить (behavior-preserving); **НЕ как энергофикс** | trivial |
| c | dead fields `_DnsAccumulator` (`ips`/`lastResolvedName`/`firstTs`) | `traffic_profiler/internal.dart:13-23` | удалить поля+записи; `firstTs` оставить ctor-параметром для `lastTs` | trivial |
| d | magic numbers диапазона Debug API-портов (3 места) | `app_settings_screen.dart:252`, `settings_storage.dart:430`, `diagnostics_tab.dart:214` | `static const debugPortMin/Max` в `SettingsStorage` | trivial |
| e | MethodChannel-имена захардкожены (6+ мест) | `logcat_reader`, `exit_info_reader`, `action.dart:390`, `box_vpn_client.dart:55`, `url_launcher`, `wifi_history_listener` | `platform_channels.dart` с константами (прецедент `method_names.dart`); прибрать и Kotlin `MainActivity.kt:84,88` | trivial |
| f | `Share.shareXFiles` deprecated под 3 ignore | `debug_screen.dart:85,109`, `config_screen.dart:55` | мигрировать на `SharePlus.instance.share(...)` **вместе с апгрейдом** `share_plus` 10→13 | small |

### P2.5 — Длинные функции / широкая mutable-поверхность `[sev: low]`

Делать ТОЛЬКО в связке с unit-тестами на извлечённые helper'ы, иначе косметика
(поведенческое покрытие уже есть). Уважать §089 (cohesion-over-line-count).

| # | Что | Где | Фикс | Effort |
|---|---|---|---|---|
| a | god-метод `_load()` (~188 строк) | `dns_settings_screen.dart:115-302` | вынести в `DnsSettingsData.load(...)` (immutable + флаг `resolverReset`); опц. под-helper'ы | medium |
| b | 12+ слабосвязанных map/list полей State (только в связке с `a`) | `dns_settings_screen.dart:58-104` | один `DnsSettingsData _data` + 3 скаляра (по образцу `NodeFilterViewModel`) | medium |
| c | god-метод `_pollConnections` (~167 строк) | `traffic_profiler.dart:906-1073` | `_extractConnFields`/`_resolveSnapshotMeta`/`_emitClosedConnections` + unit-тесты | medium |

---

## P3 — Энергопотребление (после P0.2/P0.3)

Native (Kotlin) **не добавляет своих таймеров/polling/wakelock'ов** — piggyback
на системных событиях. Почти всё ниже — opt-in диагностика или foreground-only
неэффективности (Flutter паузит vsync в фоне). Critical/High по этой оси нет.

### P3.1 — TrafficProfiler / UI-перерисовки `[sev: medium]`

| # | Что | Где | Фикс | Effort |
|---|---|---|---|---|
| a | `_appendEvent` зовёт `notifyListeners()` на КАЖДОМ event без throttle | `traffic_profiler.dart:1128-1137` (эталон `app_log.dart:208-233`) | `_scheduleNotify()` (16ms leading-edge) по образцу `AppLog`. Foreground-оптимизация активной диагностики | small |
| b | `LiveEventsTab._onEvent` пересобирает весь буфер (до 3000) на каждый SSE-event → O(K·N) на бёрсте | `live_events_tab.dart:100-117, 128-157` | парсить входящий `TrafficEvent` из `msg['data']`, инкрементальный append + trim 3000; коалесить бёрсты (`_dirty` + один `setState`); кешировать `_filtered` | medium |
| c | TrafficProfiler не паузится в фоне (Clash poll 5s + парсинг + GC 5s) — забытая запись жжёт батарею | `traffic_profiler.dart:886-918, 174-190` (§048 «recording в фоне») | Корень — **авто-стоп забытой записи**: на `paused/hidden` таймер ~10 мин → `stopGlobalRecording()`; на `resumed` отмена. Через существующий observer в `home_screen`. Приостановка `_connTimer` меняет §048 → нужно продуктовое решение | medium |

### P3.2 — Диагностические таймеры / native hot-path `[sev: low]`

| # | Что | Где | Фикс | Effort |
|---|---|---|---|---|
| a | `_ticker` 1с ребилдит весь build() таба ради метки «Recording» | `per_app_trace_tab.dart:74-77`, `live_events_tab.dart:67-69` | вынести метку в узкий `StatefulWidget`/`ValueListenableBuilder` | small |
| b | GC-таймер 5s + Clash poll 5s — два независимых `Timer.periodic` | `traffic_profiler.dart:454-456, 886-891` | слить GC в `_pollConnections` (ДО early-return!) или поднять `_connIdGcInterval` до 10-15с | trivial |
| c | `writeDebugMessage` гоняет 2 regex до null-sink проверки | `BoxService.kt:592-608` | переставить null-sink guard первой строкой | trivial |
| d | TD-119-1: безусловный `Log.i` + лишний `getLinkProperties` на каждый network update | `DefaultNetworkMonitor.kt:171-181` | загейтить `Log.isLoggable`, передавать уже вычисленный `ifName` | trivial |
| e | `checkUpdate` с `Thread.sleep` (только в catch) на main looper — UI-jank, не energy | `DefaultNetworkListener.kt:65,99-127` | де-дуп по `interfaceName`; перенести тело на `Dispatchers.IO` (см. P1.3) | medium |
| f | 2 NetworkCallback при wifi-history — `WifiManager.connectionInfo` (binder-IPC) до дедупа | `WifiNetworkObserver.kt:42-82` | кешировать последний `Network`, short-circuit ДО `readWifi()` | medium |
| g | `_drainNewLogEntries` копирует core-буфер на каждый notify AppLog | `traffic_profiler.dart:431-439, 494-512` | head-timestamp/seq в `AppLog` чтобы бейлить ДО `entriesForSource` | medium |
| h | `BG_MODE_ALWAYS` подписан на SCREEN_ON/OFF без debounce (opt-in, нетто-положительный) | `BoxService.kt:110-117, 156-166` | `runCatching` вокруг `pause()/wake()` (§050-safety); лёгкий debounce | small |

---

## Журнал реализации (2026-06-17)

Реализация по приоритетам с предварительной верификацией находок против текущего
дерева (отчёт писался 16.06, координаты в плане устарели — реальные пути:
`services/builder/`, не `builder/`). Все правки: `flutter analyze lib/ test/` чисто,
**1150 тестов passed** (+10 новых).

### ✅ Сделано

| # | Что сделано | Файлы |
|---|---|---|
| P0.1 | `_generate` бросает `FatalValidationException` при `hasFatal` → `generateConfig`-catch выставляет `_lastError`, возвращает `null` → save не происходит. Новый класс исключения с humanize-совместимым `toString` | `models/validation.dart`, `controllers/subscription_controller.dart` |
| P0.2 | Heartbeat lifecycle-aware: `onAppPaused()` → `_stopHeartbeat()`; resume рестартует + немедленный тик. `paused`/`hidden` ветка в `didChangeAppLifecycleState` | `home_controller.dart`, `home_controller/heartbeat.dart`, `screens/home_screen.dart` |
| P0.3 | `fetchProxies` гейтится `_activeGroupIsUrltest()` (по снимку `proxiesJson`+`selectedGroup`); консервативно: при неизвестном типе fetch не пропускается | `home_controller/heartbeat.dart` |
| P1.1a | JNI no-throw: `serviceReload`/`getSystemProxyStatus`/`setSystemProxyEnabled` — внешнее тело в `runCatching` + fail-safe | `BoxService.kt` |
| P1.1b | `notifySync` обёрнут в `runCatching` (fail-safe «нет интерфейса»). `Thread.sleep` оставлен осознанно (async-рефактор — отдельная device-verified задача) | `DefaultNetworkMonitor.kt` |
| P1.2a | Post-await guard (`_clash != clash \|\| !tunnelUp → return`) в `reloadProxies` и `_checkHeartbeat` | `home_controller.dart`, `heartbeat.dart` |
| P1.2b | `cancelMassPing()` в disconnected/revoked-ветке `_handleStatusEvent` (симметрия с `_onTunnelDead`) | `home_controller.dart` |
| P1.2c | Post-await `if (!tunnelUp) return` перед созданием `_autoPingTimer` | `ping_orchestration.dart` |
| P1.5 | Монотонный `_tmpSeq` → уникальный tmp per-save (убирает `PathNotFoundException` на гонке); `_sweepOrphanTmp` по glob-маске | `settings_storage.dart`, `settings_storage/io.dart` |
| P1.8a | Detour-cycle detection (3-цветный DFS) + `DetourCycle` fatal — ловит self-ref и цепные циклы | `validator.dart`, `validation.dart` |
| P1.8b | Non-string `default` ловится в build_config (remove) + validator (`InvalidDefault`) | `build_config.dart`, `validator.dart` |
| P1.8c | Per-entry try/catch в `_getServerLists` — битая запись skip'ается, не роняет весь список | `settings_storage/sources_rules.dart` |
| P1.9a | `bool _disposed` (в `dispose()` до super) → гейт delayed-колбэка `reloadVpn` | `home_controller.dart` |
| P1.9b | `reloadVpn` try/catch с `_emit(lastError)` + откат cooldown; error-boundary в `main.dart` поднят до init-await, init обёрнут try/catch | `home_controller.dart`, `main.dart` |
| P1.9d | `.handleError` на status-broadcast перед `asBroadcastStream` (анти-зомби) | `box_vpn_client.dart` |
| P1.9f | `_updateCheckTimer` сохраняется и отменяется в `dispose` | `home_screen.dart` |
| P2.3i | Мёртвый `CustomRuleEditScope.read()` удалён (0 call-sites) | `custom_rule_edit/edit_controller.dart` |
| P2.4a | `_formatBytes` → канон `formatBytes` (B/KB/MB/GB) | `connections_screen.dart` |
| P2.4b | Мёртвый `_tunPacketRe` + no-op ветка удалены | `traffic_profiler.dart` |
| P2.4c | Только `lastResolvedName` удалён (write-only). **`ips`/`cnameChain`/`firstTs` оставлены — реально используются** (находка аудита была неверна) | `traffic_profiler/internal.dart`, `traffic_profiler.dart` |
| P2.4d | `debugPortMin`/`debugPortMax` const, переиспользованы в 3 местах | `settings_storage.dart`, `app_settings_screen.dart`, `diagnostics_tab.dart` |
| P2.4e | `platform_channels.dart` с `PlatformChannels`-константами; мигрированы все 6+ Dart call-sites (Kotlin-сторона НЕ тронута) | новый `services/platform_channels.dart` + 7 файлов |
| P3.1a | Leading-edge 16ms-throttle `_scheduleNotify` для `_appendEvent` (эталон `AppLog`); stream-эмит остаётся per-event | `traffic_profiler.dart` |
| P3.2b | GC-интервал 5s→15s (TTL=30s, развод фазы с poll-таймером) | `traffic_profiler.dart` |
| P3.2c | Null-sink guard первой строкой в `writeDebugMessage` (до 2 regex) | `BoxService.kt` |

**Новые тесты:** 7× detour-cycle/non-string-default (`validator_test.dart`), 2×
`FatalValidationException`-контракт, 1× конкурентные `_save()` без сирот/throw
(`settings_storage_test.dart`).

### ⏸ Отложено (своя спека / device-verify / меняет наблюдаемое поведение)

| # | Почему |
|---|---|
| P1.3 | Callback на main looper — канонический upstream-паттерн, агент-верификатор пометил `risky`; перенос на HandlerThread меняет тайминг сетевых событий, дефекта нет (лишь «остаточный риск»). Device-verified задача. |
| P1.9e | `groupDelay` глотает non-Map как `{}` — **меняет наблюдаемое поведение**, в плане помечен «своя task-спека». Не делаю молча. |
| P2.2 | DI-шов `HomeController` — крупный (меняет конструктор + `home_screen` создание); нужен для unit-тестов P0.2/P1.2, но сам needs-care. Отдельно. |
| P2.3b | `_addWarpObfuscated`/`_addWarpPlain` DRY — needs-care (требует `WireguardSpec.copyWith` + round-trip тест чтобы не потерять `chained`). |
| P2.4f | `Share.shareXFiles` — требует апгрейда `share_plus` 10→13 (мажор). Отдельная dep-работа. |
| P3.1b, P3.2a/e/f/g/h, P2.5, P2.3a/c/d/e/f/g/h | Medium-effort рефактор/энергия — делать в связке с тестами на извлечённые helper'ы (иначе косметика); вне текущего безопасного прохода. |

### ⊘ Скип (находка неверна / не-цель)

| # | Почему |
|---|---|
| P1.4 | Агент опроверг: `widget.clash` фетчится свежим на каждый poll (immutable ctor-param), не stale. `PerAppTraceTab.clash` активно используется (не dead param). |
| P1.2d | `needRestart` уже использует **один** post-await снимок `tunnelUp` в точке решения — корректно. Захват pre-await `wasUp` (как в плане) был бы **регрессией** (туннель мог лечь во время save). |
| P1.9c/h | Синтетическая вибрация в `init()` не найдена в коде (stale-находка). |
| P3.2d | Безусловный `Log.i` в `DefaultNetworkMonitor` — **намеренный** tech-debt (TD-119-1): диагностика незакрытого field-report §119, убирать до подтверждения фикса нельзя. |
| P2.4c (часть) | `ips`/`cnameChain`/`firstTs` — НЕ мёртвые (см. ✅ выше). |

### Не покрыто тестами (verify on-device при ревью)

P0.2/P0.3 (heartbeat lifecycle/gating), P1.1a/b (Kotlin JNI), P1.9 (lifecycle
guard'ы) — нет DI-шва (P2.2) / Kotlin-тестов (P2.1). Логика прошла `analyze`;
on-device проверка по «Плану верификации» ниже. **Kotlin не компилировался
локально** (нет полного Android SDK — `sdk.dir` = platform-tools); собрать через
`build-local-apk.sh`.

---

## Скоуп / нецели

**В скоупе таски:** журнал всех 64 подтверждённых находок + приоритизированный
план. Реализация пунктов — по мере выполнения, отдельными коммитами/спеками.

**Нецели (не трогать как «фиксы»):**
- Удлинять 20с-интервал heartbeat — он же dead-tunnel detection (`_maxHeartbeatFailures`).
- Менять поведение §048 «recording продолжается в фоне» без продуктового решения.
- Считать `BG_MODE_ALWAYS` «разрядом» — механизм энергию **экономит** (`SCREEN_OFF→pause()`).
- Расщеплять документированные крупные исключения §089 без пользы (`traffic_profiler`,
  `custom_rule`, `VpnPlugin.kt` — целостны намеренно).
- Натягивать DRY-хелперы за пределы rule-of-three (`ScopedNotifier` 2 инстанса,
  `KeyValueRow` 2 неидентичных сайта).
- Парсеры подписок — подтверждённая устойчивость, действий не требуется.

---

## План верификации (при реализации)

| Пункт | Как проверить |
|---|---|
| P0.1 | Regression-тест: при `hasFatal` `saveParsedConfig`/`saveConfig` НЕ вызывается, `_lastError` содержит перечень fatal. Manual: dangling outbound → VPN не стартует, видна понятная ошибка. |
| P0.2/P0.3 | Manual on-device: VPN on → свернуть app → убедиться (Debug API / logcat) что heartbeat-тик не идёт; resume → тик возобновился. Замер: батарея за N часов фон до/после (опц.). |
| P1.1 | После P2.1 — unit-тест Kotlin: мокнутый thrower в колбэке → нет abort, fail-safe возврат. |
| P1.2 | Unit (после P2.2): disconnect во время in-flight reload → state не перезаписывается мёртвой сессией. |
| P1.5 | Unit: два конкурентных `setVar(flush:true)` → нет `PathNotFoundException`, оба значения на диске. |
| P1.6/P1.7/P1.8 | Builder-тесты: dangling dns-server / outbound на выкл. группу / detour-цикл → fatal issue (после P0.1 — блокирует save). |
| P2.x | `flutter analyze lib/ test/` чисто; новые unit-тесты на извлечённые helper'ы зелёные; smoke build. |
| P3.x | Manual: запустить recording → свернуть на >10 мин → авто-стоп сработал. Live tab при бёрсте → один rebuild на poll-tick (profiler counters). |

Обязательные релизные сценарии (из `DEVELOPMENT_GUIDE.md`) — без регрессий:
чистая установка · offline · все подписки disabled · все ноды excluded.

---

## Docs to update (при реализации)

`[deferred till implementation]` — таска сейчас только план, кода нет.

- `CHANGELOG.md` — по факту каждого user-visible фикса (Unreleased).
- `docs/ARCHITECTURE.md` — если P1.5 (serialized save) / P2.5 (DnsSettingsData) /
  `platform_channels.dart` меняют контракты между модулями.
- `docs/api/debug-api-reference.md` — только если добавятся debug-endpoints для
  тестирования (по образцу §140).
- `pubspec.yaml` version + `RELEASE_NOTES.md` — на bump (patch для фиксов).
- Связанные spec'ы (§050/§128, §072, §087, §121, §048) — добавить cross-ref на
  эту таску при реализации соответствующих пунктов.

---

## Нерешённое / follow-up

- Полный список с дословными evidence, цитатами кода и reasoning верификации —
  в [`docs/research/2026-06-16-deep-code-research.md`](../../research/2026-06-16-deep-code-research.md).
- 20 отсеянных при верификации находок (false-positive / завышенная серьёзность)
  НЕ включены — если всплывут повторно, сверяться с reasoning в отчёте.
- Пункты с пометкой «своя task-спека» (P2.3, P1.8f groupDelay) выносятся отдельно
  при начале работы — по правилу проекта «нетривиальный рефактор → `NNN.md`».
