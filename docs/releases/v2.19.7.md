# L×Box v2.19.7

Two crashes are gone from the core, and the app takes its first steps on
Android TV. The TV work is best-effort: the app now appears in the TV
launcher and the two places that were outright broken there are fixed, but
the layout is still designed for a phone.

Из ядра ушли два краша, а приложение сделало первые шаги на Android TV.
Поддержка TV — best-effort: приложение появляется в телевизионном лаунчере
и два нерабочих там места починены, но вёрстка по-прежнему рассчитана на
телефон.

<details open>
<summary><h2>🇬🇧 English</h2></summary>

## 💥 Fixed — the core no longer dies on a network switch during startup

Switching WiFi↔LTE at the exact moment the tunnel was starting killed the
whole process with a nil-pointer panic. The crash came from a real user
report with a crash dump.

The core gates early remote calls by "is the box object there", but the box
is published the moment it is *created* — while it is still starting, its
network fields are not filled in yet. A network switch landing in that
window reached those empty fields. The app registers the network monitor
before starting the tunnel, so the overlap was a normal thing to hit, not an
exotic one.

The gate now checks that the service actually reached the started state, and
the reset path has its own guard on top.

## 💥 Fixed — a TCP connection to an unreachable node killed the process

A connection that never got established took the whole process down instead
of simply timing out. Inside the network stack, a failed handshake cleared
its own state and released the lock before closing the endpoint; a packet
arriving in that window found a half-cleared handshake and dereferenced it.

## 📺 Added — the app shows up in the Android TV launcher

The manifest now declares `leanback` and `touchscreen` (both
`required="false"`) plus the `LEANBACK_LAUNCHER` category. Before that a TV
did not show the icon at all, and the missing explicit
`touchscreen required="false"` made the app formally incompatible with
devices that have no touchscreen. Nothing changes on phones and tablets.

## 📺 Fixed — importing from a file on devices without a file manager

Android TV has no system document picker, and the request is intercepted by
a system stub: it flashed a toast and silently cancelled the selection, so
the "import from file" button looked broken. The app now checks for a real
file manager up front and points to a working alternative — pasting from the
clipboard or adding by link.

## 📺 Fixed — the mass-ping button could not be reached with a remote

It was a `GestureDetector`, which has no focus node, so D-pad navigation
skipped straight past it. It is now an `InkWell`, and the main Start/Stop
button takes focus when the screen opens.

## 🔧 Process — the Flutter pin lives in the repository

The Flutter version used for builds is now read from
`app/android/flutter.version` instead of being hardcoded twice in CI. This
came out of the F-Droid review: the build should read that number from our
code rather than keep its own copy in packaging metadata.

## ✅ Tests

`flutter analyze` clean, 2937 tests pass, all four l10n checkers green.
The TV changes were verified on an Android TV emulator; behaviour on a real
television is not confirmed yet.

</details>

<details open>
<summary><h2>🇷🇺 Русский</h2></summary>

## 💥 Исправлено — ядро больше не умирает при смене сети на старте

Переключение WiFi↔LTE ровно в момент запуска туннеля убивало весь процесс
nil-паникой. Краш пришёл из реальной жалобы вместе с крашдампом.

Ядро гейтило ранние вызовы по принципу «объект box существует», но box
публикуется в момент *создания* — пока он ещё стартует, его сетевые поля не
заполнены. Смена сети, попавшая в это окно, добиралась до пустых полей.
Приложение регистрирует монитор сети до запуска туннеля, поэтому совпадение
было штатным, а не экзотическим.

Теперь гейт проверяет, что сервис действительно дошёл до состояния
«запущен», а на самом пути сброса стоит отдельная защита.

## 💥 Исправлено — TCP-соединение до недостижимого узла роняло процесс

Соединение, так и не дошедшее до установленного состояния, убивало весь
процесс вместо того, чтобы просто отвалиться по таймауту. Внутри сетевого
стека неудачное рукопожатие занулило собственное состояние и отпустило
блокировку до закрытия точки соединения; пришедший в это окно пакет нашёл
наполовину зачищенное рукопожатие и разыменовал его.

## 📺 Добавлено — приложение видно в лаунчере Android TV

В манифест добавлены `leanback` и `touchscreen` (обе `required="false"`) и
категория `LEANBACK_LAUNCHER`. Раньше телевизор не показывал иконку вообще,
а отсутствие явного `touchscreen required="false"` делало приложение
формально несовместимым с устройствами без сенсорного экрана. На телефонах
и планшетах ничего не меняется.

## 📺 Исправлено — импорт из файла на устройствах без файлового менеджера

На Android TV системного документ-пикера нет, а запрос перехватывает
системная заглушка: она мигала тостом и молча отменяла выбор, поэтому
кнопка «импорт из файла» выглядела неработающей. Теперь приложение проверяет
наличие настоящего файлового менеджера заранее и подсказывает рабочую
альтернативу — вставку из буфера обмена или добавление по ссылке.

## 📺 Исправлено — кнопка массового пинга недостижима с пульта

Была `GestureDetector`, у которого нет фокусного узла, — навигация по D-pad
просто пропускала её. Заменена на `InkWell`; главная кнопка Start/Stop
получает фокус при открытии экрана.

## 🔧 Процесс — пин Flutter лежит в репозитории

Версия Flutter, которой идёт сборка, теперь читается из
`app/android/flutter.version`, а не хардкодится в CI двумя местами. Это
пришло из ревью F-Droid: сборка должна брать это число из нашего кода, а не
держать собственную копию в метаданных упаковки.

## ✅ Тесты

`flutter analyze` чистый, 2937 тестов проходят, все четыре l10n-чекера
зелёные. Изменения для TV проверены на эмуляторе Android TV; поведение на
реальном телевизоре пока не подтверждено.

</details>

---

## 📲 Install

```bash
adb install -r LxBox-v2.19.7-arm64-v8a.apk
```

Без uninstall! Поверх существующей установки. Настройки и подписки сохранятся.

No uninstall needed — install over the existing one. Settings and
subscriptions are preserved.

---

Previous release / Предыдущий релиз: [v2.19.6](docs/releases/v2.19.6.md).
