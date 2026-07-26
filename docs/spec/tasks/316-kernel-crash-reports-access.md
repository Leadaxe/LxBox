# §316 — Доступ к краш-репортам ядра через Debug API

**Тип:** таска (диагностика)
**Статус:** реализовано, device-verified 27.07.2026
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

Открыть существующие файлы, не трогая ядро.

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
