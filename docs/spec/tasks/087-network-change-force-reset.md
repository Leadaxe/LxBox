# 087 — Force-reset соединений на смену сети (native, variant C)

| Поле | Значение |
|------|----------|
| Статус | Implementation — реализует **failure mode 1** из §086 |
| Дата | 2026-06-08 |
| Тип | bug-fix / native |
| Основание | [§086](086-stale-connections-network-change-doze.md) — root-cause найден, recommendation = variant **C** (native force-reset на genuine interface change) |
| Файлы | `DefaultNetworkMonitor.kt` (детект genuine change + debounce + reset), `BoxService.kt` (проводка reset-callback). |
| Вне скоупа | Failure mode 2 (Doze freeze) — research §086 не закончен; variant B/D (Dart) — C закрывает mode 1 в корне, на правильном слое. |

## Проблема (из §086)

Смена сети (WiFi↔LTE): native ловит смену интерфейса и шлёт libbox
**passive** `updateDefaultInterface(name, idx, false, false)` — ядро узнаёт про
новый NIC (новые коннекты биндятся верно), но **существующие** сокеты на
мёртвом интерфейсе не закрываются. Браузер ретрансмитит в них до TCP-таймаута
→ «старое висит, новое грузится».

`resetNetwork()` (= `commandServer.resetNetwork()` → ядро CloseAll + flush DNS +
rebind) **реализован**, но дёргается только вручную. Gap: его никто не зовёт
на смену интерфейса.

## Решение (variant C)

В `DefaultNetworkMonitor.checkUpdate()` — детект **genuine interface change** и
debounced-вызов `resetNetwork()`.

### Дисциплина (критично — иначе регрессия #3400 «убить весь TCP на каждый чих»)

`checkUpdate` дёргается из `DefaultNetworkListener` на **любой**
`onCapabilitiesChanged` (`Msg.Update`), не только на смену сети. Поэтому
reset **только** когда:

```
lastIfName != newIfName
  И lastIfName非пустой (был реальный интерфейс)
  И newIfName非пустой (есть новый реальный интерфейс)
```

Матрица:

| Переход | Reset? | Почему |
|---|---|---|
| `""` → `wlan0` (первый connect) | ❌ | нечего закрывать |
| `wlan0` → `wlan0` (capability-update) | ❌ | не смена сети |
| `wlan0` → `""` (disconnect) | ❌ | нет сети для re-dial |
| `wlan0` → `rmnet_data0` (switch) | ✅ | стейл-сокеты на старом NIC |
| `rmnet_data0` → `wlan0` (switch back) | ✅ | то же |

### Debounce

Android при переходе шлёт пачку callback'ов. `resetJob` отменяется и
перезапускается на каждый genuine change; фактический `resetNetwork()`
выполняется через **`RESET_DEBOUNCE_MS` (1500ms)** тишины. Пачка переходов =
один reset.

### Проводка

- `DefaultNetworkMonitor.start(scope, onNetworkSwitch)` — добавлен 2-й параметр
  `onNetworkSwitch: () -> Unit`. `BoxService.runService` передаёт
  `{ runCatching { commandServer.get()?.resetNetwork() } }`.
- `lastIfName: String?` — хранит имя последнего интерфейса; обновляется в
  `checkUpdate`/`notifySync`. Сбрасывается в `stop()`.
- `resetJob: Job?` — debounce; отменяется в `stop()`.
- Serialization: `checkUpdate` исполняется в actor-корутине
  `DefaultNetworkListener` последовательно → `lastIfName` без доп. локов.
- Reset выполняется на `Dispatchers.IO` (как и passive-уведомление).

## Что НЕ меняется

- `updateDefaultInterface(..., false, false)` passive-уведомление остаётся —
  оно нужно для rebind'а новых коннектов (`auto_detect_interface`). Reset
  **дополняет** его, не заменяет.
- Конфиг (`wizard_template.json`), `interrupt_exist_connections`,
  `resetNetwork()` Dart/native реализация — без изменений.

## Проверка

- `flutter analyze` clean; Dart-тесты зелёные (native не покрыт unit-тестами —
  Kotlin без test-harness в проекте).
- Device-verify (manual): WiFi→LTE на загруженной странице → старые сессии
  пересоздаются (RST), не виснут до таймаута. Лог `[vpn] receiver:
  ACTION_RESET_NETWORK` / прямой `resetNetwork()` в logcat при переключении.
- Negative: сидя на одной сети (capability-updates) reset **не** триггерится
  (нет лог-спама resetNetwork).

## Источники

- §086 — root-cause + industry consensus.
- `route/network.go` (sing-box) — `notifyInterfaceUpdate`/`ResetNetwork`.
