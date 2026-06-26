# §183 — Вычистить мёртвый код старой DNS-атрибуции (после §180)

**Тип:** cleanup (мёртвый код / упрощение)
**Статус:** Draft
**Связано:** §180 (структурный DNS-стрим из ядра), §168 (TCP из CommandClient),
§048 (confidence-уровни), §177 (баннер)

## Контекст

§180 перевёл DNS с текстового парсинга лога на структурный стрим из ядра
(`CcChannel.dnsQueries` → `_ingestDnsQueries`), где атрибуция к приложению
приходит ГОТОВОЙ из ядра (`processInfo`). §180 уже выпилил `_dnsRe`/`_dnsFailRe`/
`_handleDnsLine`/`_DnsAccumulator`/`_dnsByConnId`. Но остались **обходные пути из
старой жизни**, когда DNS не был атрибутирован. Аудит (полное чтение
traffic_profiler.dart + part-файлы + UI-читатели + тесты) нашёл три группы.

## Группа A — write-only `_connIdToMeta` + лог-питатель (РИСК НИЗКИЙ)

`_connIdToMeta` **write-only** — подтверждено: пишется ([traffic_profiler.dart:602](app/lib/services/traffic_profiler.dart)),
GC ([:536](app/lib/services/traffic_profiler.dart)), clear ([:1318](app/lib/services/traffic_profiler.dart)),
**ноль чтений** (нет lookup/containsKey/values/итерации). Раньше читала DNS-ветка
для connId→package сшивки; §180 её удалил, write-half повис.

TCP-атрибуция давно идёт из ядра напрямую (`CcConnection.packageName`, §168
`_ingestCcConnections`), НЕ из router-лога. Значит весь лог-питатель мёртв:

Удалить:
- `_connIdToMeta` (поле :179) + GC-строка (:536) + clear (:1318)
- `_ConnMeta` (internal.dart:7-11)
- `_packageRe` (:585-586) + package-ветка в `_processLogLine` (:597-605)
- `_processLogLine` целиком (после выпила ветки пуст)
- лог-листенер, обслуживающий ТОЛЬКО `_processLogLine`:
  `_appLogListener`, `_ensureLogListenerAttached`, `_maybeDetachLogListener`,
  `_drainNewLogEntries`, `_lastSeenLogTs`, вызовы attach/detach в
  `start`/`stop`/`startGlobalRecording`/`stopGlobalRecording`
- `feedLogLineForTest` (:1343-1346) + тавтологичный тест (test:845-857)

ОСТАВИТЬ: GC-таймер `_gcStaleConnIds` (нужен для `_globalRollingBuffer` /
`_globalUnattributedEvents` / `_closedHandled` — умирает лишь строка :536).
`_globalRollingBuffer` (backfill / Live / snapshot — много читателей).

## Группа B — Strategy 4 `_inferProcessByIp` + `inferred`-уровень (РИСК СРЕДНИЙ)

Strategy 4 атрибутирует TCP/UDP по недавнему DNS-резолву того же IP (окно
`_processInferenceWindow`). После §180 И DNS, И TCP несут package из ядра →
эвристика по IP избыточна. Ноль тестов покрывают inferred. Решение (юзер):
**выпилить** — безымянный TCP станет `unattributed` вместо `inferred`
(деградация точности, не поломка; ядро даёт атрибуцию напрямую).

Удалить:
- Strategy 4 (:800-814), `_inferProcessByIp` (:1188-1209), `_processInferenceWindow` (:80)
- `ConfidenceLevel.inferred` (models.dart:23)
- флаг `processInferred` целиком (models.dart:122,161,249,288;
  traffic_profiler.dart:835,850,907,1149)
- UI-читатели inferred:
  - [live_view.dart:204-205](app/lib/screens/per_app_trace_tab/widgets/live_view.dart) (`〽 inferred from prior DNS`)
  - [live_view.dart:294](app/lib/screens/per_app_trace_tab/widgets/live_view.dart) (`inferred => '〽'`)
  - [traffic_event_detail_sheet.dart:286](app/lib/screens/stats_screen/traffic_event_detail_sheet.dart)
  - [trace_dialogs.dart:48](app/lib/screens/per_app_trace_tab/trace_dialogs.dart) (легенда `〽`)

## Группа C — устаревшие комментарии (РИСК НУЛЕВОЙ)

- `:1213-1215` — ссылка на удалённый `_handleDnsFailLine` → заменить на
  `_ingestDnsQuery` (ветка `q.failed`).
- При выпиле A — обновить `:73` («conn-id correlation» больше нет) и
  header-комментарий :16-34 (убрать router-лог как live-источник package).

## Границы

- НЕ трогать: `_globalRollingBuffer`, `_gcStaleConnIds` (нужны), CommandClient-
  тракты `_ingestCcConnections`/`_ingestDnsQueries` (основной живой путь).
- Tombstone-комментарии про `_DnsAccumulator`/`_dnsByConnId`/`_dnsRe` — ОСТАВИТЬ
  (полезная история §180, не врут).
- `_connIdToMeta` confidence-уровни verified/secondary/unattributed — ОСТАЮТСЯ
  (живые); уходит только inferred.

## Тесты

- Существующие профайлер-тесты зелёные после выпила (inferred не покрыт — регрессий
  в тестах нет по определению).
- analyze чист (особое внимание: не осталось битых ссылок на удалённые символы в
  UI-файлах и моделях).
- Проверить: безымянный TCP-conn (process пуст) → `unattributed` (был бы inferred).
