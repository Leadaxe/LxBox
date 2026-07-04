# §236 — Test servers в папке (headless probe + пороги + массовые действия)

> **СТАТУС: РЕАЛИЗОВАНО, device-verified** (04.07.2026, CPH2411 dev.14).
> Device-прогон папки «test» (VPN off, 14 нод): 10 ok (VLESS 97мс, AWG
> 49–135мс, plain WARP 80мс, MASQUE «in» 189мс) / 4 failed (MASQUE QUIC
> `context deadline exceeded` — честный LTE-DPI-результат, НЕ SERVFAIL-баг).
> Через `POST /folders/{id}/probe` (§238); API отзывчив во время теста.
> Тесты:
> `test/probe/probe_test.dart` (+bulk-ops в `test/subscription/folder_test.dart`).
> Источник — 4PDA: NeoCat #562/#754/#758
> (пинг пачки при добавлении БЕЗ запущенного VPN, ручные пороги с цветовой
> шкалой, отсев тормозных), serborkr #568 (удалять недоступные после теста).
> Решение юзера: честный тест через headless-инстанс ядра (не TCP-probe).

## Зачем

Весь пинг сегодня — urltest через CommandClient **работающего** ядра: нужен
запущенный VPN и нода уже в конфиге. Сценарий «добавил пачку серверов →
сразу проверил → выкинул мусор» невозможен. Папка §234 — идеальное место:
per-member toggle/delete уже есть.

## Архитектура probe

### Ограничение, диктующее модель

`command.sock` создаётся в глобальном `basePath` (`Libbox.setup` — один раз
на процесс) → **два CommandServer одновременно невозможны**. Поэтому два
режима теста:

| Состояние VPN | Механика | Кто тестируется |
|---|---|---|
| **Выключен** | probe-сессия: временный `CommandServer` (без tun) + probe-конфиг | **все** члены папки, включая выключенных |
| **Запущен** | существующий `ccUrlTestOutbound` через боевое ядро | только включённые (они в конфиге); выключенные → вердикт `enable to test` |

Тест при запущенном VPN честный: outbound-dial ядра protected → мимо tun.

### Probe-сессия (native, VPN выключен)

`ProbeSession` (Kotlin object, НЕ Android-сервис):

```
start(configJson):
  guard: tunnelAlive == false, иначе error "vpn running"
  cs = CommandServer(probeHandler, probePlatform)   // probePlatform: без tun,
  cs.start()                                        // protect no-op, notification no-op
  cs.startOrReloadService(configJson, OverrideOptions())
  client = CommandClient(NoOpHandler, options без подписок); client.connect()
urlTest(tag, link, timeoutMs) → {delay, error}      // client.urlTestOutbound (SPEC 014,
                                                    // Variant B: error в результате)
stop():
  client.disconnect(); cs.closeService(); cs.close()
```

- **Mutual exclusion**: старт VPN при живой probe-сессии → сначала
  `ProbeSession.stopAndAwait()` (VPN приоритетнее). Probe при живом VPN не
  стартует (гейт на native — источник истины `tunnelAlive`).
- Все JNI-колбэки handler'ов — `runCatching` (JNI-no-throw).
- MethodChannel-кейсы в `VpnPlugin`: `probeStart{config}` / `probeUrlTest{tag,
  link, timeoutMs}` / `probeStop`. Конкурентность мэсс-теста — на Dart-стороне
  (пул ~6 параллельных вызовов), ядро меряет по одному synchronous+stateless.

### Probe-конфиг (Dart)

Мини-билдер `buildProbeConfig(FolderServers)` (НЕ общий buildConfig — без
каналов/правил/inbound'ов):

- outbounds/endpoints: каждый член через существующий `NodeSpec.getEntries`
  (detour-цепочки члена сохраняются — тестируем то, чем реально ходим);
  **все члены включены**; теги голые (без folder tag_prefix — сессия локальная).
- `dns`: `{servers:[{type:local, tag:local}]}` + `route.default_domain_resolver:
  local` (адреса серверов бывают доменами).
- `inbounds`: НЕТ (openTun не вызывается — §119-путь). `log.level: error`.
- Член с `node == null` (не парсится) в конфиг не попадает → вердикт сразу
  **broken** («can't parse»). Член, чей emit бросил → **invalid**.
- Detour-политика папки к probe НЕ применяется (тестируем ноды, не маршрут
  канала; override-detour цели может не быть в probe-конфиге).

## UI (folder detail → вкладка Servers; rework по device-фидбэку 04.07)

- **Контрольная полоса** над списком (паттерн главного экрана):
  `инфо · [⋮ actions] · кнопка теста · кнопка фильтра`.
  - Кнопка теста = `Icons.speed` / `stop_circle_outlined` (консистентно с
    mass-ping главного); тап = старт/отмена, **long-press = настройки теста**
    (Ping URL & timeout — глобальные `ping_options`; Ping color thresholds).
  - Кнопка фильтра = `Icons.filter_list` (+primary/точка при активном) →
    панель фильтра: **regex + протокол-чипы** (виджеты §048/§095 главного);
    при активном фильтре drag-reorder выключен (индексы вида ≠ состава).
- У каждого члена — бейдж по мере результатов: `123 ms` цветом шкалы, `err`
  (красный, **тап по бейджу — текст ошибки**), `broken`, `not tested (off)`.
- **VPN запущен + есть выключенные члены → попап** после теста: «N disabled
  server(s) were not tested … Stop VPN and run the test again».
- **Цветовая шкала** (пороги — настройка, дефолты NeoCat):
  зелёный ≤ 250 < жёлтый ≤ 500 < оранжевый ≤ 700 < красный. Хранение —
  `vars.probe_ms_green/yellow/orange` (в `_appFeatureFlagVars` → переживают
  backup; НЕ config-vars).
- URL и timeout теста — существующие `ping_options.url` / `timeout_ms`.
- **Массовые действия** (⋮ в полосе при наличии результатов):
  - `Disable slower than … ms` (prefill = оранжевый порог) — per-member toggle;
  - `Delete unreachable` — err/timeout + broken (confirm с количеством);
  - `Sort by ping` — reorder members по возрастанию (err/broken в конец).
- Результаты эфемерны (state экрана) — НЕ персистятся (протухают мгновенно).

## Вне скоупа (фазы позже)

- Тест на экране подписки (нужен per-node disable подписок — отдельная задача).
- Шаг «Test & filter» прямо в импорте пачки (сначала обкатать в папке).
- Фильтр стран по кодам/GeoIP (NeoCat #562, вторая половина) — отдельная
  задача: тег-эвристика vs offline-mmdb.
- Батч-RPC в ядре (SPEC 015 §5 deferred) — пул на клиенте достаточен.

## Файлы

| Слой | Файл | Изменение |
|---|---|---|
| native | `ProbeSession.kt` (новый) | CommandServer/Client lifecycle, гейт tunnelAlive |
| native | `VpnPlugin.kt` | кейсы probeStart/probeUrlTest/probeStop |
| native | `BoxService.kt` | стоп probe перед стартом VPN |
| dart | `services/probe/probe_config.dart` (новый) | мини-билдер конфига |
| dart | `services/probe/probe_runner.dart` (новый) | пул, вердикты, отмена; ветка VPN-on → ccUrlTestOutbound |
| dart | `vpn/cc_channel.dart` | probe-методы MethodChannel |
| ui | `folder_detail_screen.dart` | кнопка/бейджи/шкала/массовые действия/диалог порогов |
| storage | `vars` | probe_ms_green/yellow/orange (defaults 250/500/700) |
| тесты | `test/probe/` | probe-конфиг (все enabled, broken исключён, dns/resolver), классификация порогов, bulk-действия, ветка вердиктов |

## Критерий готовности

VPN выключен → папка с пачкой серверов → Test servers → у всех членов
задержка/err/broken → Disable slower 700 → Delete unreachable → Sort by ping →
конфиг ядра не запускался как VPN (иконки ключа не было).

## Связанные

- §234 server-folders (место жительства), §209 pingClient (VPN-on ветка),
  ядро SPEC 014/015 (`URLTestOutbound`, Variant B error-model), §119
  vpn-mode (прецедент «конфиг без tun → openTun не зовётся»), §173 SetupOptions.
