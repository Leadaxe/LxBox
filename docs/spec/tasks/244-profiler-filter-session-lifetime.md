# §244 — Фильтр профайлера переживает навигацию (session-lifetime)

> СТАТУС: реализовано (05.07.2026). Баг B4 с 4PDA: «ставишь фильтр по
> трафику или домену, уходишь на другую вкладку и возвращаешься — фильтр
> слетел». Не регрессия — так было всегда (never worked), фича-фикс.

## Проблема

`ProfilerFilter` (ChangeNotifier, §044/new-profiler) жил **полем State**
вкладки:

| Вкладка | Поле | dispose |
|---|---|---|
| Profiler (system-wide Live), `live_events_tab.dart` | `final ProfilerFilter _filter = ProfilerFilter();` | `_filter.dispose()` |
| App (per-app trace), `per_app_trace_tab.dart` | то же | то же |

Вкладки лежат в **голом `TabBarView`** (`stats_screen.dart`,
`DefaultTabController(length: 4)`) без `AutomaticKeepAliveClientMixin` →
уход с вкладки = dispose State = новый `ProfilerFilter()` при возврате =
фильтр (поиск/чипы протокола/app-ось/rule/outbound/потеряшки) слетел.
Уход со Stats-экрана целиком — тем более.

## Решение (согласовано с владельцем)

Фильтры живут **на уровне сессии приложения**: переживают переключение
вкладок И уход со Stats-экрана, но НЕ перезапуск приложения. **НИКАКОГО
persist** в настройки/диск.

Session-холдер `ProfilerFilters` (паттерн синглтона `TrafficProfiler.I`
— private ctor + static final) с **двумя независимыми** инстансами:

```dart
class ProfilerFilters {
  ProfilerFilters._();
  static final ProfilerFilter appTab = ProfilerFilter();   // App-вкладка
  static final ProfilerFilter liveTab = ProfilerFilter();  // Profiler-вкладка
}
```

Два инстанса не сливать: у вкладок разные наборы осей (App-вкладка не
применяет app-ось — target зафиксирован сессией) и разные user-интенты.

| Было | Стало |
|---|---|
| `_LiveEventsTabState`: поле `ProfilerFilter()` + `dispose()` | getter → `ProfilerFilters.liveTab`, dispose убран |
| `_PerAppTraceTabState`: поле `ProfilerFilter()` + `dispose()` | getter → `ProfilerFilters.appTab`, dispose убран |

Session-объект **не диспоузится никогда** — вызов `dispose()` на нём из
State уничтожил бы notifier для всех будущих State (Flutter ChangeNotifier
после dispose бросает assert на addListener).

## Подписки (проверено — утечек нет)

Сами tab-State на `_filter` **не подписываются** (нет addListener).
Слушатели — ниже по дереву, оба парно снимаются:

- `TraceExplorer` (`stats_screen/trace_explorer.dart`): `addListener` в
  `initState` + rewire в `didUpdateWidget` + `removeListener` в `dispose`.
  Пересоздание State вкладки = пересоздание explorer'а = снял/повесил
  заново — на session-объекте это безопасно.
- `ProfilerFilterSheet` (`stats_screen/profiler_filter_sheet.dart`):
  `addListener` в `initState` + `removeListener` в `dispose`. Sheet
  редактирует переданный инстанс (тот же session-объект) — работает
  без изменений.

## Сознательные решения

- **VPN stop/start фильтр НЕ сбрасывает** — живёт всю сессию приложения
  (решение владельца). Сброс руками: Filter → Reset all (`clearAll()`).
- Не keepAlive вкладок (`AutomaticKeepAliveClientMixin`) — было бы шире
  скоупа: держало бы живыми SSE-подписки/тикеры обеих вкладок и не
  спасало бы от ухода со Stats-экрана целиком.
- Не persist на диск — фильтр ситуативный (диагностика «здесь и сейчас»),
  восстанавливать его через перезапуск = сюрприз «куда делись события».

## Файлы

- `app/lib/screens/stats_screen/profiler_filters.dart` — session-холдер (новый)
- `app/lib/screens/live_events_tab.dart` — getter вместо поля, dispose убран
- `app/lib/screens/per_app_trace_tab.dart` — то же
- `app/test/screens/profiler_filters_test.dart` — тесты (новый)

## Тесты (`profiler_filters_test.dart`)

- Холдер: инстансы стабильны между обращениями; appTab и liveTab —
  разные объекты; состояние независимо.
- «Пересоздание вкладки»: изменение фильтра видно при повторном
  обращении к холдеру (симуляция нового State).
- Widget-тест изолированного поддерева (без TrafficProfiler-стриминга и
  platform-каналов — известная грабля §214: testWidgets + `_invoke`
  виснут): фейковая «вкладка» по паттерну tab-State (addListener в
  initState / removeListener в dispose, фильтр из холдера) убирается из
  дерева и монтируется заново — фильтр жив, повторная подписка не падает.

## Docs to update

- `CHANGELOG.md` → Unreleased: user-visible фикс (profiler filters survive
  navigation). Отложено из этой сессии: параллельный агент работает в
  соседней зоне, правку общего файла делает владелец при merge.
