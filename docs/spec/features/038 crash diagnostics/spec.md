# 038 — Crash diagnostics (Go panic visibility & Android exit info)

| Поле | Значение |
|------|----------|
| Статус | Draft (MVP1 — stderr viewer — в работе) |
| Дата | 2026-04-29 |
| Зависимости | [`023 debug and logging`](../023%20debug%20and%20logging/spec.md), [`031 debug api`](../031%20debug%20api/spec.md), [`032 quick connect`](../032%20quick%20connect/spec.md), [`012 native vpn service`](../012%20native%20vpn%20service/spec.md) |

## Цель

Превратить «приложение вылетело» из чёрного ящика в воспроизводимый артефакт, который пользователь может одной кнопкой отдать разработчику. Главный кейс — нативный краш sing-box / libbox в момент старта VPN, когда процесс умирает целиком (SIGABRT) и in-memory `AppLog` теряется.

После §038 при следующем запуске приложения юзер должен видеть в Debug-экране, **что именно убило процесс в прошлый раз**, и иметь возможность поделиться этим одним тапом.

**Не в скопе целиком (для MVP1):**

- ApplicationExitInfo / `getHistoricalProcessExitReasons` API (Android 11+) — будущая работа.
- Per-session breadcrumb / persist last-config — будущая работа.
- Авто-snackbar «Previous session crashed» — будущая работа.
- Tombstone parsing / pretty-print — будущая работа.
- Внешние сервисы (Crashlytics / Sentry / breakpad) — никогда. Локально, off-line, под контролем пользователя.

---

## Архитектура

### Три источника информации (полная картина — для будущих этапов)

| Канал | Что ловит | Где переживает смерть процесса | Этап |
|---|---|---|---|
| **A. ApplicationExitInfo** (API 30+) | native SIGABRT/SIGSEGV, JVM Throwable, ANR, LMK, force-stop. С tombstone в `traceInputStream` для NATIVE_CRASH. | в Android-системе, читается при следующем `Application.onCreate()` | future |
| **B. stderr-redirect** | Go panic stacktrace из libbox/sing-box (всё что Go runtime пишет в stderr перед SIGABRT'ом) | в `external/stderr.log` (последняя сессия — без накопления истории) | **MVP1** |
| **C. Session breadcrumb** | факт «start был, штатного stop'а не было» + конфиг сессии | в `filesDir/crash_dumps/session_<sid>.json` + `last_config_<sid>.json` | future |

`A` и `B` перекрываются на API 30+ (хорошо — взаимная сверка). `B` покрывает Android 8-10, где `A` нет. `C` даёт контекст «на каком конфиге упало», без которого stacktrace часто бесполезен.

MVP1 покрывает только `B` — это самое маленькое, но и самое полезное в моменте: Go panic'и (как тот, что был с VLESS `packet_encoding: "none"` в task [012](../../tasks/012-vless-packet-encoding-libbox-panic.md)) — главная категория крашей при старте VPN, и для них stderr-stacktrace даёт точный ответ.

---

## MVP1 — stderr viewer

### Контракт `Libbox.redirectStderr`

Уже подключён в [`BoxApplication.initializeLibbox`](../../../app/android/app/src/main/kotlin/com/leadaxe/lxbox/vpn/BoxApplication.kt). Поведение:

- При вызове `Libbox.redirectStderr(path)` Go runtime через `dup2(file_fd, STDERR_FILENO)` перенаправляет свой stderr в указанный файл.
- При panic'е без `recover()` Go runtime пишет полный multi-goroutine stacktrace в stderr **до** того, как процесс получит SIGABRT.
- Файл — `Context.getExternalFilesDir(null) / stderr.log` (= `/sdcard/Android/data/<pkg>/files/stderr.log`).

### История крашей не накапливается

Намеренно: показываем **только последнюю сессию**. Никаких `.old`-копий, никакой ротации. Цель MVP1 — закрыть текущий инцидент быстро, не вести лог крашей. Если libbox при следующем cold-start'е перетрёт файл — это ок: пользователь либо успел открыть Debug-экран сразу после краша, либо нет; в обоих случаях бесполезно держать историю на устройстве.

История появится позже — в MVP2 (ApplicationExitInfo) и MVP3 (per-session breadcrumb), там уже с retention'ом и UI-списком крашей.

### Чтение из Dart

Файл лежит в external app-scoped storage (`getExternalFilesDir(null)`), в Dart доступ через [`path_provider`](https://pub.dev/packages/path_provider) → `getExternalStorageDirectory()` (тот же путь). Никакого MethodChannel-метода для чтения **не нужно** — используем `dart:io` `File.readAsString`. Это симметрично тому, как `§031 Debug API` `_externalFile` handler читает тот же файл — оба используют path_provider, не дублируя нативный код.

Сервис: `lib/services/stderr_reader.dart`

```dart
class StderrReader {
  /// Содержимое stderr.log или null если отсутствует/пуст.
  static Future<String?> read();

  /// Путь к файлу — для Share (или null).
  static Future<String?> path();
}
```

### UI

В **Debug-экране** добавляется условный `TabBar`:

- Если `StderrReader.read()` вернул не-null — экран показывает 2 таба:
  - **Log** — текущий контент (events с фильтрами, search, share-dump).
  - **stderr** — `SelectableText` (monospace, 11-12sp), весь текст файла, с кнопкой Refresh и кнопкой Share (открывает share-диалог с `stderr.log`).
- Если файл пустой/отсутствует — экран остаётся как сейчас (без TabBar). Это правило: **stderr-таб не появляется на устройствах где никогда не было краша**.

Перезагрузка stderr содержимого:
- На `initState` асинхронно.
- По кнопке Refresh внутри stderr-таба.
- Не на каждый event AppLog — это файл, не in-memory state, частые I/O не нужны.

### Share

`Share.shareXFiles([XFile(stderr.log)], subject: 'L×Box stderr — <iso-time>')` — переиспользуем уже подключённый `share_plus`.

В отличие от `_shareDump` (который собирает JSON-pack из config + vars + subs + log), share stderr-таба отдаёт **только** stderr-файл — компактнее, без раскрытия конфига юзера (важно: stderr тоже может содержать имена outbound'ов и хосты, но не пароли — Go не дампит входной JSON в stack).

---

## Безопасность

- **Stderr Go panic** содержит имена outbound'ов и иногда хосты (если они попали в строку ошибки). **Пароли — нет** (Go panic пишет stack-frames с локальными переменными, а не оригинальный JSON-конфиг). Перед share — без маскирования; пользователь видит контент в `SelectableText` до share, может оценить.
- `external/stderr.log` лежит в **app-scoped external storage** под uid пакета. На Android 11+ другие приложения этот путь не видят (Scoped Storage). На Android 9-10 видны через MANAGE_EXTERNAL_STORAGE / file pickers — стандартный sandbox Android.
- **Не пишем в shared `Downloads/`** — только в app-private external dir.

---

## Совместимость / поведение по тирам

| Android | Поведение |
|---|---|
| 14+ (API 34+) | Полностью работает. Будущий этап: ApplicationExitInfo даст ещё tombstone. |
| 13 (API 33) | Работает stderr-only (ApplicationExitInfo есть, но в MVP1 не используется). |
| 11–12 (API 30–32) | Работает stderr-only. Primary tier. |
| 8–10 (API 26–29) | Работает stderr-only. Best-effort; ApplicationExitInfo недоступен по API. |

---

## Этапы

| Этап | Содержимое | Статус |
|---|---|---|
| **MVP1 — stderr viewer** | StderrReader service + Debug tab + share (без накопления истории) | done ([task 018](../../tasks/018-stderr-viewer-debug-tab.md)) |
| MVP2 — ApplicationExitInfo reader | reader на API 30+, dump traces в `crash_dumps/aei_<ts>.txt`, секция «Crashes» в Debug-экране | future |
| MVP3 — Session breadcrumb + last-config persist | sessionId, `session_<sid>.json`, `last_config_<sid>.json`, линковка с aei по startedAt | future |
| MVP4 — DumpBuilder integration + UX polish | crash_dumps/ в общий dump-zip, snackbar «Previous session crashed», retention 10/7d | future |

---

## Открытые вопросы

1. **Размер `stderr.log`** — нужно ли cap'ать? В норме файл пустой; при panic'е — 5-50KB. Если кто-то поставит `GODEBUG=schedtrace=1000` и активно используется — может расти. На MVP1 не cap'аем; в MVP4 (DumpBuilder) можно tail-only включать.
2. **Authoritative format в Share** — текстовый file как сейчас; или JSON-обёртка с meta (app version + git sha + libbox version)? MVP1 — plain-text file. MVP3 (с breadcrumb) — будет meta-обёртка автоматически.
