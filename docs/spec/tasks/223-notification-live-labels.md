# §223 — Live-обновление лейблов уведомления при смене ноды (GitHub #20)

**Тип:** bug-fix (native / notification)
**Статус:** ✅ Реализовано
**Приоритет:** Medium (заметно каждому, кто переключает ноды при живом туннеле)
**Связано:** §123 (подтекст = тег активной ноды), §182 (кнопки Stop/Reconnect,
broadcast-паттерн), GitHub issue #20 (репорт с видео), частично #23

## Симптом (issue #20)

Подтекст foreground-уведомления («vpn-1: 🇫🇮 …») замораживается на ноде,
выбранной в момент старта туннеля. Переключение ноды без Stop/Start (selector
или URLTest-автовыбор) шторку не обновляет — она врёт до полного рестарта.

## Корень

Путь «Dart → native» для лейблов был написан наполовину:

- Dart честно шлёт свежие лейблы: `home_controller.applyGroup()` →
  `_pushNotificationLabels()` → `setNotificationTitle/Text` (§123) — на каждый
  groups-push, включая смену ноды.
- Native (`VpnPlugin` → `ConfigManager.setNotificationText`) строку **только
  кэшировал**. Единственный рендер с лейблами — `notification.show(...)` в
  `BoxService.startSingbox()` на connect. Re-render-пути не существовало.

## Решение (broadcast-паттерн, как §182)

1. **`BoxVpnService`**: новый `ACTION_UPDATE_NOTIFICATION` + companion-метод
   `updateNotification(context)` — шлёт package-scoped broadcast (как
   `stop()`/`reload()`).
2. **`VpnPlugin`** (`setNotificationTitle`/`setNotificationText`): после
   кэширования, **только если значение изменилось**, дёргает
   `BoxVpnService.updateNotification(context)`. Дедуп против лишних рендеров:
   `_pushNotificationLabels` шлёт оба лейбла на каждый groups-push, а меняется
   обычно один.
3. **`BoxService.receiver`**: обработчик `ACTION_UPDATE_NOTIFICATION` — рендер
   `notification.show(title, text.ifEmpty { "Connected" })` **строго при
   `status == Started`**. Тот же `show()`-путь, что и connect-рендер: builder
   в `ServiceNotification` переиспользуется, кнопки §182 навешаны один раз в
   `init` → не стекаются.

## Почему guard на Started обязателен

- **Starting**: держим «Starting…» — connect-рендер в `startSingbox()` сам
  подхватит закэшированные лейблы (Dart шлёт их ДО `startVPN()`).
- **Stopping/Stopped**: `show()` = `startForeground()` — после
  `notification.stop()` он воскресил бы шторку убитого туннеля. Вне жизни
  сервиса receiver вообще не зарегистрирован → broadcast — no-op.

## Что НЕ решает (границы)

- **URLTest-автопереключение без UI**: подтекст показывает НАЧАЛЬНУЮ ноду
  (снапшот на старте, см. Часть B). Если ядро потом само переключит ноду через
  URLTest, пока приложение не открыто, — подтекст не обновится (нет подписчика в
  фоне по энергомодели). Это осознанно вне скоупа задачи.
- Трафик-статистика в шторке (#22) — вне скоупа.

---

# Часть B — native-fallback лейбла при старте без UI (#23, частично)

## Проблема

Часть A перерисовывает шторку, но строку по-прежнему поставляет ТОЛЬКО Dart
(`_pushNotificationLabels`). При старте с **QS-плитки / launcher-shortcut**
сервис может подняться в свежем процессе БЕЗ Flutter-движка — лейблы прислать
некому, `ConfigManager.notificationText` пуст → шторка показывает `Connected`.

## Решение: один unary-pull через ~3 с после Started

«Потребитель, а не подписчик»: native сам ОДИН раз читает выбранную ноду через
уже существующий `BoxCommandClient.getGroups()` — это unary RPC поверх
`ensurePingClient()` (lifecycle-независимый клиент §209, без подписки). Новой
резидентной подписки НЕ появляется, энергомодель не трогаем.

Точка: `BoxService.startSingbox()`, сразу после создания `commandClient`
(тот же метод, где идёт connect-рендер). На `serviceScope` (отменяется в
onDestroy/stop → нет утечки и рендера мёртвой шторки):

```
serviceScope.launch {
    delay(NOTIFICATION_SNAPSHOT_DELAY_MS)   // ~3с — дать ядру устаканить selected
    if (status != Started) return           // stop/reload успел
    if (ConfigManager.notificationText.isNotEmpty()) return  // Dart уже прислал — UI есть
    val label = commandClient?.selectedNodeLabel(ConfigManager.load()) ?: return
    ConfigManager.setNotificationText(label)
    notification.show(notificationTitle, label)   // тот же show()-путь
}
```

### `BoxCommandClient.selectedNodeLabel(configRaw): String?`

Новый публичный хелпер. Повторяет логику выбора «главной» группы из
`home_controller.dart:807` (Dart `selectedGroup`):

1. `getGroups()` → список групп (selector'ы; unary через ensurePingClient).
2. Исключить `GLOBAL`.
3. Выбрать группу: `route.final` (если есть среди групп и валиден), иначе
   первую. `route.final` парсим из `configRaw` через `org.json` (как Dart
   `RouteConfig.finalTag`: `root.route.final`).
4. Нода = `group.selected`. Формат подтекста — как в Dart
   `_pushNotificationLabels`: `«<группа>: <нода>»`, при пустой ноде — только
   группа. `null` если групп нет / RPC не удался (оставляем `Connected`).

## Почему guard'ы обязательны

- **`status != Started`** — за 3 с юзер мог нажать Stop/переоткрыть; рисовать
  шторку остановленного туннеля нельзя (см. Часть A про воскрешение).
- **`notificationText.isNotEmpty()`** — если Dart УЖЕ прислал лейбл (UI был
  открыт), native-fallback молчит: Dart-источник авторитетнее (знает
  `selectedGroup` из своего state, покроет и последующие смены).

## Файлы (Часть B)

- `BoxCommandClient.kt` — публичный `selectedNodeLabel(configRaw)` + приватный
  разбор `route.final`.
- `BoxService.kt` — const `NOTIFICATION_SNAPSHOT_DELAY_MS` + snapshot-корутина
  в `startSingbox` после создания `commandClient`.

## Верификация (Часть B)

- Kotlin компилируется.
- Device: НЕ открывая приложение, старт с QS-плитки → через ~3 с подтекст
  показывает `vpn-1: <нода>` вместо `Connected`. Открытие приложения после —
  Dart-лейблы работают как в Части A (native молчит: text уже не пуст).

## Файлы

- `BoxVpnService.kt` — const + companion `updateNotification`
- `BoxService.kt` — IntentFilter + receiver-обработчик
- `VpnPlugin.kt` — changed-check + триггер в двух хендлерах

## Верификация

- Компиляция Kotlin — локально.
- Device-сценарий (#20): connect → смена ноды в selector → шторка обновилась
  без Stop/Start; кнопки Stop/Reconnect не дублируются; Stop → уведомление
  исчезло и не воскресает.
