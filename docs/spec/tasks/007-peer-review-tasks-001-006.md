# 007 — Peer review: задачи 001–006 (VPN lifecycle, оптимизации, detour UI)

| Поле | Значение |
|------|----------|
| Статус | **Closed** — actionable code-level замечания все закрыты (2026-04-21) |
| Дата | 2026-04-20 (ревью) · 2026-04-21 (закрытие) |
| Объект ревью | [001](./001-reconnect-sink-leak.md), [002](./002-blocking-stopvpn-intent-reset.md), [003](./003-revoke-ux.md), [004](./004-lifecycle-resume-resync.md), [005](./005-optimization-pass.md), [006](./006-per-node-detour-toggles.md) |
| Коммит-закрытие | `e0e7213` fix(review): address peer review follow-ups for tasks 001-006 |
| Связанные spec'ы | [`003 home screen`](../features/003%20home%20screen/spec.md), [`012 native vpn service`](../features/012%20native%20vpn%20service/spec.md), [`018 detour server management`](../features/018%20detour%20server%20management/spec.md) |

## Резюме закрытия (2026-04-21)

Все code-level замечания peer review закрыты в коммите `e0e7213`:

| # | Замечание | Статус |
|---|-----------|--------|
| 006 critical | `persistSources()` в `SwitchListTile.onChanged` | ✅ Fixed |
| 003 | `_onTunnelDead` полный cleanup (unified с `_handleStatusEvent`) | ✅ Fixed |
| 004 | `TunnelStatus.unknown` default вместо `disconnected` | ✅ Fixed |
| 006 | `'⚙ '` literal → `kDetourTagPrefix` в `home_screen` / `node_filter_screen` | ✅ Fixed |
| 006 docs | Статус `In progress` → `Done` + секция Follow-up | ✅ Fixed |
| 002 docs | Зачёркнуты устаревшие follow-up (spec 012 / TunnelStatus) | ✅ Fixed |
| 003 docs | Зачёркнуты follow-up (unknown, unified cleanup) | ✅ Fixed |

**Открытые non-code пункты** (не требуют кода):

- Ручные чеклисты 002/003/004/006 на устройстве — передано пользователю для manual verification перед tag 1.4.0.
- 004 edge-case мониторинг (лишние resync через `unknown`) — наблюдать в production, точечно править если всплывёт.

## Контекст

Сводная оценка соответствия отчётов в `docs/spec/tasks` фактическому коду репозитория L×Box после сдачи серии задач по VPN lifecycle, UX revoke, resume re-sync, optimization pass и per-node detour toggles.

## Итоговая оценка (кратко)

| Задача | Соответствие отчёту | Качество инженерии | Риски / хвосты |
|--------|--------------------|--------------------|----------------|
| 001 | Полное | Очень высокое | Минимальные |
| 002 | Полное | Высокое | Re-entry `stopAwait`, ручная верификация по чеклисту |
| 003 | Полное | Высокое | `_onTunnelDead` vs полная очистка как в `_handleStatusEvent` |
| 004 | Полное | Хорошее | Только status; `unknown` для неизвестного raw |
| 005 | Полное | Хорошее | Нюанс пересчёта `sortedNodes` на каждый emit |
| 006 | Почти | Хорошее по идее | **Нет `persistSources()` на новых toggle'ах**; в task статус *In progress* |

Серия **001–005** выглядит связной: явный root cause, слойные фиксы без лишнего polling, отчёты совпадают с кодом.

---

## 001 — Reconnect / «Config changed» / sink leak

**Оценка: 9/10**

- В `app/lib/vpn/box_vpn_client.dart`: `late final _statusStream` из `receiveBroadcastStream().map(...).asBroadcastStream()`, геттер `onStatusChanged` отдаёт одну ссылку — совпадает с отчётом 001.
- Комментарий в коде фиксирует причину (перезапись `statusSink` на native при множественных `onListen` / `onCancel`).
- Теоретический край: поведение `asBroadcastStream()` при отсутствии долгоживущих listeners — для текущей модели (постоянная подписка из `HomeController`) обычно не релевантно.

---

## 002 — Blocking `stopVPN` + intent-based сброс `configStaleSinceStart`

**Оценка: 8.5/10**

- Native: `BoxVpnService.stopAwait`, completer в `setStatus(Stopped)`, `VpnPlugin.stopVpn` с `withTimeout(5_000)`, `pluginScope.cancel()` в `onDetachedFromEngine` — как в отчёте 002.
- Dart: `_stopInternal` / `_startInternal`, `reconnect` без `firstWhere`/`timeout` — согласовано с целью убрать гонку с guard в `onStartCommand`.
- При повторном `stopAwait` предыдущий completer отменяется — первый caller может получить `false`; в 002 это осознанно описано.

**Документация (хвост в отчёте 002):** в [002](./002-blocking-stopvpn-intent-reset.md) в «Нерешённое» было «обновить spec 012 с описанием `stopAwait`». В репозитории это уже сделано: раздел про blocking `stopVPN` / `stopAwait` есть в [`012 native vpn service`](../features/012%20native%20vpn%20service/spec.md); поток reconnect/stop описан и в [`ARCHITECTURE.md`](../../ARCHITECTURE.md). Сам файл task-002 при желании можно пометить как выполненный follow-up по докам, чтобы журнал не расходился с кодом/spec.

---

## 003 — Revoke UX

**Оценка: 8/10**

- Отдельный listener контроллера для SnackBar (вне `build`) — корректный Flutter-паттерн.
- В `_handleStatusEvent` для `disconnected`/`revoked`: `_clash = null`, объединённый `_emit` — совпадает с 003.

**Замечание:** путь `_onTunnelDead()` выставляет `tunnel: revoked`, но **не обнуляет `_clash`** и не дублирует полный набор полей ветки `revoked`/`disconnected` в `_handleStatusEvent`. Имеет смысл позже выровнять (единый путь очистки).

---

## 004 — Lifecycle resume re-sync

**Оценка: 8/10**

- `HomeController.onAppResumed` → `_resyncOnResume`: pull `getVpnStatus`, сравнение с `_state.tunnel`, при расхождении `_handleStatusEvent({'status': raw})`, затем heartbeat при `tunnelUp` — как в отчёте 004.
- Ограничение: только строка статуса; `TunnelStatus.fromNative` с `_ => disconnected` — для шумных/пустых raw возможны лишние resync (в отчётах уже отмечен follow-up про `unknown`).

---

## 005 — Optimization pass

**Оценка: 8.5/10**

- `ConfigCache` в `HomeState` (parse только при смене `configRaw`), `late final sortedNodes`, один `_transientTimeoutTimer`, батчинг `_emit` в `_handleStatusEvent` для основных веток — совпадает с 005.
- `StatsScreen` / `ConnectionsView` с `WidgetsBindingObserver` и паузой таймеров в background — подтверждено в коде.
- Нюанс: новый инстанс `HomeState` на каждый `copyWith` → `sortedNodes` пересчитывается на каждый emit; выигрыш — в отсутствии многократного sort в рамках одного rebuild одного state; дальнейший тюнинг возможен при профилях.

---

## 006 — Per-node detour toggles

**Оценка по коду после доработок: 8/10**

- `kDetourTagPrefix` в `lib/config/consts.dart`, ветка `isMainAsDetour` в `server_list_build.dart`, два `SwitchListTile` в `node_settings_screen.dart` при включённом «Mark as detour server» — соответствуют описанию 006.
- **Персист:** в `onChanged` обоих переключателей «Register in VPN groups» / «Register in auto group» вызывается `unawaited(widget.subController.persistSources())` — как у detour dropdown.
- **Документация:** [006](./006-per-node-detour-toggles.md) — статус *Done*, дата завершения и коммит указаны (в т.ч. follow-up persist).

**Навигация (scope UserServer):** `NodeSettingsScreen` открывается только для «direct server» (`entry.url.isEmpty && entry.connections.isNotEmpty` в `subscriptions_screen.dart`), т.е. ручной сервер — согласуется с заявленным scope 006 без дублирующей проверки `is UserServer` внутри экрана.

**Префикс в Home:** фильтр списка нод использует `kDetourTagPrefix` (`home_screen.dart`, импорт `consts.dart`).

---

## Дополнение (независимая сверка)

- Первичные замечания peer review по коду (persist, `_onTunnelDead`, префикс, `unknown`) закрыты повторной сверкой исходников.
- Ручная приёмка по 002/003/004 в task-файлах по-прежнему может быть помечена *pending* на девайсе — CI/review не заменяют прогон сценариев reconnect / revoke / resume.

---

## Верификация этого review-документа

- Сверка выполнена по чтению исходников: `box_vpn_client.dart`, `home_controller.dart`, `home_state.dart`, `home_screen.dart`, `BoxVpnService.kt`, `VpnPlugin.kt`, `server_list_build.dart`, `node_settings_screen.dart`, `subscriptions_screen.dart`, `subscription_controller.dart`, `tunnel_status.dart`; по докам — `012 native vpn service/spec.md`, `ARCHITECTURE.md`.
- Сборка/тесты для этого файла не требуются (только документация).

## Нерешённое / follow-up

1. **Ручные чеклисты** на устройстве (002 reconnect/stop, 003 revoke + SnackBar, 004 resume/divergence, 006 detour toggles) — по [002](./002-blocking-stopvpn-intent-reset.md) и соседним task-файлам; при закрытии обновить секции «Верификация».
2. **004 (edge):** при появлении на практике лишних resync из-за `unknown` vs прежний Dart-state — точечно уточнить сравнение в `_resyncOnResume` (сейчас достаточно для типичных native status string).

Остальное из первичного списка follow-up **закрыто** в коде или в task-файлах ([002](./002-blocking-stopvpn-intent-reset.md) — зачёркнутые пункты в «Нерешённое», в т.ч. spec 012 и `TunnelStatus.unknown`).
