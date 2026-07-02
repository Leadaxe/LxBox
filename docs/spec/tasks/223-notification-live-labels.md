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

- **#23 (старт с QS-плитки без UI)**: в свежем процессе Dart-движка нет, лейблы
  некому прислать → fallback «Connected» остаётся. НО: как только юзер открывает
  приложение, `applyGroup` шлёт лейблы, и теперь (в отличие от прежнего
  поведения) шторка обновится без рестарта. Полный фикс #23 — native-side
  источник имени ноды, отдельная задача.
- Трафик-статистика в шторке (#22) — вне скоупа.

## Файлы

- `BoxVpnService.kt` — const + companion `updateNotification`
- `BoxService.kt` — IntentFilter + receiver-обработчик
- `VpnPlugin.kt` — changed-check + триггер в двух хендлерах

## Верификация

- Компиляция Kotlin — локально.
- Device-сценарий (#20): connect → смена ноды в selector → шторка обновилась
  без Stop/Start; кнопки Stop/Reconnect не дублируются; Stop → уведомление
  исчезло и не воскресает.
