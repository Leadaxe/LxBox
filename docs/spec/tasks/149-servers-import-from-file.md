# 149 — Servers: «Import from file…» в overflow-меню

| Field | Value |
|------|----------|
| Status | Implemented (analyze ✅, device-test pending) |
| Started | 2026-06-18 |
| Trigger | На экране Servers контент добавлялся только из буфера (Paste), визарда (Add server) и публичных тест-серверов. Не было способа импортировать подписку/конфиг из файла — частый кейс, когда юзеру прислали `.txt` со списком URI или `.json`-конфиг. `file_picker` уже подключён и используется на других экранах (config / backup). |
| Related | [§074] (Add server wizard), [Servers screen] `screens/subscriptions_screen.dart` |
| Files touched | EDIT `screens/subscriptions_screen.dart` (импорты, метод `_importFromFile`, пункт меню + ветка `onSelected`) |

## Что сделано

В overflow-меню (⋮) экрана Servers добавлен пункт **«Import from file…»** — в группе «добавить контент извне», сразу после `Scan QR code`:

```
Add server… / Get WARP
──────────
Paste from clipboard / Scan QR code / Import from file…   ← новый
──────────
Get Public Test Servers
──────────
☑ Auto-update subscriptions
```

Обработчик `_importFromFile()`:

1. `FilePicker.pickFiles(withData: true, allowMultiple: false)` — cancel/пустой результат = noop.
2. Читает содержимое: `file.bytes` (in-memory) или fallback `File(path).readAsString()` — паттерн идентичен `config_screen._loadFromFile` / backup.
3. Пустой файл → SnackBar «File is empty».
4. Содержимое (URI-список / JSON-конфиг / proxy-link) идёт в тот же `subController.addFromInput(...)`, что и paste/manual — **парсер сам определяет формат**, отдельной логики разбора не добавляли.
5. Успех → `_regenerateAndSave()` (пересборка конфига + snackbar с числом нод). Ошибка → SnackBar с `lastError`. Исключение → `formatUserError(e)`.

Новые импорты: `dart:io`, `package:file_picker/file_picker.dart`, `services/error_format.dart`.

## Не сделано / out of scope

- Нет предпросмотра/диалога подтверждения как у paste (`showConfirmAddDialog`): импорт из файла — явное действие пользователя, формат подтверждается результатом `addFromInput`.
- Не фильтруем расширения в пикере (`FileType.any`) — content-based парсинг важнее имени файла.
