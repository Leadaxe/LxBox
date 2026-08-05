# L×Box v2.20.0

Two things you can now do that you couldn't before: import a config by
scanning a QR code with the camera, and save a backup as a file instead of
only sending it through the share sheet. The app no longer freezes with
"isn't responding" while reloading a large config. And the diagnostic report
you send us is now readable and says which build it came from.

Два новых действия: импорт конфига сканированием QR-кода камерой и сохранение
бэкапа файлом, а не только через «поделиться». Приложение больше не зависает
с «не отвечает» при перезагрузке большого конфига. А диагностический отчёт,
который вы нам присылаете, стал читаемым и теперь сообщает, на какой сборке
снят.

<details open>
<summary><h2>🇬🇧 English</h2></summary>

## 📷 Added — import by scanning a QR code

"Scan QR code" in the ⋮ menu on the servers screen used to answer with "QR
scanner coming soon". It now opens the camera.

QR is how most providers hand out configs — a code on the panel page, a
screenshot in a support chat. Until now you had to decode it with another
app and paste the result.

Whatever the code contains goes through the same import as a paste: a single
proxy link or a subscription URL, both work. Before anything is added you
get a confirmation dialog showing what actually arrived — a QR code is
untrusted input, and nothing is imported silently.

Nodes added this way are marked with source `qr`. Devices without a camera
(Android TV) don't show the menu item at all: unlike file import, where the
clipboard and a URL remain as alternatives, scanning has no fallback.

The APK grew by 3.8 MB — that's the ML Kit barcode scanner and CameraX.

## 💾 Added — backup export can save a file

Export now asks how you want it:

- **Save to file** — the system save dialog, you choose the folder.
- **Save to Downloads** — writes straight to the public Downloads folder
  (Android 10+).
- **Share** — the previous behaviour.

This came from a user report: "on some devices without a third-party file
manager there's no way to save the backup". Export only ever opened the
share sheet, and the file itself lived in the app cache — where it went was
whatever you picked in the sheet, and the cache gets cleared eventually. With
no file manager installed there was often no "save to files" target in the
sheet at all.

Options your device can't do aren't shown.

## 💥 Fixed — the app froze with "isn't responding" while reloading the config

Applying a config change to a running tunnel could freeze the interface for
long enough that Android offered to close the app. The fix came from a user
report with a diagnostic dump.

Reloading rebuilds the whole core instance — parsing the config and
assembling every outbound, DNS and routing. That work was running on the UI
thread, so nothing was drawn and no taps were handled until it finished. On
a typical config it takes a fraction of a second and passes unnoticed; on a
subscription with several hundred nodes it went past the five-second mark
where Android declares the app unresponsive.

The reload now runs off the UI thread, so the interface stays responsive
regardless of how large the config is. The tunnel still drops and comes back
during a reload, as before.

Two neighbouring actions went the same way, for the same reason: clearing
the DNS cache (it reloads too) and the network reset.

This was not a core problem — the core was doing its normal work, it was
simply being called from the wrong thread.

## 🔎 Fixed — the diagnostic report drowned in its own noise

When a subscription points nodes at a relay that isn't currently built — a
disabled WARP preset is the usual case — the app drops the broken link and
warns about it. It used to warn once per node: 138 nodes meant 138 identical
lines per rebuild.

In one user's dump that came to 276 lines out of 305. Everything else had
been pushed out of the log, including the events we needed to read.

It's now one line per missing relay: how many nodes referenced it, the names
of the first five, and a count of the rest.

## 🏷 Fixed — the diagnostic report now says which build it came from

`Share dump` writes `app_version`, `app_build` and `core_version` at the top
of the file.

Before this, the core version reached the report only by accident — as a
field inside crash or OOM snapshots, because the core puts it there itself.
No snapshots, no version. The app's own version was never in the report at
all. First question on any report is which build to reproduce on, and the
report couldn't answer it.

## 🔧 Process — the version code is derived from the version

Nothing changes for you: updates install as before. This is about how builds
are numbered.

Android orders updates by an integer `versionCode`. Until now ours was the
number of commits in history — a value that says how often someone committed,
not which version this is. That made the version impossible to read from the
sources, which is what F-Droid's update checker does. Automatic updates in
their catalogue were therefore off, and every version needed a manual merge
request.

The number is now derived from the version itself: `2.20.0` on arm64 becomes
`22000502`, where the digits carry major, minor, patch, the stage
(release candidate, release, hotfix) and the architecture. The architecture
is the last digit on purpose — F-Droid sorts by this number, and with the
architecture in the leading digits an old x86_64 build outranks a new armv7
one, scrambling the version list.

Your installed build carries a much smaller number (3606 on arm64), so the
new scheme is far above it and updates keep working. Verified on a device.

## ✅ Tests

2941 tests green, analyzer clean, all four localization checkers at zero.

QR scanning and backup export are both device-verified (04.08.2026): a phone
emulator on API 34 and an Android TV emulator on API 31. The version fields
are device-verified too (05.08.2026, on a phone). The aggregated warning has
four tests of its own.

The version-code change is device-verified (05.08.2026, arm64 emulator on
Android 14): a build carrying the old number installs over with the new one
without uninstalling, and an equal number still installs — the property local
dev builds depend on.

The freeze fix has not been verified on a device: reproducing it needs a
subscription of several hundred nodes, since a normal config never reaches
the freeze threshold. Kotlin compiles clean.

</details>

<details open>
<summary><h2>🇷🇺 Русский</h2></summary>

## 📷 Добавлено — импорт сканированием QR-кода

Пункт «Scan QR code» в меню ⋮ на экране серверов раньше отвечал «QR scanner
coming soon». Теперь он открывает камеру.

QR — основной способ раздачи конфигов: код на странице панели, скриншот в
чате поддержки. До сих пор его приходилось распознавать сторонним
приложением и вставлять результат вручную.

Содержимое кода уходит в тот же разбор, что и вставка из буфера: работает и
одиночная proxy-ссылка, и ссылка на подписку. Перед добавлением показывается
диалог подтверждения с тем, что реально приехало в коде — QR недоверенный
ввод, молча ничего не добавляется.

Узлы, добавленные сканером, помечаются источником `qr`. На устройствах без
камеры (Android TV) пункт меню не показывается вовсе: в отличие от импорта
файла, где остаются буфер обмена и ссылка, у сканирования замены нет.

APK вырос на 3.8 МБ — это сканер штрихкодов ML Kit и CameraX.

## 💾 Добавлено — экспорт бэкапа умеет сохранять файл

Экспорт теперь спрашивает способ:

- **Сохранить в файл** — системный диалог сохранения, папку выбираете вы.
- **Сохранить в Загрузки** — пишет прямо в публичную папку «Загрузки»
  (Android 10+).
- **Поделиться** — прежнее поведение.

Пришло из жалобы: «бэкап на некоторых устройствах без стороннего файлового
менеджера не сохранить». Экспорт открывал только share-sheet, а сам файл
лежал в кэше приложения — куда он попадёт, решал выбор в шите, а кэш рано
или поздно вычищается системой. Без файлового менеджера пункта «сохранить в
файлы» в шите часто не было вообще.

Способы, недоступные на конкретном устройстве, в списке не показываются.

## 💥 Исправлено — приложение зависало с «не отвечает» при перезагрузке конфига

Применение изменений конфига к работающему туннелю могло заморозить
интерфейс настолько, что Android предлагал закрыть приложение. Исправление
пришло из жалобы пользователя вместе с диагностическим дампом.

Перезагрузка пересобирает весь инстанс ядра — разбирает конфиг и заново
строит все узлы, DNS и маршрутизацию. Эта работа шла на потоке интерфейса,
поэтому до её завершения ничего не отрисовывалось и нажатия не
обрабатывались. На обычном конфиге она занимает доли секунды и проходит
незаметно; на подписке в несколько сотен узлов выходила за пять секунд —
порог, после которого Android считает приложение зависшим.

Теперь перезагрузка идёт вне потока интерфейса, и он остаётся отзывчивым при
любом размере конфига. Туннель во время перезагрузки по-прежнему отваливается
и поднимается заново — это не изменилось.

Тем же путём отправились два соседних действия по той же причине: сброс
DNS-кэша (он тоже делает перезагрузку) и сброс сети.

Проблема была не в ядре — ядро делало свою обычную работу, его просто звали
не с того потока.

## 🔎 Исправлено — диагностический отчёт тонул в собственном шуме

Когда подписка направляет узлы через посредника, которого сейчас в конфиге
нет (типовой случай — выключенный WARP-пресет), приложение снимает битую
ссылку и предупреждает об этом. Предупреждение писалось на каждый узел: 138
узлов давали 138 одинаковых строк за одну пересборку.

В дампе одного из пользователей это дало 276 строк из 305. Всё остальное из
лога вытеснилось, включая события, которые и надо было прочитать.

Теперь строка одна на каждого недостающего посредника: сколько узлов на него
ссылались, имена первых пяти и счётчик остальных.

## 🏷 Исправлено — по отчёту видно, на какой сборке он снят

`Share dump` пишет в начало файла `app_version`, `app_build` и
`core_version`.

Раньше версия ядра попадала в отчёт случайно — полем внутри снимков крашей
или OOM, потому что их кладёт туда само ядро. Нет снимков — нет и версии.
Версии самого приложения в отчёте не было никогда. При этом первый вопрос по
любому отчёту — на какой сборке воспроизводить, и ответить на него отчёт не
мог.

## 🔧 Процесс — код версии выводится из самой версии

Для вас ничего не меняется: обновления ставятся как раньше. Речь о том, как
нумеруются сборки.

Android упорядочивает обновления по целому числу `versionCode`. До сих пор им
было число коммитов в истории — величина, которая говорит, сколько раз
кто-то закоммитил, а не какая это версия. Из-за этого версию нельзя было
прочитать из исходников, а именно так её ищет F-Droid. Автообновление в их
каталоге поэтому было выключено, и каждая версия требовала ручного
merge request.

Теперь число выводится из самой версии: `2.20.0` для arm64 даёт `22000502`,
где разряды несут major, minor, patch, стадию (кандидат, релиз, заплатка) и
архитектуру. Архитектура стоит последней цифрой намеренно — F-Droid
сортирует по этому числу, и когда архитектура попадает в старшие разряды,
старая сборка под x86_64 оказывается «новее» новой под armv7, а список версий
едет вперемешку.

У установленной у вас сборки число намного меньше (3606 для arm64), новая
схема заведомо выше — обновления продолжают работать. Проверено на
устройстве.

## ✅ Тесты

2941 тест зелёный, анализатор чист, все четыре чекера локализации по нулям.

Сканирование QR и экспорт бэкапа проверены на устройствах (04.08.2026):
эмулятор телефона API 34 и эмулятор Android TV API 31. Поля с версиями тоже
проверены на устройстве (05.08.2026, телефон). У агрегированного
предупреждения — четыре собственных теста.

Смена схемы versionCode проверена на устройстве (05.08.2026, эмулятор arm64
на Android 14): сборка со старым числом обновляется на новое без удаления, а
равное число по-прежнему ставится — на это свойство опираются локальные
dev-сборки.

Исправление зависания на устройстве не проверено: для воспроизведения нужна
подписка в несколько сотен узлов, обычный конфиг до порога зависания не
доходит. Kotlin компилируется чисто.

</details>

---

## 📲 Install

```bash
adb install -r LxBox-v2.20.0-arm64-v8a.apk
```

Без uninstall! Поверх существующей установки. Настройки и подписки сохранятся.

No uninstall needed — install over the existing one. Settings and
subscriptions are preserved.

---

Previous release / Предыдущий релиз: [v2.19.7](docs/releases/v2.19.7.md).
