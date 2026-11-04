# 713 — Настройка параллельности проверки серверов (`ping_options.concurrency`)

| Field | Value |
|-------|-------|
| Status | Done |
| Start date | 2026-11-04 |
| End date | 2026-11-04 |
| Commits | — |
| Related specs | §040 (ping_options), §209 (mass ping через pingclient), §236/§518 (ProbeRunner), features/009-NODE_HEALTH |

## Problem

Issue #192 (paratroop3r, 02.11.2026): при большой подписке массовая проверка
серверов даёт пачку одновременных запросов в разные протоколы; автор просит
настройку числа параллельных запросов, как в v2rayNG и в десктоп-клиенте.

У нас параллельность зашита константами и не настраивается:

- mass ping с главного экрана — `_pingConcurrency = 10`
  (`controllers/home_controller/ping_orchestration.dart`);
- «Test servers» в папке/подписке — `ProbeRunner._concurrency = 6`
  (`services/probe/probe_runner.dart`).

## Solution

Одна настройка `ping_options.concurrency` (целое, 1..32, по умолчанию 10),
общая для mass ping и ProbeRunner. Хранится рядом с `url` / `timeout_ms`
в объекте `ping_options`, поэтому в бэкап едет без отдельной работы
(`ping_options` целиком в allowlist §221).

1. `SettingsStorage`: константы `pingConcurrencyDefault/Min/Max`,
   `getPingConcurrency()` (значение из storage с clamp, иначе дефолт),
   `setPingConcurrency(int?)` (`null` → ключ снимается = дефолт).
2. Mass ping читает значение из storage при каждом старте прогона
   (кэша `_pingOptions` не хватает: App Settings не держит контроллер).
3. `ProbeRunner.run` читает то же значение на старте прогона; конструктор
   принимает `concurrency` для тестов и Debug API. Прежний дефолт 6 уходит:
   значение одно на обе проверки.
4. Debug API `PUT /settings/ping_options`: ключ `concurrency` в allowlist,
   должен быть числом.
5. App Settings → General → Feedback, под «Auto-ping after connect»: строка
   «Parallel checks» — числовое поле и кнопка «Reset to default»
   (`Icons.restart_alt`, активна только при значении ≠ 10). Ввод вне
   диапазона приводится к границе; пустое поле = дефолт.

## Verification

- `test/services/settings_storage_ping_concurrency_test.dart`: чтение
  дефолта, clamp сверху/снизу, мусор в storage → дефолт, `null` снимает ключ.
- Эмулятор: не проверялось в этой сессии.

## Documentation

STORAGE.md (`ping_options`), api/debug-api-reference.md, ARCHITECTURE.md
(строки про `_pingConcurrency`), CHANGELOG Unreleased, l10n ru/zh.
