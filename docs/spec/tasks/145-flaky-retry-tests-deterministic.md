# §145 — Детерминизация flaky retry-тестов (§101/§T3)

**Статус:** Done
**Дата:** 2026-06-17

## Проблема

При полном `flutter test` (все ~1260 тестов в одном изоляте, группы
гоняются конкурентно) периодически падали тесты в:

- `test/services/rule_set_downloader_test.dart` (§T3)
- `test/subscription/rehydrate_race_test.dart` (§101)
- `test/subscription/sources_test.dart` (T1-3) — потенциально

Изолированно файлы проходили — классический flaky на разделяемом
состоянии + искусственных таймерах.

## Два корня

### 1. `RuleSetDownloader._cacheDir` — залипающий static-путь

`_dir()` кэшировал `Directory` первого вызова **навсегда**. В тесте
каждый `setUp` создаёт свой `createTemp` + `PathProviderPlatform.instance`,
но `_cacheDir` уже указывал на папку первого `setUp`. Её сносил первый
`tearDown` → последующие `download()` писали в удалённую директорию,
ловили `FileSystemException` в `catch(_)`, возвращали `null` после
ретраев → `expect(path, isNotNull)` падал. Проявлялось, когда
`tearDown` успевал снести папку до записи (timing-зависимо при
параллельной нагрузке).

**Фикс:**
- `RuleSetDownloader.resetCacheForTesting()` — сброс `_cacheDir`.
- `_dir()` больше не доверяет кэшу слепо: если закэшированная папка
  исчезла — пересоздаёт (`exists()` → `create`). Защита и для прода
  (очистка стораджа на лету).
- Тест вызывает `resetCacheForTesting()` в `setUp`.

### 2. Реальный сон 1s+3s в retry-кейсах

`RuleSetDownloader.download` и `sources.dart::_fetch` спали exp-backoff
`[1s, 3s]` между ретраями. Retry-тесты гоняли это **реально** (~4s на
кейс). В параллельном suite event-loop загружен → задержки наслаивались
и сдвигали тест к flutter-test таймауту.

**Фикс — backoff'ы test-overridable (прод-значения по умолчанию):**
- `RuleSetDownloader.download(..., List<Duration>? backoffs)` —
  `null` → прод `[1s, 3s]`. Тесты передают `[Duration.zero, Duration.zero]`
  (те же 2 ретрая, без сна).
- `sources.dart`: `set fetchBackoffsForTesting(List<Duration>?)` —
  глобальный override `_fetch`. `rehydrate_race_test` и `sources_test`
  ставят нулевой в `setUp`, сбрасывают в `null` в `tearDown` (без
  протечки на остальной suite).

## Проверка

3× полный `flutter test` подряд: 0 падений в subscription/rule_set/
rehydrate во всех прогонах (раньше — мелькали в `-N`). Время прогона
изменённых файлов: ~12s → ~3.5s (ушёл реальный сон).

## Не входит

4 детерминированных (не flaky) падения в
`test/services/warp_obfuscation_test.dart` (§126/§136) — регресс в
незакоммиченном WARP/AWG-коде параллельной сессии (`awg_junk.dart`,
`warp_client.dart`). Стабильно падают и изолированно. Чужую
незавершённую работу не трогаем.

## Файлы

- `app/lib/services/rule_set_downloader.dart`
- `app/lib/services/subscription/sources.dart`
- `app/test/services/rule_set_downloader_test.dart`
- `app/test/subscription/rehydrate_race_test.dart`
- `app/test/subscription/sources_test.dart`
