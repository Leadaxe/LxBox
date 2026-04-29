# 038 — Crash diagnostics

| Поле | Значение |
|------|----------|
| Статус | Done (MVP1 + MVP2) |
| Дата | 2026-04-29 |
| Зависимости | [`023 debug and logging`](../023%20debug%20and%20logging/spec.md), [`031 debug api`](../031%20debug%20api/spec.md), [`012 native vpn service`](../012%20native%20vpn%20service/spec.md) |

## Цель

Дать пользователю однокнопочный путь отдать stacktrace последней сессии VPN core разработчику, без `adb`. Главный кейс — нативный краш sing-box / libbox при старте VPN, когда процесс умирает SIGABRT'ом и in-memory `AppLog` теряется.

**Не в скопе:**
- Tombstone parsing / pretty-print — текстом разбирается на стороне разработчика.
- Внешние сервисы (Crashlytics / Sentry / breakpad) — никогда; локально, off-line.
- Retention / UI-список крашей / автоматический snackbar «Previous session crashed» — всё в `DumpBuilder` через ⤴ Share dump.

---

## Архитектура — четыре канала

| Канал | Что ловит | Где переживает смерть процесса |
|---|---|---|
| **A. stderr-redirect** | Go panic stacktrace из libbox/sing-box — всё что Go runtime пишет в stderr перед SIGABRT'ом | `filesDir/stderr.log` |
| **B. ApplicationExitInfo** (API 30+) | native SIGABRT/SIGSEGV, JVM Throwable, ANR, LMK; tombstone в `traceInputStream` для NATIVE_CRASH; Java stacktrace для CRASH (на некоторых OEM пуст) | в Android-системе, читается ленивым запросом из `DumpBuilder` |
| **C. Persistent AppLog** | warning + error JVM-events до краха (что приложение делало в моменте) | `filesDir/applog.txt`, ring-buffer ~200 строк |
| **D. Logcat tail** | system-level логи нашего процесса: `AndroidRuntime FATAL EXCEPTION` (Java throwable), `libc`/`DEBUG`/`tombstoned` (native signal+backtrace), `art`/`linker` (class-load failures) | kernel circular buffer, читается через `Runtime.exec("logcat -d")` |

`A` ловит Go panic, но только если процесс дожил до `Libbox.redirectStderr`. `B` ловит то что убило процесс уровнем системы. `C` ловит JVM-сторону — что мы делали. `D` — независимый источник от B (logd — kernel-buffer, AEI — ActivityManager); полезен на API <30 где B недоступен, и на OEM-устройствах где B не прикладывает trace для `REASON_CRASH` (Samsung One UI quirk). Вместе закрывают post-mortem без `adb`.

---

## MVP1 — stderr viewer (канал A)

### Контракт `Libbox.redirectStderr`

Подключён в [`BoxApplication.initializeLibbox`](../../../app/android/app/src/main/kotlin/com/leadaxe/lxbox/vpn/BoxApplication.kt):

- При вызове `Libbox.redirectStderr(path)` Go runtime через `dup2(file_fd, STDERR_FILENO)` перенаправляет свой stderr в указанный файл.
- При panic'е без `recover()` Go runtime пишет полный multi-goroutine stacktrace в stderr **до** SIGABRT'а.
- Файл — `Context.filesDir / stderr.log` (= `/data/data/<pkg>/files/stderr.log`), internal app-scoped storage. Там же где `SettingsStorage`, `ConfigManager`, `cache.db`. См. [task 027](../../tasks/027-libbox-init-race-fix.md) про переход с external на internal.

### История крашей не накапливается

Намеренно: показываем только последнюю сессию. Никаких `.old`-копий, ротации, retention. Цель MVP1 — закрыть текущий инцидент. История появится в MVP2/MVP3 с retention'ом и UI-списком.

### Чтение из Dart

`lib/services/stderr_reader.dart`:

```dart
class StderrReader {
  static Future<String?> read();   // null если файл отсутствует/пуст
  static Future<String?> path();   // путь или null
}
```

Через `path_provider` `getApplicationDocumentsDirectory()`. Симметрично `§031 Debug API` `_localFile` handler'у.

### UI

[`Debug-экран`](../../../app/lib/screens/debug_screen.dart) — на `initState` async читает stderr; если непустой → `DefaultTabController(length: 2)` с `TabBar`:

- **Log** — events с фильтрами/search/share-dump.
- **stderr** — `SelectableText` (monospace) + Refresh + Share.

Если файл пустой — без TabBar, экран как раньше.

### Share

Два пути:

1. **Кнопка Share на вкладке stderr** — отдаёт `stderr.log` через `share_plus`.
2. **Кнопка Share dump (⤴ AppBar)** — `DumpBuilder.build()` включает поле `stderr_log` в JSON-pack рядом с `config + vars + server_lists + debug_log`. Если stderr пустой → `null`.

## Безопасность

- Stderr содержит имена outbound'ов и иногда host'ы; **пароли — нет** (Go panic пишет stack-frames, не входной JSON).
- `filesDir/stderr.log` — internal app-scoped storage, недоступно другим apps. Не в Downloads / external.

---

## MVP2 — ApplicationExitInfo (B) + Persistent AppLog (C) + Logcat tail (D)

### ApplicationExitInfo (lazy в DumpBuilder)

Native MethodChannel-метод `getApplicationExitInfo` в [`VpnPlugin`](../../../app/android/app/src/main/kotlin/com/leadaxe/lxbox/vpn/VpnPlugin.kt):

- На API <30 — возвращает пустой массив (никакого AEI на старых Android).
- На API 30+ — `ActivityManager.getHistoricalProcessExitReasons(packageName, 0, 5)` → массив структур: `timestamp`, `reason` (mapped в человекочитаемое имя `CRASH | CRASH_NATIVE | ANR | LOW_MEMORY | …`), `description`, `importance`, `pss`, `rss`, `status`, `trace` (`traceInputStream` целиком в string — для NATIVE_CRASH это mini-tombstone).

Зовётся **только из `DumpBuilder.build()`**. Ленивое: пользователь жмёт ⤴ Share dump → дамп включает поле `exit_info: [...]` с последними 5 экзитами. Не на старте app'а — чтобы не дёргать тяжёлый `traceInputStream` зря и не усложнять lifecycle'ом нашего кода.

### Persistent AppLog (file-backed ring-buffer)

В [`AppLog`](../../../app/lib/services/app_log.dart) добавляется persistence для **только warning + error** уровней. `debug`/`info` остаются in-memory (это шум, не нужен после рестарта).

- **Файл**: `filesDir/applog.txt`, JSON-lines (одна запись на строку).
- **Cap**: 200 entries или ~64KB — что меньше.
- **Write**: async через `Future.microtask` с debounce-флагом (`isWriting`/`isDirty`); при каждом новом warning/error планируется rewrite файла. Spam'ы schedule'ятся в один write.
- **Read**: на старте `main()` зовётся `AppLog.I.initPersistent()` → entries из файла кладутся в `_entries` с маркером `fromPreviousSession=true`. Live-events после старта попадают на верх как обычно.

UI [`debug_screen.dart`](../../../app/lib/screens/debug_screen.dart) — entries с `fromPreviousSession=true` визуально отделены (subtitle-тег «← prev session», иконка `↑`). Не блокируют текущий лог.

`DumpBuilder.debug_log` автоматически содержит и persistent, и live entries — отдельного поля не нужно.

### Logcat tail (lazy в DumpBuilder)

Native MethodChannel `getLogcatTail` в [`VpnPlugin`](../../../app/android/app/src/main/kotlin/com/leadaxe/lxbox/vpn/VpnPlugin.kt) — `Runtime.exec("logcat", "-d", "-t", count, "*:level")` через `ProcessBuilder` с timeout 2s. Возвращает text-snapshot kernel-буфера.

`logd` UID-фильтрует автоматически — без `READ_LOGS` permission читатель получает только события собственного UID и связанные system messages (`libc`/`DEBUG`/`tombstoned` пишутся под нашим pid'ом перед смертью). Permission не запрашивается.

[`LogcatReader.tail()`](../../../app/lib/services/logcat_reader.dart) Dart-сервис, зовётся из `DumpBuilder.build()` → поле `logcat_tail: String?`. Default — последние 1000 строк уровня Error+Fatal (`*:E`).

### Безопасность

- AEI tombstone — безопасно (memory addresses, регистры, имена SO; user-data нет).
- `applog.txt` — warning/error что юзер и так видит в Debug-экране. Маскирование URL-секретов уже работает в существующих модулях.
- Logcat — UID-фильтрован logd'ом, только наш процесс.

---

## Сводка реализации

| Канал | Status | Tasks |
|---|---|---|
| A (stderr viewer) | done | [018](../../tasks/018-stderr-viewer-debug-tab.md) |
| B (ApplicationExitInfo) | done | [029](../../tasks/029-application-exit-info.md) |
| C (Persistent AppLog) | done | [028](../../tasks/028-persistent-applog.md) |
| D (Logcat tail) | done | [022](../../tasks/022-logcat-tail-in-dump.md) |
| HTTP API `/diag/*` | done | см. [§031 Debug API](../031%20debug%20api/spec.md) |
