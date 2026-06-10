# 101 — Стартовая гонка rehydrate↔bootstrap + guard на пустой fetch

**Дата:** 2026-06-10 · **Статус:** DONE
**Симптом (field report):** «серверы Liberty в кеше, но при этом не загрузились
в конфиг» — плавающий, после рестарта app.

## Root cause (подтверждён построчным чтением, 3 независимых ревью)

1. `SubscriptionServers.toJson` **не персистит nodes** (только
   `last_node_count`) — после рестарта `nodes=[]`, пока их не восстановит
   `_rehydrateFromCache()` (file IO + decode + parseAll, последовательно).
2. `init()` запускает rehydrate как `unawaited` (fire-and-forget),
   `subscription_controller.dart:91`.
3. `home_screen._initSubsAndAutoUpdate` ждёт фикс. **100 мс** и при
   `configDirty` (mtime-compare §076 — true после любого `_persist` без
   rebuild: fetch-attempt, §098 reorder, §100 sort, toggle) зовёт
   `generateConfig()`.
4. `_generate()` снимает снапшот `_entries.map((e) => e.list)` — у
   не-регидрированной подписки `nodes=[]` → builder **молча** эмитит 0
   outbounds (`server_list_build.dart:25`).
5. Конфиг сохраняется, `configDirty=false`; mtime конфига теперь свежее
   настроек → битый конфиг переживает рестарты. Rehydrate, доехав, ставит
   только UI-статус «N nodes (cached)» — rebuild не триггерит.

Смежные подтверждённые баги (фиксим заодно):

- **R2.** `_rehydrateFromCache` пишет `_entries[i]` **по индексу через
  await-границы** — `moveEntry`/`removeAt` (§098 reorder) во время старта
  подменяет list чужой entry (дубликат, потеря исходного списка). Fetch-путь
  давно переведён на by-ref (`_fetchEntryByRef`, см. doc-comment :425) —
  rehydrate пропущен.
- **R3.** Кеш, распарсившийся в 0 нод, скипается **без строки лога**
  (exception-ветка логирует, empty-ветка — нет); UI-счётчик при этом
  показывает stale `lastNodeCount`.
- **R4.** HTTP 200 с мусорным телом (HTML-заглушка провайдера, challenge)
  идёт по success-path: `HttpCache.save` затирает рабочий кеш на диске,
  `copyWith(nodes: [])` стирает in-memory ноды, `status=ok`,
  `consecutiveFails=0`. После этого rehydrate мёртв навсегда (кеш мусорный).
- **R5.** `HttpCache.save` — `unawaited` + не-атомарная запись: kill процесса
  mid-write оставляет обрезанное тело при `lastNodeCount=N`.

## Fix

| # | Файл | Изменение |
|---|---|---|
| F1 | `subscription_controller.dart` | `Completer<void> _rehydrated` + `Future<void> get rehydrationDone`; завершается в конце `_rehydrateFromCache` (включая ранний `return`/throw — try/finally) |
| F1 | `home_screen.dart` | `_initSubsAndAutoUpdate`: вместо `delayed(100ms)` → `await Future.wait([_subController.rehydrationDone, _controllerInit])`, где `_controllerInit` — сохранённый future от `_controller.init()`. `_autoUpdater.start()` переносится **после** bootstrap-блока (appStart-fetch'и не бампают mtime настроек посреди bootstrap'а) |
| F2 | `subscription_controller.dart` | `_rehydrateFromCache`: итерация по снапшоту ссылок (`List.of(_entries)`), запись через `entry._replaceList`; guard после await'ов: entry ещё в `_entries` и `identical(entry.list, list)` (fetch мог успеть подменить) |
| F3 | `subscription_controller.dart` | empty-ветка rehydrate → `AppLog.warning` с `diagnoseEmptyParse`-hint |
| F4 | `subscription_controller.dart` | `_fetchEntryByRef`: `result.nodes.isEmpty` → ветка **failure**: кеш НЕ перезаписывается, in-memory nodes/`lastNodeCount`/`meta` сохраняются, `lastUpdateStatus=failed`, `consecutiveFails+1`, haptic error; `HttpCache.save` перенесён после этого guard'а |
| F5 | `http_cache.dart` | Атомарная запись: `<key>.tmp` → rename (body и headers) |
| — | `subscription_controller.dart` | Test seam: `@visibleForTesting http.Client? httpClientForTesting` → прокидывается в `parseFromSource` |

## Поведенческие изменения

- Bootstrap-rebuild на старте теперь ждёт восстановления нод из кеша
  (обычно сотни мс; корректность > скорость — VPN при автостарте использует
  сохранённый конфиг, не этот rebuild).
- Подписка, у которой сервер вернул 200 с нераспознаваемым телом, теперь
  выглядит как **failed** (было: ok с 0 нод). Легитимно опустевшая подписка
  (провайдер удалил все серверы) тоже станет failed — осознанный trade-off:
  тихо стереть рабочие ноды хуже, чем ложный fail-статус.

## Тесты (`test/subscription/rehydrate_race_test.dart` + http_cache_test)

1. init → `rehydrationDone` восстанавливает ноды из кеша (happy path).
2. Кеш парсится в 0 → ноды пусты, без crash'а.
3. `moveEntry` сразу после `init()` (rehydrate в полёте) → списки не
   перепутаны, дубликатов нет.
4. Fetch 200 + мусорное тело при живых нодах → ноды/кеш/lastNodeCount
   сохранены, status=failed, consecutiveFails+1.
5. Fetch 500 → старое поведение сохранено (regression).
6. `HttpCache.save` атомарен (нет `.tmp`-резидуала, перезапись ок).

## Пост-ревью (адверсариальное, 3 линзы)

Принятые находки:

- **should-fix:** throw из `_controllerInit` (PlatformException из
  `getVpnStatus` — `_invoke` ловит только Timeout) или `saveParsedConfig`
  убивал метод до `_autoUpdater.start()` (единственный call-site!) →
  try/catch вокруг bootstrap, `start()` в finally.
- nit: persist-фейл в empty-ветке уводил в общий catch → двойной
  `consecutiveFails`/haptic → локальный try/catch.
- nit: `identical`-guard rehydrate ложно срабатывал на UI-сеттерах
  (rename сохраняет nodes=[]) → guard переписан: применяем кеш, если у
  ТЕКУЩЕГО list нет нод; копируем на него (правки юзера не теряются).
- nit: deadlock `rehydrationDone` при throw из init до запуска rehydrate →
  completer завершается и в error-пути init.
- nit: фикс. имя `.tmp` гонялось при конкурентных save одного URL →
  монотонный суффикс.

Зафиксировано как accepted-residual: пара body/headers пишется двумя
rename'ами — kill между ними даст свежее body со старыми headers
(косметика, Source-вкладка).

## Ручная верификация на устройстве

В Debug-логе строка `Re-hydrated N nodes from cache: <host>` должна идти
**раньше** `Config built: …`; в собранном конфиге присутствуют теги подписки
сразу после холодного старта с `configDirty=true`.
