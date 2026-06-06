# 072 — Атомарная и устойчивая к kill'у персистентность `SettingsStorage`

| Поле | Значение |
|------|----------|
| Статус | Released в v1.9.0 |
| Дата | 2026-06-05 |
| Тип | fix (data-loss) |
| Приоритет | high — приводит к полной потере пользовательских данных |
| Зависимости | [`§063 backup format snapshot rewrite`](063-backup-format-snapshot-rewrite.md) (`BackupService.exportRaw`/`replaceRaw` сидят на той же `_cache`) |
| Связанные | `app/lib/services/settings_storage.dart:38-64` (`_load`/`_save`), `app/lib/services/backup_service.dart` (`exportRaw`/`replaceRaw`), `app/lib/services/app_log.dart::AppLog.I` (для логирования факта повреждения), `app/lib/services/migration/proxy_source_migration.dart` (миграция v1→v2 server_lists) |
| Триггер | На устройствах Xiaomi/HyperOS (воспроизведено на Xiaomi Pad 8 Pro) раз в пару дней у приложения **полностью** сбрасываются все пользовательские данные: vars, подписки/server lists, правила, DNS-настройки. На «чистом» Android не воспроизводится. Storage — внутренний (`getApplicationDocumentsDirectory()`), системный клинер ни при чём. |

## Цель

Сделать запись `lxbox_settings.json` атомарной и устойчивой к kill'у процесса в любой точке: читатель всегда видит **либо** предыдущее, **либо** новое полное состояние. Никогда не пустой/обрезанный файл, никогда не молчаливый сброс в `{}`.

## Не в скопе

- Распределение состояния по нескольким файлам (per-section storage) — оставляем один `lxbox_settings.json`. Формат файла не меняется, меняется только механика записи/чтения.
- Шифрование, encrypted-storage, KeyStore — отдельная история.
- WAL / journal / sqlite миграция — overengineering для текущего объёма.
- Изменения в `BackupService` API — только убедиться что `exportRaw`/`replaceRaw` остаются консистентны (см. ниже).
- Любые миграции существующих файлов на диске — формат бэкап-файла (`.bak`) появляется лениво при первой успешной записи после деплоя.

---

## Корневая причина (root cause)

Всё состояние хранится в одном файле `lxbox_settings.json` в `getApplicationDocumentsDirectory()`. Три бага складываются:

### 1. Неатомарная запись (`settings_storage.dart:54-64`)

```dart
static Future<void> _save() async {
  _cache?.remove('node_overrides');
  _cache?.remove('show_detour_servers');
  final data = Map<String, dynamic>.from(_cache ?? {});
  final f = await _file();
  _pendingSave = f.writeAsString(
    const JsonEncoder.withIndent('  ').convert(data),
  );
  await _pendingSave;
  _pendingSave = null;
}
```

`File.writeAsString` — это **truncate-then-write** без `flush: true`. Файл сначала обрезается в ноль, затем пишется. Если HyperOS убивает процесс между truncate и завершением записи (агрессивный kill свёрнутых приложений), на диске остаётся **пустой** или **обрезанный** JSON.

### 2. Молчаливый фолбэк в пустой кэш (`settings_storage.dart:38-52`)

```dart
static Future<Map<String, dynamic>> _load() async {
  if (_cache != null) return _cache!;
  if (_pendingSave != null) await _pendingSave;
  try {
    final f = await _file();
    if (await f.exists()) {
      final raw = await f.readAsString();
      _cache = jsonDecode(raw) as Map<String, dynamic>;
      return _cache!;
    }
  } catch (_) {}        // ← проглатывает FormatException на битом JSON
  _cache = {};          // ← «нет файла» и «битый файл» обрабатываются одинаково
  return _cache!;
}
```

`catch (_) {}` проглатывает `FormatException` на битом JSON, после чего управление проваливается в `_cache = {}`. То есть **«файл повреждён» и «файла нет»** обрабатываются одинаково.

### 3. Закрепление потери

Первый же последующий `setVar`/`save` (автообновление подписок, любой тоггл в UI) пишет пустой `_cache` обратно на диск через тот же неатомарный `_save()` → сброс становится **постоянным**, без шанса на восстановление.

### Почему «раз в пару дней»

Всё состояние в одном файле — одна неудачная запись сносит сразу всё. Интервал = вероятность что kill попадёт в миллисекундное окно записи.

---

## Требуемые изменения

### A. Атомарная запись в `_save()`

```
┌─────────────────────────────────────────────────────────┐
│ _save() — новая схема                                   │
├─────────────────────────────────────────────────────────┤
│ 1. Сериализовать data → utf-8 bytes                     │
│ 2. Если основной `path` существует И валидный JSON →    │
│    copy(path, `${path}.bak`) — обновляем backup до      │
│    того как тронем основной.                            │
│ 3. Записать во временный `${path}.tmp` c flush: true.   │
│ 4. await tmp.rename(path) — атомарная замена в пределах │
│    одной ФС (POSIX rename guarantees).                  │
│ 5. _pendingSave = null.                                 │
└─────────────────────────────────────────────────────────┘
```

- Шаг 2 (`.bak` snapshot) делается **только из** валидного основного — нет смысла плодить второй битый файл.
- `flush: true` обязателен на `.tmp` write — без него POSIX `rename` может зафиксировать pointer на ещё не сброшенные dirty pages.
- Шаг 4 — `File.rename` в Dart обёртка над `rename(2)` POSIX, атомарна в пределах одной filesystem mount (все наши файлы в одной — `getApplicationDocumentsDirectory()`).

### B. Восстановление и различение случаев в `_load()`

```
┌─────────────────────────────────────────────────────────┐
│ _load() — decision tree                                 │
├─────────────────────────────────────────────────────────┤
│                                                         │
│  path exists?                                           │
│   │                                                     │
│   ├─ no → return {}  (legitimate fresh install)         │
│   │                                                     │
│   └─ yes → parse JSON                                   │
│            │                                            │
│            ├─ ok  → return parsed                       │
│            │                                            │
│            └─ fail → bak exists?                        │
│                       │                                 │
│                       ├─ yes → parse bak                │
│                       │         │                       │
│                       │         ├─ ok → восстановить:   │
│                       │         │       1. логировать   │
│                       │         │          recovery     │
│                       │         │       2. _cache = bak │
│                       │         │       3. _save()      │
│                       │         │          перезапишет  │
│                       │         │          main из bak  │
│                       │         │                       │
│                       │         └─ fail → drop          │
│                       │                  (см. ниже)     │
│                       │                                 │
│                       └─ no → drop                      │
│                                                         │
│  drop:                                                  │
│   1. AppLog.I.error('SettingsStorage: corrupted main    │
│      file, no recoverable backup. Manual fix needed.    │
│      Path: ...')                                        │
│   2. _cache = {}                                        │
│   3. **НЕ** перезаписывать main автоматически —         │
│      оставляем для ручной диагностики/recovery.         │
│      Следующий setVar/save заметит «main существует     │
│      но мы знаем что он битый» через флаг               │
│      _mainIsCorrupted = true — и тогда уже разрешим     │
│      перезапись (юзер начал заново вводить данные).     │
└─────────────────────────────────────────────────────────┘
```

**Ключевое отличие от текущей логики**: «main существует и битый» **≠** «main отсутствует». Первое — потеря данных, требует попытки recovery + явного логирования. Второе — fresh install, тихо вернуть `{}`.

### C. Совместимость с `_pendingSave`

`_pendingSave` сейчас используется в `_load()` для «жди завершения записи прежде чем читать» (line 41). С новой схемой `_save()` всё ещё ставит/снимает `_pendingSave` ровно вокруг tmp-write + rename. Семантика «pending write завершён → видимый на диске результат — последняя запись» сохраняется.

### D. Очистка `.tmp` от прошлых сбоев

В начале `_load()` (или ленивее — в `_save()` перед записью) сделать best-effort delete `${path}.tmp` если он остался после прошлого fail'нувшего save. Без этого `.tmp` накапливается мусор и потенциально путает recovery (мы знаем что `.tmp` не консистентен — он был оборван kill'ом).

---

## Файлы

- `app/lib/services/settings_storage.dart` — переписать `_load` + `_save`, добавить статический флаг `_mainIsCorrupted` (только in-memory, сбрасывается на `resetCacheForTesting`).
- `app/lib/services/backup_service.dart` — **read-only audit**: убедиться что `exportRaw` (читает `_cache`) и `replaceRaw` (заменяет `_cache` + `_save`) автоматически наследуют атомарность. Кодовых изменений не должно быть.
- `app/test/services/settings_storage_test.dart` — **NEW**, набор unit-тестов (см. ниже).
- `app/lib/services/app_log.dart` — read-only, использовать существующий `AppLog.I.error` для логирования факта повреждения. Не менять API.

## Не трогаем

- Формат `lxbox_settings.json` — schema идентична.
- Миграции (`proxy_sources → server_lists`, `app_rules → custom_rules`, presets-migration) — они работают поверх distinct schema keys, к ним атомарность ортогональна.
- Любые публичные API (`getVar`/`setVar`/`getServerLists`/...) — сигнатуры не меняются.
- `resetCacheForTesting()` — расширить чтобы сбрасывал `_mainIsCorrupted` тоже.

---

## Критерии приёмки

1. Прерывание процесса в любой момент `_save()` не приводит к потере данных: читатель видит **либо** предыдущее (через `.bak`), **либо** новое полное состояние (rename уже произошёл).
2. Битый/обрезанный основной файл при наличии валидного `.bak` приводит к прозрачному recovery + логированию (`AppLog.I` запись с уровнем `error`).
3. Повреждённый основной файл **не перезаписывается** пустым кэшем автоматически на чтении. Перезапись разрешается только после явного `setVar`/`save` от пользователя (т.е. юзер начал заново).
4. Все существующие тесты в `app/test/` проходят. Миграции v1→v2 не сломаны.
5. `.tmp` не остаётся на диске после успешного `_save()` (rename должен консумировать).
6. Round-trip backup export → replace остаётся консистентным (см. `BackupService` audit).

---

## Тесты (`app/test/services/settings_storage_test.dart` — NEW)

Использовать паттерн ротации `getApplicationDocumentsPath()` между прогонами + `resetCacheForTesting()` (уже применяется в `update_checker_test.dart` / `backup_service_test.dart`).

| # | Сценарий | Ожидание |
|---|----------|----------|
| 1 | `setVar('a','1')` → restart cache → `getVar('a','def')` | `'1'` (sanity round-trip) |
| 2 | На диске основной файл — невалидный JSON (`'not json'`), `.bak` — валидный с `{vars:{a:'1'}}` | `_load` восстанавливает из `.bak`, `getVar('a','def') == '1'`, в `AppLog` есть error-entry про recovery |
| 3 | На диске основной — невалидный, `.bak` отсутствует | `_load` возвращает `{}`, основной файл **не перезаписан** (содержимое осталось битым), в `AppLog` есть error про unrecoverable corruption |
| 4 | На диске основной — пустой файл (truncate в ноль, `0 bytes`) | Не трактуется как валидные пустые настройки; идёт попытка recovery через `.bak` (или drop с логом если `.bak` нет) |
| 5 | После успешного `_save()` — на диске нет `${path}.tmp` | `tmp` отсутствует (rename консумировал) |
| 6 | Регрессия: на диске лежит **валидный** существующий файл старого формата (`proxy_sources` без `server_lists`) → `getServerLists()` | Возвращает мигрированный list (миграция `proxy_sources → server_lists` отработала как прежде) |
| 7 | После drop (сценарий 3) → `setVar('new','x')` → restart cache → `getVar('new','def')` | `'x'` (юзер может писать поверх битого main; `_mainIsCorrupted` сбросился после первой явной перезаписи) |
| 8 | `_save()` падает (например через mock тайм-инжекцию) **после** копирования в `.bak`, но **до** rename → restart cache → `_load()` | Видит старый main (предыдущая консистентная версия — rename не произошёл), `.bak` снэпшот того же поколения |

---

## Риски / open questions

| # | Риск | Решение |
|---|------|---------|
| R1 | `File.rename` через `MethodChannel`/Dart IO на Android — не каждая FS гарантирует atomicity. | `getApplicationDocumentsDirectory()` всегда на app-internal storage (ext4/f2fs, single mount) → `rename(2)` атомарен. Документируем в коде. |
| R2 | `.bak` тоже может оборваться kill'ом если копирование сделано write+flush. | `.bak` создаётся **до** записи нового `.tmp` (последовательно). Если kill между copy и tmp-write — `.bak` целый, main целый, юзер не теряет ничего. Если kill между tmp-write и rename — main целый, `.bak` целый, новые данные потеряны но **старые сохранены**. |
| R3 | Двойной write (`.bak` + `.tmp`) удваивает дисковое время → видимый lag на UI при больших `_cache`. | `lxbox_settings.json` в продовых юзкейсах — единицы-десятки KB. Удвоение незаметно. Если когда-то вырастет до MB — рассмотреть skip-bak при unchanged-data check (hash сравнение). |
| R4 | `_mainIsCorrupted` — in-memory state, теряется на рестарте процесса. После рестарта `_load` снова видит битый main → drop loop. | Это корректно. На каждом старте мы делаем попытку recovery (вдруг `.bak` появился через ручной восстанов). Если каждый раз drop — это правильный сигнал что нужна ручная диагностика. |
| R5 | `BackupService.replaceRaw` пишет `_cache` через `_save()` — атомарность наследуется. Но restore из backup'а **сбрасывает** `_mainIsCorrupted` через `resetCacheForTesting`-подобный flow? | Аудит: `replaceRaw` должен сбрасывать `_mainIsCorrupted` после успешного `_save()` (он же только что перезаписал main). Уточнить в impl. |

---

## История

- 2026-06-05 — Draft. Триггер: incident report Xiaomi Pad 8 Pro, периодическая потеря всех настроек ~раз в 2 дня. Root cause analysis оператором.
