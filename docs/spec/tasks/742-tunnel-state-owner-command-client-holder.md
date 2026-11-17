# 742 — Владелец состояния туннеля, держатель командного клиента, сторож границ

| | |
|---|---|
| **Статус** | Done — код, чекер и документация в develop; эмулятор ОК (7 сценариев), телефон не проверен |
| **Дата** | 2026-11-17 |
| **Повод** | Слово владельца 17.11.2026: «делай пункты 1 и 2 и подумай, где улучшить» — продолжение [740](740-architecture-revision-process-boundary.md), раздел «Не делается» |
| **Связанные** | [740](740-architecture-revision-process-boundary.md), [122F — CommandClient](122F-commandclient-migration/), [732 — вызовы ядра с главного потока](732-main-thread-core-calls-off-main.md), [ARCHITECTURE → Process boundary](../../ARCHITECTURE.md#process-boundary-vpn-service-side-vs-ui-side) |

## Главное правило

Поведение не меняется: те же статусы, те же моменты создания и остановки
командного клиента, те же уведомления, те же строки логов. Меняется, кто
чем владеет и кто на кого ссылается.

## Проблема

1. **Состояние туннеля — четыре отдельных поля в companion сервиса**
   (`currentStatus`, `currentRevoked`, `tunnelStartedElapsedMs`,
   `currentSessionAllowBypass`). Их читают 14 файлов с обеих сторон, обращаясь
   к классу `BoxVpnService`. Читатель может увидеть несогласованную пару
   (статус уже `Stopped`, метка `revoked` ещё прежняя). UI-сторона ради чтения
   состояния зависит от класса Android-сервиса.
2. **Командный клиент — поле `BoxService.commandClient`.** UI-сторона
   (`VpnPlugin`, 43 обращения, и активити Taildrop) ходит за клиентом в класс
   рантайма сервиса. Проверка `commandClient != null` служит ещё и признаком
   «ядро поднято» (`ProbeSession`, `Taildrop`). Сам `BoxCommandClient`
   рисует уведомления сервиса (`ServiceNotification.showSignIn/cancelSignIn`)
   и пишет в лог через `BoxService.appLogWarning` — клиент сокета знает о
   сервисе, хотя по сути он клиент `command.sock` и мог бы жить в любом
   процессе.
3. **Границы никто не сторожит.** Правила из 740 (шесть пунктов о границе
   процессов, направление слоёв Dart) записаны в документе, но нарушение
   пройдёт CI незамеченным — так и накопился долг, который 740 разбирала.

## Решение

### A. `TunnelState` — единственный владелец состояния туннеля

`vpn/TunnelState.kt`, `object TunnelState`:

- неизменяемый снимок `Snapshot(status, revoked, startedElapsedMs,
  sessionAllowBypass)` в одном `@Volatile` поле; геттеры `status`, `revoked`,
  `startedElapsedMs`, `sessionAllowBypass`, `snapshot`;
- запись — только `internal`-методами (`setStatus`, `setSessionAllowBypass`),
  каждый заменяет снимок целиком; логика переходов (§276 сброс `revoked`,
  §187 фиксация старта один раз) переезжает сюда дословно;
- побочный эффект `TaildropClip.onVpnStopped` остаётся на стороне сервиса
  (в `BoxVpnService.setCurrentStatus`, который теперь зовёт `TunnelState` и
  затем эффект) — владелец состояния ничего не знает о Taildrop.

Поля companion удаляются, все читатели переходят на `TunnelState`.
`live`, `stopReceiverAlive`, `stopCompleter` остаются в `BoxVpnService`: это
не состояние туннеля, а механика сервиса в его процессе.

После разделения на процессы у UI-процесса будет свой `TunnelState`,
наполняемый из `BROADCAST_STATUS`; читатели не изменятся.

### B. `CoreSession` — держатель командного клиента

`vpn/CoreSession.kt`, `object CoreSession`:

- `client: BoxCommandClient?` (`@Volatile`, запись `internal`: `open(cc)` /
  `close()`), `isUp: Boolean` — вместо проверок `commandClient != null`;
- `BoxService` открывает и закрывает сессию в тех же точках, где сейчас
  присваивает поле; поле `BoxService.commandClient` удаляется;
- все читатели (`VpnPlugin`, `Taildrop*`, `ProbeSession`, активити) переходят
  на `CoreSession`.

`BoxCommandClient` перестаёт ссылаться на сервис: зависимости приходят
конструктором — интерфейс `Host` (`showSignIn(tag)`, `cancelSignIn(tag)`,
`logWarning(text)`); реализацию даёт `BoxService` (прежние вызовы
`ServiceNotification` и `appLogWarning`). В файле `BoxCommandClient.kt` не
остаётся ссылок на `BoxService`, `BoxVpnService`, `ServiceNotification`.
`SerialLane` в companion пишет предупреждения через статический приёмник,
который назначает `BoxService` (поведение `appLogWarning` прежнее).

`BoxService.coreLogsVerbose` и вызов `BoxService.doForceStop` из `VpnPlugin`
в этой задаче не трогаются (см. «Не делается»).

### C. Сторож границ в CI

`app/tool/arch/boundary_check.dart` — по образцу `tool/l10n/*_check.dart`,
запуск в джобе `checks` (`--strict`). Правила — грепом по импортам и
ссылкам, со списком разрешённых исключений в самом файле (каждое с
причиной):

Dart (`app/lib`):
- `services/`, `models/`, `config/` не импортируют `screens/`, `widgets/`
  (исключение: `services/debug/handlers/taildrop.dart` → `exit_node_store`);
- `vpn/` не импортирует `controllers/`, `screens/`, `widgets/`;
- `controllers/` не импортируют `screens/`, `widgets/`;
- `MethodChannel(` / `EventChannel(` со строковым литералом имени — только
  в `vpn/platform_channels.dart` (остальные берут имя из реестра);
- список файлов `screens/` и `widgets/`, импортирующих
  `vpn/box_vpn_client.dart` или `vpn/cc_channel.dart`, заморожен: новые
  файлы в него не добавляются без правки чекера (долг не растёт).

Kotlin (`app/android/app/src/main/kotlin`):
- `VpnPlugin` упоминается только в `VpnPlugin.kt`, `MainActivity.kt` и
  регистрации плагина;
- `EventSink` как тип поля — только в `UiSinks.kt` (и локально в
  `VpnPlugin.kt`);
- `getSharedPreferences(` — только в `BootReceiver.kt`, `NativeCache.kt`,
  `AutomationCache.kt` (плюс удаление устаревших файлов в `VpnPlugin.kt`);
- `BoxService.` не встречается в UI-файлах (`VpnPlugin.kt`,
  `MainActivity.kt`, `Taildrop*Activity.kt`, `editor/`) сверх замороженного
  списка (`coreLogsVerbose`, `doForceStop`);
- `BoxVpnService.currentStatus` и другие удалённые поля не встречаются нигде.

Чекер печатает нарушение как `файл:строка правило`, выходит с кодом 1 в
`--strict`. В `ARCHITECTURE.md` у каждого правила — ссылка на чекер.

## Не делается

- Создание командного клиента UI-стороной по событию статуса (вместо
  создания сервисом) — меняет моменты подключения, отдельная задача с
  проверкой на телефонах.
- Разрез `VpnPlugin.onMethodCall`, `CoreControl` для process-global
  `Libbox.*`, `ConfigManager.cachedConfig`, `coreLogsVerbose`, `doForceStop`
  из плагина.
- Дефект `onDetachedFromEngine` (два необнуляемых sink'а) — из 740, не здесь.

## Проверка

- `compileDebugKotlin`, unit-тесты Kotlin; unit-тест на переходы
  `TunnelState` (Starting/Started сбрасывают `revoked`; старт фиксируется
  один раз; `Stopped` обнуляет старт).
- `flutter analyze`, чекер `boundary_check --strict` — 0 нарушений.
- Эмулятор: старт VPN, статус и аптайм после перезапуска UI при живом
  туннеле, данные главного экрана (группы, скорость), остановка, повторный
  старт, остановка из уведомления.

## Docs to update

- эта задача
- [ARCHITECTURE.md](../../ARCHITECTURE.md) — раздел «Process boundary»
  (владельцы состояния и клиента, сторож), схема «Class layout»
- `CHANGELOG.md` — none

## Итог

- **A.** `vpn/TunnelState.kt`: снимок `Snapshot` в одном `@Volatile` поле, запись
  `@Synchronized`. Четыре поля companion удалены, читатели (17 файлов) переведены.
  `VpnPlugin.getVpnStatus` берёт статус и `revoked` одним чтением снимка.
  Unit-тест `TunnelStateTest` — 5 случаев.
- **B.** `vpn/CoreSession.kt`; поле `BoxService.commandClient` удалено.
  `BoxCommandClient(host)` — интерфейс `Host` реализует `BoxService`;
  предупреждения полосы идут через `BoxCommandClient.laneWarningSink`. В
  `BoxCommandClient.kt` нет ссылок на `BoxService`, `BoxVpnService`,
  `ServiceNotification`.
- **C.** `app/tool/arch/boundary_check.dart` (+ `src/boundary_scan.dart`, тест,
  README), шаг «Architecture boundaries» в джобе `checks`. Десять правил, на
  дереве после A и B — 0 нарушений. Исключение сверх спеки: `EventSink` как тип
  разрешён ещё в `BoxCommandClient.kt` (эмиттеры держат sink).
- **Эмулятор** (Android 16, arm64, сборка из b1e84331): холодный старт, старт
  VPN с данными ядра на экране, аптайм после закрытия активити (продолжился),
  остановка из приложения, повторный старт, остановка из уведомления — без
  ошибок в logcat. Не проверено: смерть процесса UI при живом сервисе (процесс
  один), уведомление Sign-in у openconnect, телефоны.
