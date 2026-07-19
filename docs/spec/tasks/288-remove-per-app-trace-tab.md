# §288 — Удаление вкладки «App» (per-app trace) из статистики

**Тип:** cleanup / UX · **Статус:** in progress (develop)

## Проблема

В `StatsScreen` четыре вкладки: `Stats`, `Conns`, `App` (per-app trace,
`PerAppTraceTab`), `Profiler` (`LiveEventsTab`). Вкладка `App` дублирует
`Profiler`: всё, что она даёт для «посмотреть трафик одного приложения»,
доступно в `Profiler` через app-фильтр (multi-select по package'ам внутри
`TraceExplorer`). Отдельная вкладка не несёт уникальной ценности, но занимает
1/4 ширины TabBar на узких экранах и раздваивает UX профилирования.

### Разбор «уникальных» возможностей вкладки App

| Возможность App | Есть ли в Profiler | Вывод |
|---|---|---|
| Просмотр трафика одного приложения (Live/Aggregated, поиск, чипы, drill-down) | Да — app-фильтр в `TraceExplorer` + тот же движок | дубль |
| Запись сессии START/STOP | Да — `startGlobalRecording`/`stopGlobalRecording` | дубль |
| Share / Copy JSON | Да — экспорт буфера в Profiler | дубль |
| **Secondary packages** | Нет как «склейки», но данные видны — ручной выбор пакетов = мультивыбор в фильтре Profiler | косметика атрибуции, не доступ к данным |
| **Verbose core logs (debug)** | Нет | это просто тумблер `log_level=debug` на время сессии; к DNS/просмотру приложения не привязан (DNS-события идут отдельным структурным стримом `CcDnsQuery`, SPEC 018 §180/§261, независимо от `log_level`) |

Итог: уникального, ради чего держать отдельную вкладку, нет. `secondary`/`verbose`
— узкоспециальный ручной dev-функционал, дублируемый более простым путём в
Profiler.

## Решение

Убрать вкладку `App` из UI и удалить сугубо per-app UI-файлы. Сервисный слой
(`TrafficProfiler`) и общий движок (`TraceExplorer`, его `widgets/`,
`session_json.dart`, `app_multi_picker.dart`) **не трогать** — они держат
`Profiler`, home-бар и Debug API.

TabBar становится трёхтабовым: `Stats`, `Conns`, `Profiler`.

## Файлы

### Удалить (используются ТОЛЬКО вкладкой App)

| Файл | Причина |
|---|---|
| `app/lib/screens/per_app_trace_tab.dart` | сама вкладка; импортирует только `stats_screen.dart` |
| `app/lib/screens/per_app_trace_tab/single_app_picker_screen.dart` | target-picker, только per-app |
| `app/lib/screens/per_app_trace_tab/trace_dialogs.dart` | help/wipe-диалоги, только per-app |
| `app/lib/screens/per_app_trace_tab/trace_sections.dart` | header/stats/saved-sessions, только per-app |

### Править

| Файл | Изменение |
|---|---|
| `app/lib/screens/stats_screen.dart` | убрать `import per_app_trace_tab.dart`; enum `StatsTab` без `perApp`; `DefaultTabController(length: 4→3)`; убрать 3-й `Tab` (`App` + bolt-индикатор); убрать `const PerAppTraceTab()` из `TabBarView` |
| `app/lib/screens/home/widgets/traffic_bar.dart` | убрать ветку `StatsTab.perApp` в tap-навигации (§044) и per-app bolt-чип `isRecording` (recording больше не запускается из UI → мёртвая ветка); global-recording чип (`isGlobalRecording`, podcasts) остаётся |
| `app/assets/l10n/ru/ui.json` | удалить 19 per-app-only ключей (список ниже) |

### НЕ трогать (шарятся с Profiler / Debug API / тестами)

- `per_app_trace_tab/session_json.dart` — `eventsToJson` используется `live_events_tab.dart` и тестом
- `per_app_trace_tab/app_multi_picker.dart` — фильтр-окно Profiler
- `per_app_trace_tab/widgets/*` — общий движок `TraceExplorer`
- `app/lib/screens/app_picker_screen.dart` — TUN-настройки + редактор правил
- весь `traffic_profiler.dart` — каждый per-app метод (`start`/`stop`/`isRecording`/
  `active`/`completed`/`updateSecondaryPackages`/`delete`/`clearAll`) вызывается
  Debug API-хендлером `services/debug/handlers/profiler.dart` и покрыт
  `test/services/traffic_profiler_test.dart`. Мёртвого кода в сервисе нет.

### l10n-ключи на удаление (`app/assets/l10n/ru/ui.json`, только per-app)

`%1$d doms · %2$d ips · %3$d ev`, `%1$s · %2$d doms · %3$d ips`,
`%d unattributed events / 30s — attribution gaps detected. See "System-wide" section in Live tab.`,
`Clear all sessions`, `Clear all sessions?`, `Copy session JSON`, `Edit secondary`,
`No secondary packages`, `Pick an app and tap START to record…` (help-текст),
`Pick app to trace`, `Saved sessions (last %d)`, `Saved trace sessions will be removed.`,
`Session JSON copied to clipboard`, `Share session`, `Verbose core logs (debug)`,
`Verbose core logs active — battery/CPU impact while session runs`,
`Verbose toggle takes effect on next session — stop and restart.`, `· %d dropped`,
`Per-app trace` (заголовок help-диалога).

Общие ключи (`START`, `STOP`, `Recording`, `Stopped`, `Cancel`, `Clear`, `Share`,
`Help`, `Search by name or package`, `Show system apps`, system-wide unattributed
Profiler-баннер) — **не трогать**.

## Что остаётся у пользователя

Профилирование трафика приложения — через `Profiler`: START/STOP запись,
app-фильтр (выбрать нужные пакеты), Live/Aggregated, поиск, drill-down, экспорт
JSON. Debug API per-app-профайлера (`/profiler/*`) сохраняется без изменений.

## Приёмка

- `StatsScreen` показывает 3 вкладки: `Stats`, `Conns`, `Profiler`.
- Home-бар при тапе открывает `Stats` (Overview); global-recording чип работает.
- `flutter analyze` (lib + test) зелёный, sealed-switch по `StatsTab` закрыт.
- `flutter test` зелёный — ни один тест не импортировал удаляемые файлы.
