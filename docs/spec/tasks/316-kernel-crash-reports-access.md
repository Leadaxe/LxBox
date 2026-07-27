# §316 — Доступ к краш-репортам ядра через Debug API

**Тип:** таска (диагностика)
**Статус:** реализована и device-verified 27.07.2026 (обе половины)
**Связано:** §038 (stderr-канал ядра), §173/§271 (`SetupOptions` при переезде на libbox 1.14), §010 (Go-stderr на ColorOS уходит в `/dev/null`), §027 (файлы переехали в internal storage)

---

## 1. Проблема

Ядро упало трижды (26–27.07): `Fatal signal 6 (SIGABRT) in tid … (DefaultDispatch)`,
один фрейм — `libbox.so` с голым адресом, без символов. Причина паники
недоступна: Go пишет трейс в stderr, а на Android stderr процесса уходит
в `/dev/null` (§010). Разобрать краш постфактум **невозможно** — только
гадать по косвенным уликам.

При этом механизм сохранения **уже работает**:

| Звено | Состояние |
|---|---|
| `redirectStderr` + `debug.SetCrashOutput` | есть в ядре (`experimental/libbox/setup.go:101`), зовётся на каждом `Setup()` |
| Включён ли у нас | да — `crashReportSource = "lxbox"` ([BoxApplication.kt:114](../../../app/android/app/src/main/kotlin/com/leadaxe/lxbox/vpn/BoxApplication.kt:114)) |
| Куда пишет | `workingPath/CrashReport-lxbox.log`, где `workingPath` = `context.filesDir` |
| Ротация | ядро само архивирует прошлый репорт и `.old` в `workingPath/crash_reports/` |
| Читает ли Debug API эту папку | **НЕТ** — см. ниже |

**Разрыва два, и второй серьёзнее.**

1. В whitelist `/files/local` лежали только `stderr.log` и `cache.db` — имя
   `CrashReport-lxbox.log` туда не внесли при переезде на libbox 1.14 (§173).
   Архив в подпапке `crash_reports/` недостижим отдельно: `_assertSafeName`
   режет любой путь со слэшем (защита от traversal).

2. **Путь был неверным.** Диагностика ходила в
   `getApplicationDocumentsDirectory()`, а это у Flutter
   `/data/user/0/<pkg>/app_flutter`. Ядро же пишет в native
   `Context.filesDir` = `/data/user/0/<pkg>/files`. **Разные папки.**
   Комментарий в `stderr_reader.dart` («`getApplicationDocumentsDirectory()`
   соответствует Android `filesDir`») — унаследованное от §038 заблуждение.

Следствие пункта 2: **§038-канал stderr не работал вообще, с самого
введения** — не только краш-репорты. Оба эндпоинта (`/files/local?name=
stderr.log` и `/diag/stderr`) молча возвращали «файла нет», потому что
искали не там. Device-verified §316: до фикса `CrashReport-lxbox.log` →
404, после → 200.

Итог: история крашей ядра на устройстве **есть**, но была недоступна
дважды — по имени и по пути.

## 2. Решение

Открыть существующие файлы, не трогая ядро. **Две половины:** доступ для
разработчика (Debug API, §2.0-2.3) и доступ для ПОЛЬЗОВАТЕЛЯ (UI, §2.4-2.7).
Без второй половины краши у пользователей по-прежнему уходят в никуда — а
именно ради них канал и нужен.

### 2.0 Правильный путь (корень пункта 2)

Native-метод `getFilesDir` отдаёт реальный `Context.filesDir`; Dart-обвязка
`BoxVpnClient.getFilesDir()`; `files.dart` резолвит базу через него с
фоллбэком на Dart-путь (нужен юнит-тестам, где MethodChannel не поднят).

Заодно чинится `/diag/stderr` и `StderrReader` — они получают ту же базу.

### 2.1 Whitelist текущего репорта

`_localWhitelist` += `CrashReport-lxbox.log`, `CrashReport-lxbox.log.old`.
Имя совпадает с `crashReportSource` из `BoxApplication` — константа
`kCrashReportBaseName` рядом с whitelist'ом, чтобы связь была явной.

### 2.2 Архив прошлых крашей

Новые роуты (образец — `/files/srs/list` + `/files/srs`):

| Роут | Ответ |
|---|---|
| `GET /files/crash/list` | `[{name, size, mtime}]` — содержимое `crash_reports/`, новые первыми |
| `GET /files/crash?name=<n>` | тело конкретного архивного репорта |

`_assertSafeName` переиспользуется как есть (basename-only) — подпапка
задаётся сервером, не клиентом, traversal невозможен.

### 2.3 Почему не расширяем `_localFile` путями

Соблазн — разрешить `name=crash_reports/foo.log`. Отвергнуто: гейт
`_assertSafeName` — единственная защита от traversal на этом эндпоинте,
ослаблять её ради удобства нельзя. Отдельный роут с фиксированной
подпапкой безопаснее по построению.

### 2.4 UI-канал читает НЕ ТОТ файл (корень второй половины)

`StderrReader` читает `stderr.log` — имя из схемы ДО libbox 1.14, когда
`redirectStderr` звался вручную. На 1.14 ядро пишет `CrashReport-<source>.log`
(§173-переезд), файла `stderr.log` больше не существует. Значит обе
пользовательские кнопки в Diagnostics («Share stderr», «Share dump») молча
отдают пустоту — та же ошибка, что с путём, только по имени.

Фоллбэк на `stderr.log` **не делаем** (решение юзера): пользователи
переставят приложение, а тянуть мёртвое имя ради теоретических старых
установок — мусор. `StderrReader` читает `CrashReport-lxbox.log`, точка.

### 2.5 Экран «Crash reports» в Diagnostics

Кнопка открывает список репортов, **новые первыми**: дата-время (из mtime,
локальная зона) + размер. Тап по строке → системный share конкретного файла
(тот же `Share.shareXFiles`, что у существующей кнопки stderr).

Список = архив `crash_reports/` + текущий `CrashReport-lxbox.log`, если он
непустой (текущая сессия ещё не архивирована ядром).

Пустой список → «No crash reports» вместо пустого экрана: «крашей не было» —
это хорошая новость, а не поломка.

### 2.6 Ротация: 10 последних

Архив наполняет **ядро** (перекладывает прошлый репорт при каждом `Setup()`)
и **не ограничивает** его размер — папка растёт без предела. Чистим мы:
на старте приложения, после `Setup()`, удаляем всё кроме 10 свежих по mtime.

Почему на старте, а не при открытии экрана: пользователь в Diagnostics может
не заходить годами, а папка растёт от каждого запуска.

### 2.7 Плашка «ядро падало» — ОДИН раз на краш

При старте: если в архиве есть репорт свежее последнего показанного —
баннер на главном (`app_banner.dart`, §116-механизм) с тапом на share.

«Один раз» привязано к КОНКРЕТНОМУ крашу, не к факту показа: в storage
храним имя+mtime последнего показанного файла. Совпало с самым свежим —
молчим (повторный запуск), не совпало — показываем (новый краш). Иначе
получилось бы либо «показали дважды», либо «новый краш промолчал».

### 2.8 Архив в dump-pack

`DumpBuilder` кладёт `crash_archive: [{name, mtime, content}]` — одна кнопка
«Share dump» отдаёт всю историю паник вместе с остальной диагностикой.
Поле `stderr_log` остаётся (теперь непустое — читает правильный файл).

## 3. Граница применимости (важно)

`debug.SetCrashOutput` ловит **паники Go-рантайма**. НЕ покрывает:

- SIGSEGV в cgo/нативном коде вне Go;
- `abort()` из JNI, когда колбэк бросил исключение (§050/§128) — там
  процесс умирает раньше, чем Go успевает записать;
- kill системой (LMK/OOM-killer) — процесса просто нет.

Поэтому пустой/отсутствующий репорт при наличии tombstone — **сам по себе
диагностический сигнал**: краш пришёл не из Go-паники. Это записано в
DIAGNOSTICS, чтобы не искать файл там, где его быть не может.

## 4. Изменения

1. [handlers/files.dart](../../../app/lib/services/debug/handlers/files.dart) —
   whitelist + два роута + листинг архива + резолв базы через native.
1a. [VpnPlugin.kt](../../../app/android/app/src/main/kotlin/com/leadaxe/lxbox/vpn/VpnPlugin.kt),
   [box_vpn_client.dart](../../../app/lib/vpn/box_vpn_client.dart),
   [method_names.dart](../../../app/lib/vpn/box_vpn_client/method_names.dart) —
   метод `getFilesDir`.
2. [handlers/help.dart](../../../app/lib/services/debug/handlers/help.dart) —
   баннер + машинный каталог (урок ревью §311: роут без `/help` не находят).
3. [docs/DIAGNOSTICS.md](../../DIAGNOSTICS.md) — раздел «ядро упало»: порядок
   действий + граница применимости.
4. [docs/api/debug-api-reference.md](../../api/debug-api-reference.md) — роуты.

**Пользовательская половина:**

5. [stderr_reader.dart](../../../app/lib/services/stderr_reader.dart) —
   `StderrReader` читает `CrashReport-lxbox.log` (фоллбэка на `stderr.log`
   нет); рядом `CrashReports` — `baseDir()` / `list()` / `prune(keep: 10)` /
   `stamp()` и константы `kCrashReportBaseName` / `kCrashArchiveDir` /
   `kCrashKeep`. `files.dart` переиспользует их, а не дублирует.
6. [crash_reports_screen.dart](../../../app/lib/screens/crash_reports_screen.dart)
   — экран списка (дата-время `formatDateTime` + размер, share по тапу,
   пометка «current session»); вход —
   [diagnostics_tab.dart](../../../app/lib/screens/app_settings_screen/widgets/diagnostics_tab.dart),
   пункт ВЫШЕ раздела «Developer» (файл нужен обычному пользователю).
7. [crash_share.dart](../../../app/lib/services/crash_share.dart) — общий
   `shareCrashReport()` для плашки и экрана.
8. [dump_builder.dart](../../../app/lib/services/dump_builder.dart) —
   `crash_archive` в dump-pack; тело каждого файла режется на 64 KB с
   пометкой `truncated` (паника с сотней горутин бывает на сотни KB, решает
   голова трейса).
9. [crash_banner_state.dart](../../../app/lib/services/crash_banner_state.dart)
   — `CrashBannerState` (singleton `ChangeNotifier`) + storage-ключ
   `shown_crash_stamp` (в `_appFeatureFlagVars`, иначе теряется при restore).
   **Не поле `HomeState`:** тот — проекция состояния туннеля, а этот факт
   приходит с файловой системы и к жизненному циклу VPN отношения не имеет.
   [app_banner.dart](../../../app/lib/screens/home/widgets/app_banner.dart) —
   баннер `core_crash` под флагом `crashPending`.
10. [main.dart](../../../app/lib/main.dart) — `prune()` + `refresh()` на
    старте, неблокирующе (`unawaited`).

**Попутно (не планировалось спекой):** плашки главного экрана не
локализовались вовсе — `activeBanners` отдавала голые литералы, а
`BannerStack` рисовал их как есть. Обёрнуты в `getLocalText.s` в самой
`activeBanners` (перевод в точке рендера сканер `ui_check` не видит —
динамический аргумент), 4 строки заведены в словарь.

## 5. Тесты

`test/services/debug/crash_files_handler_test.dart`:

1. `/files/local?name=CrashReport-lxbox.log` — отдаёт содержимое.
2. `.old` — тоже в whitelist.
3. Не-whitelist имя → 404 `not whitelisted`.
4. `/files/crash/list` — сортировка по mtime (новые первыми), поля
   `name/size/mtime`.
5. `/files/crash/list` при отсутствии папки → `[]` (не 404: «крашей не
   было» — валидное состояние).
6. `/files/crash?name=…` — тело; несуществующее имя → 404.
7. Traversal (`../`, `/`, ведущая точка) → 400 на обоих роутах.

`test/services/crash_reports_test.dart` (пользовательская половина, 15 шт.):

8. `StderrReader.read()` берёт `CrashReport-lxbox.log`; `stderr.log`
   игнорируется даже если существует (фоллбэка нет — решение юзера); пустой
   файл = «паник не было» (ядро пересоздаёт его на каждом `Setup()`).
9. `list()` — архив + текущий (если непуст), новые первыми, с mtime/size и
   флагом `isCurrent`; пустой текущий в список не попадает.
10. `prune(keep: 10)` — удаляет только лишние (самые старые), 10 свежих целы;
    при ≤10 файлах не трогает ничего; текущий репорт не трогает никогда.
11. Баннер: новый краш → показывается; повторный старт с тем же файлом →
    молчит; следующий (более свежий) → снова показывается; `markShown` без
    pending — no-op (не затирает отметку пустотой).

`test/screens/app_banner_test.dart` — `crashPending` → плашка `core_crash`
(error-палитра, тап + крестик, без auto-dismiss); сосуществует с остальными.

Тело `crash_archive` в dump-pack тестом не покрыто: `DumpBuilder.build()`
тянет `BoxVpnClient`/`AppLog`/`SubscriptionController` — на юнит-стенде это
полуинтеграционный тест ради одного поля. Проверяется на устройстве (§6).

## 6. Device-verify

Выполнено 27.07.2026 (CPH2411, ядро rc.3):

1. До фикса пути: `GET /files/local?name=CrashReport-lxbox.log` → **404**
   (файл искался в `app_flutter`).
2. После: → **200**, 0 байт (репорт пересоздан ядром при переустановке —
   `os.Create` на каждом `Setup()`, паник с тех пор не было).
3. `GET /files/crash/list` → `[]` (архива нет: ядро архивирует прошлый
   репорт только если тот непустой).
4. `/diag/stderr` → 200 (был 404) — §038-канал ожил тем же фиксом.

Краши 26–27.07 разобрать постфактум не удалось: файлы были потеряны до
того, как канал открылся. Следующий краш ядра будет читаемым.

**Пользовательская половина** — проверено 27.07.2026 на той же сборке
(`2.17.0-dev.26`, ядро `1.14.0-lx.16`): экран Diagnostics → «Crash reports»
открывается и на чистом устройстве показывает «No crash reports»;
`/files/crash/list` → `[]`, текущий репорт 0 байт (ядро пересоздаёт его на
каждом `Setup()`), `shown_crash_stamp` в storage отсутствует — то есть
согласованное «паник не было».

Сценарии С содержимым (список, плашка, ротация 11→10) проверяются на живом
краше: Debug API файлы только читает, а `run-as` на release-сборке
недоступен (`package not debuggable`) — подложить тестовый репорт нечем.
Логика этих веток покрыта юнит-тестами (§5).
