# 740 — Архитектурная ревизия: зоны ответственности и подготовка границы «сервис VPN / UI»

| | |
|---|---|
| **Статус** | Done — код и документация в develop; на устройстве не проверялось (перенос кода) |
| **Дата** | 2026-11-17 |
| **Повод** | Слово владельца 17.11.2026: давно не было архитектурной ревизии; привести код и `ARCHITECTURE.md` в соответствие, готовясь к будущему разделению на два процесса (сервис VPN и Dart-UI). Само разделение сейчас не делается. |
| **Связанные** | [089 — cohesion over line count](089-deep-refactor-no-monsters.md), [291F — фасады слоёв](291F-layered-architecture-facades/), [122F — CommandClient](122F-commandclient-migration/), [707 — где живут настройки](707-taildrop-send-receive-files.md), аудит 591 |

## Главное правило

**Поведение не меняется.** Меняется только внутреннее устройство: расположение
кода, границы файлов, точки доступа. Имена каналов, имена нативных методов,
ключи prefs, формат хранилища и бэкапа, строки интерфейса, порядок
инициализации — прежние. Найденные по дороге дефекты поведения не чинятся
здесь, а записываются в раздел «Найдено, не исправлено».

## Диагностика (разведка 17.11.2026)

### Граница «сервис VPN / UI» в Kotlin

Процесс один, и код этим пользуется: стороны общаются через статику.

1. В `BoxVpnService.companion` лежат объекты Flutter-движка: `coreLogSink` и
   10 `cc*Sink` (`EventSink`). Пишет `VpnPlugin`, читает `BoxService` и
   `BoxCommandClient`. `EventSink` через границу процессов не передаётся.
2. Там же `openConnectOpenRequest` / `taildropOpenRequest` — их и пишет
   (`MainActivity`), и читает (`VpnPlugin`) только UI; к сервису они не относятся.
3. Сервисная сторона зовёт статику UI напрямую:
   `VpnPlugin.handleAutomationAction` (из `LxBoxIntentReceiver`,
   `LocaleSettingReceiver`), `VpnPlugin.notifyStopRequested` (из
   `BoxVpnService.stop()`).
4. `SharedPreferences`: 36 вызовов `getSharedPreferences`; `boxvpn_boot` — 32
   дубля в `BootReceiver` при существующем `prefs()`; `lxbox_automation` — три
   разрозненных вызова и константа, объявленная дважды. `ARCHITECTURE.md`
   утверждает, что файлов prefs два; их три.
5. `BoxApplication.onCreate` смешивает шаги сервиса, UI и общие.
6. `BoxService.commandClient` (статика) читают ~70 мест с обеих сторон;
   `BoxVpnService.currentStatus` — ~25 мест. Process-global вызовы `Libbox.*`
   (`setQuicGSO…`, `reloadSetupOptions`, `setLocale`, pprof) идут из `VpnPlugin`.
7. Уже процессо-безопасно: команды сервису (Intent / broadcast с `setPackage`),
   `BROADCAST_STATUS`, сокет `command.sock`, файлы, будильник `VpnWatchdog`.

### Dart-мост

1. Реестр имён каналов есть (`PlatformChannels`), но лежит в `services/`, а не
   в `vpn/`; канал и viewType редактора Sora — строковые литералы мимо реестра.
2. `vpn/cc_channel.dart` (2192 строки) — две вещи в одном файле: синглтон-канал
   (~930 строк) и 30 DTO (~1230 строк). Имена нативных методов `CcChannel`
   (~45) — литералы по коду; у `BoxVpnClient` реестр имён есть.
3. 18 файлов `screens/` и `widgets/` зовут `BoxVpnClient` / `CcChannel`
   напрямую при заявленном правиле «UI не трогает Platform».

### Слои Dart

Мёртвых файлов нет. Нарушения направления сверх двух записанных:

- `services/` → `screens/`, `widgets/`: `dns_controller` (резолвер экрана DNS,
  `OutboundOption`), `debug/handlers/chains` (три чистых файла редактора
  цепочек), `debug/handlers/taildrop` (`exit_node_store`).
- `services/` → `controllers/`: 17 импортов в 12 файлах (debug, core_reject,
  auto_updater, direction_mutations, `ParseEnvSnapshot`).
- UI-код в нижнем слое: `services/ui_helpers.dart`,
  `services/app_theme_seed.dart`, `services/l10n/template_aware_state.dart`,
  `services/nav/home_return_observer.dart`; `models/home_state.dart` тянет
  `material.dart` ради иконок `NodeSortMode`.
- `models/` ↔ `services/` (43 / 334 импорта) — цикл внутри одного слоя.

### Крупные файлы против «cohesion over line count»

| Файл | Строк | Вердикт |
|---|---|---|
| `services/lx_backup.dart` | 4891 | Пять стадий (модели, экспорт, декодер 0.x, декодер 1.0, слияние) в одной библиотеке без `part`; состояния нет — режется механически |
| `controllers/subscription_controller.dart` | 4002 | CRUD, операции с папками, сборка, фетч в одном классе; операции с папками трогают только `_entries` / `_busy` — отделяются |
| `controllers/home_controller.dart` | 2235 | Один автомат вокруг `_state`; периферия (граф зависимостей, выбор узла) отделяется миксинами по прецеденту |
| `vpn/cc_channel.dart` | 2192 | См. выше: DTO в `part` |
| `services/settings_storage.dart` | 1374 | Уже поделён на 11 `part`; не трогать |
| `vpn/box_vpn_client.dart` | 1181 | Тонкий типизированный фасад; не трогать (DTO в `part`) |

### Документ архитектуры

Раздел «The source tree» отстал: базовые имена 352 из 578 файлов в нём не
встречаются, три упомянутых файла не существуют, цифры строк устарели.

## План

Пять пакетов с непересекающимися наборами файлов, затем документация.

### A. Kotlin: шов «сервис / UI»

- `vpn/UiSinks.kt` — `coreLogSink` и все `cc*Sink` уезжают из
  `BoxVpnService.companion`.
- `vpn/UiLaunchRequests.kt` — `openConnectOpenRequest`, `taildropOpenRequest`.
- `vpn/AutomationBridge.kt` — `handleAutomationAction`, `notifyStopRequested`,
  `sendAutomationBroadcast`, `bridgeChannel`, `appContext`; `VpnPlugin`
  регистрируется в мосте при attach / detach.
- prefs: `vpn/AutomationCache.kt` — единая точка `lxbox_automation`;
  `BootReceiver` ходит через свой `prefs()`.
- `BoxApplication.onCreate` → `initCommon()` / `initServiceSide()` /
  `initUiSide()`, порядок шагов прежний.

### B. Dart: мост `vpn/`

- DTO `cc_channel.dart` → `part`-файлы `vpn/cc_channel/models_*.dart`.
- Имена нативных методов `CcChannel` → `part` `vpn/cc_channel/method_names.dart`.
- `MemoryInfo`, `CoreCheck` → `part` `vpn/box_vpn_client/models.dart`.
- `services/platform_channels.dart` → `vpn/platform_channels.dart`; в реестр
  добавляются viewType и префикс канала редактора Sora.

### C. Dart: направление зависимостей

- Чистый код, поднятый в UI, спускается: резолвер DNS-серверов и
  `resolved_server` → `services/dns/`; `OutboundOption` → `models/`; три файла
  `chain_edit/chain_*` → `services/`; `ParseEnvSnapshot` → `services/`.
- UI-код, лежащий внизу, поднимается: `ui_helpers`, `app_theme_seed`,
  `template_aware_state`, `home_return_observer` → `widgets/`;
  иконки `NodeSortMode` → extension в UI.
- Неиспользуемые импорты контроллера в `services/debug` — убрать, если
  анализатор подтвердит.

### D. `lx_backup.dart` → `part`-файлы по стадиям

`lx_backup/{constants,models,export,decode_0x,decode_10,merge}.dart`; в главном
файле остаются импорты, вход в разбор, фильтр целей импорта и общие
приведения типов. Публичный API прежний.

### E. Контроллеры

- `subscription_controller/folder_ops.dart` — операции над папками и членами;
  `subscription_controller/link_notice.dart` — `NodeLinkSubject`, `NodeLinkNotice`.
- `home_controller/dependency_health.dart`, `home_controller/node_selection.dart`
  — миксины по прецеденту `_PingMixin`.
- Автомат статусов, старт / стоп, `_generate`, `_fetchEntryByRef` не трогаются.

### F. Документация

`ARCHITECTURE.md`: новый раздел о границе процессов (что уже пересекает её
безопасно, что ещё нет, правила для нового кода), актуальные нарушения слоёв,
таблица крупных файлов, раздел «The source tree» и число файлов prefs.

## Не делается (следующие этапы)

- Kotlin: фасад `ServiceState` над `currentStatus` и пр.; провайдер
  `CommandClientRef` вместо `BoxService.commandClient`; разрез
  `VpnPlugin.onMethodCall` на обработчики; `CoreControl` для process-global
  вызовов `Libbox.*`; `ConfigManager.cachedConfig`.
- Dart: фасады для 18 UI-файлов, зовущих мост напрямую (решение о правиле — за
  владельцем); `services` → `controllers` через интерфейсы; цикл
  `models` ↔ `services`; `AppLog` за интерфейсом для `vpn/`.
- Само разделение на процессы.

## Найдено, не исправлено

- `VpnPlugin.onDetachedFromEngine` не обнуляет `ccTailscalePingSink` и
  `ccConnectionTestSink` (остальные cc-sink'и обнуляет).

## Проверка

- `flutter analyze` — новых замечаний 0 (база 19).
- Тесты затронутых областей локально, полный набор — CI на `develop`.
- Kotlin: `compileDebugKotlin` и существующие unit-тесты.
- Поведенческой проверки на устройстве не требуется по построению (перенос
  кода); сборка APK — CI.

## Итог

- **A. Kotlin.** `UiSinks` (`coreLogSink` + 10 `cc*Sink`), `UiLaunchRequests`,
  `AutomationBridge` (`handleAutomationAction`, `notifyStopRequested`,
  `sendAutomationBroadcast`; сервисная сторона больше не зовёт статику
  `VpnPlugin`), `AutomationCache` — единая точка `lxbox_automation`;
  `BootReceiver` ходит через свой `prefs()`. `getSharedPreferences` в Kotlin —
  3 вызова (по одному на файл). `BoxApplication.onCreate` разложен на функции
  сторон, порядок шагов прежний.
- **B. Мост `vpn/`.** `cc_channel.dart` 2192 → 958 строк + `cc_channel/models_{tailscale,status,traffic,probe}.dart`
  и `cc_channel/method_names.dart` (`_CcMethods`, 57 имён);
  `MemoryInfo`/`CoreCheck` → `box_vpn_client/models.dart` (`box_vpn_client.dart`
  1181 → 1121); `PlatformChannels` → `vpn/platform_channels.dart` с viewType и
  префиксом канала Sora.
- **C. Слои.** `dns_server_resolver`, `resolved_server` → `services/dns/`; три
  `chain_*` → `services/chains/`; `OutboundOption` → `models/`;
  `ParseEnvSnapshot` → `services/parser/`; `ui_helpers`, `app_theme_seed`,
  `template_aware_state`, `home_return_observer` → `widgets/` (каталог
  `services/nav` исчез); иконки `NodeSortMode` → `NodeSortModeIcon` в UI.
  Остаток долга (импорт `services` → `screens` в `debug/handlers/taildrop`, 16
  импортов `services` → `controllers`, цикл `models` ↔ `services`, 28 UI-файлов
  с прямым вызовом моста) записан в `ARCHITECTURE.md`.
- **D.** `services/lx_backup.dart` 4891 → 1041 строка + 6 `part`-файлов по стадиям.
- **E.** `subscription_controller.dart` 4002 → 3000 (+ `folder_ops.dart`,
  `link_notice.dart`); `home_controller.dart` 2235 → 2029 (+
  `dependency_health.dart`, `node_selection.dart`).
- **F.** `ARCHITECTURE.md`: раздел «Process boundary: VPN service side vs UI
  side», нарушения слоёв, таблица крупных файлов, «The source tree», три файла
  prefs; `STORAGE.md` — число файлов prefs.

Отступления от плана:

- `BoxApplication.onCreate` — пять функций (`initCommon`, `initServiceSideEarly`,
  `initUiSide`, `initCommonWifiCache`, `initServiceSide`) вместо трёх: стороны
  чередуются, а порядок шагов менять нельзя.
- «Неиспользуемые» импорты контроллера в `services/debug` оказались
  используемыми (`SubscriptionEntry`) и остались.
- Набор общих помощников в главном `lx_backup.dart` шире запланированного:
  декодер 1.0 переиспользует части декодера 0.x.

## Docs to update

- эта задача ✓
- [ARCHITECTURE.md](../../ARCHITECTURE.md) — пакет F ✓
- `CHANGELOG.md` — none (пользователю не видно)
