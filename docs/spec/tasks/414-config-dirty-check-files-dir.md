# 414 — Dirty-check конфига искал `singbox_config.json` не в том каталоге

| Поле | Значение |
|------|----------|
| Статус | Done |
| Дата старта | 2026-09-03 |
| Дата завершения | 2026-09-03 |
| Коммиты | см. ветку задачи |
| Связанные spec'ы | [features/076 settings-and-config-lifecycle](../features/076%20settings-and-config-lifecycle/spec.md), [tasks/113](113-false-config-changed-banner.md), [tasks/316](316-kernel-crash-reports-access.md), [features/012 native vpn service](../features/012%20native%20vpn%20service/spec.md) |

## Проблема

`ConfigDirtyCheck` (§076) на запуске сравнивает mtime `lxbox_settings.json`
и `singbox_config.json`: настройки новее → конфиг устарел → тихая
пересборка на старте. После каждой чистой записи настроек `touchConfig()`
(§113) выравнивает mtime конфига, чтобы не было ложного «грязно».

Оба файла искались в `getApplicationDocumentsDirectory()`. На Android
path_provider отдаёт там `Context.getDir("flutter")` = `app_flutter/`, а
native `ConfigManager.kt` пишет конфиг в `Context.filesDir` = `files/`
(features/012 это фиксирует явно). В `app_flutter/` файла нет никогда:

- `configModifiedTime()` → всегда `null` → по таблице `isDirty()` («config
  absent → true») `configDirty = true` на **каждом** запуске при наличии
  настроек (`subscription_controller.dart` — лог `init: configDirty=true
  via mtime compare`);
- mtime-сравнение §076/§113 не выполнялось ни разу — работал только грубый
  fallback «всегда пересобирать»;
- `touchConfig()` — no-op (файла по Dart-пути нет).

User-impact: лишняя сборка конфига на каждом холодном старте; сценарий
«холодный старт с dirty при живом туннеле» (home_screen) срабатывал всегда,
а не когда настройки реально менялись. Ошибок не было, поэтому не замечали.

## Диагностика

Найдено при инвентаризации файлов на диске для Workspaces. Комментарий в
шапке `config_dirty_check.dart` утверждал `Context.filesDir() ==
getApplicationDocumentsDirectory()` — это неверно, и в проекте это уже
знали: `BoxVpnClient.getFilesDir()` (§316) заведён ровно потому, что
«пока диагностика ходила по Dart-пути, файлы ядра не находились никогда».
Dirty-check тогда не поправили.

Подтверждение по коду: `path_provider_android` →
`getApplicationDocumentsPath()` = `getDir("flutter")`,
`getApplicationSupportPath()` = `filesDir`; `ConfigManager.kt:28,42` —
`File(filesDir, CONFIG_FILE)`; в Dart `singbox_config.json` упоминает
только `config_dirty_check.dart`.

Ловушка по дороге: `subscription_controller.dart` содержал сырой NUL в
строковом литерале, и `grep` без `-a` молча не искал в нём (вычищено
отдельно, e5f5b4b6).

## Решение

`app/lib/services/config_dirty_check.dart`:

- каталог конфига — `_configDir()`: native `filesDir` через
  `BoxVpnClient().getFilesDir()`, ответ кэшируется на процесс (только
  успешный: без канала — юнит-тесты — каждый вызов падает на Documents,
  где тесты кладут конфиг рядом с настройками);
- `configModifiedTime()` и `touchConfig()` ходят через `_configDir()`;
  `settingsModifiedTime()` — по-прежнему Documents;
- `resetForTesting()` сбрасывает кэш между тестами;
- шапка файла переписана: два каталога, откуда какой.

Доки: STORAGE.md «Disk layout» и ARCHITECTURE.md «The user state» —
`singbox_config.json` и `cache.db` перенесены под `Context.filesDir`;
TEMPLATE.md — `<filesDir>/singbox_config.json`.

## Риски и edge cases

- Вызов MethodChannel на пути `_save()` (touch после чистой записи):
  один раз за процесс, дальше кэш; таймаут канала 5 с — только при мёртвом
  native, и тогда fallback на Documents = прежнее поведение.
- Первые запуски после обновления: конфиг в `files/` уже есть, mtime
  сравнится честно. Если настройки новее — одна пересборка, как и раньше.
- Не покрыто: `http_cache/` в доках по-прежнему описан под Documents, а
  живёт в `files/sub_cache/` (§027 → follow-up).

## Верификация

`app/test/services/config_dirty_flag_test.dart`, группа «§414»: мок
канала ядра отдаёт отдельную папку как `filesDir`:

- свежий конфиг в filesDir → `isDirty=false`;
- конфиг только в Documents (старое место) → не считается, `isDirty=true`;
- `touchConfig` дотягивается до файла в filesDir.

Старые тесты §113 не менялись: без мока канала работает fallback на
Documents. `flutter analyze` + `flutter test` — зелёные.

## Docs to update

- `CHANGELOG.md` → Unreleased/Fixed — done.
- `docs/STORAGE.md`, `docs/ARCHITECTURE.md`, `docs/TEMPLATE.md` — done.

## Нерешённое / follow-up

- Доки про `http_cache/` (реально `files/sub_cache/<hash>` + `.headers`,
  ключ — `url.hashCode`, не sha1) — отдельная правка.
