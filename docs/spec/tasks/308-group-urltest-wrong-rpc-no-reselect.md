# §308 — Group URLTest звал не тот RPC: без переселекта группа висела на мёртвом узле

**Тип:** bugfix (нетривиальный root cause, массовые жалобы) · **Статус:** ✅ реализовано, device-проверка пройдена (оператор, 2026-07-26) · **Размер:** S · **Область:** ping-оркестрация / CC-мост

Самая массовая жалоба темы (июль 2026, трое независимо): Auto-группа на старте
выбирает нерабочий сервер и **не переключается**, даже когда тесты уже показали
живые узлы. Помогает «попинать сайт» и вручную запустить URLTest на группе —
но «Run URLTest» из контекстного меню при мёртвом выбранном узле просто
возвращал ошибку и ничего не менял.

## Root cause — два слоя

**Ядро (sing-box-lx):** выбор urltest-группы — закешированный указатель
(`selectedOutboundTCP`), пересчитываемый ТОЛЬКО в хвосте собственного
группового прогона (`performUpdateCheck`, `protocol/group/urltest.go`).
Обновление history само по себе переселект не запускает. Пер-узловой RPC
`URLTestOutbound` (ядровая SPEC 014) пишет history и НЕ трогает выбор.

**LxBox (этот баг):** при миграции §122 с Clash API на CommandClient групповой
тест должен был перейти на штатный `urlTest(groupTag)` (§122 §4.1: «паритет
1:1»). Фактически `runGroupUrltest` был подключён к **пер-узловому**
`urlTestOutbound(groupTag)`. Ядро резолвит тег группы в сам group-адаптер и
делает **один замер СКВОЗЬ группу** — то есть через её текущий (возможно
мёртвый) выбор:

- ни перебора членов, ни переселекта — комментарий «ядро само перебирает
  членов и обновляет selected» описывал семантику, которой в этой цепочке нет;
- при мёртвом выбранном — ошибка «timeout» и группа остаётся на мёртвом
  до interval-тика ядра (дефолт 3m; тик может вовсе не случиться —
  pause на screen-off, passive_check);
- хвост mass-ping (`_runAllUrltestGroups`), задуманный ровно против «Auto
  висит до первого тика», не работал по той же причине.

## Решение

`runGroupUrltest` переведён на настоящий групповой RPC — новая проводка
через весь мост:

| Слой | Изменение |
|---|---|
| `BoxCommandClient.kt` | `urlTestGroup(tag)` → libbox `CommandClient.urlTest(groupTag)` через `ensurePingClient()` (§209-стиль, как `selectOutbound`) |
| `VpnPlugin.kt` | handler `ccUrlTestGroup` (blocking unary → `Dispatchers.IO`, как `ccUrlTestOutbound`) |
| `cc_channel.dart` | `Future<bool> urlTestGroup(tag)` |
| `ping_orchestration.dart` | `runGroupUrltest` зовёт `urlTestGroup`; убраны `reloadProxies()` + bump `pingBatchGen` (см. семантику ниже); `_rescueGroupsSelecting` — авто-спасение при фейле единичного пинга выбранного узла |

В ядре RPC `URLTest(groupTag)` → `group.URLTest.CheckOutbounds()` →
`CheckOutbounds(true)`: **force-прогон всех членов + `performUpdateCheck`
(переселект) + interrupt** зависших соединений группы.

### Авто-спасение при фейле единичного пинга

`runNodeUrltest` при фейле дополнительно зовёт `_rescueGroupsSelecting(tag)`:
если упавший узел сейчас `selected` какой-то urltest-группы — форсим её
групповой URLTest (группа маршрутизирует трафик в мёртвое, ждать
interval-тика ядра — дефолт шаблона 15m, при screen-off тик вовсе стоит —
нельзя). Для остальных узлов — no-op: группа не на них, а force-прогон будит
suspended-эндпоинты (SPEC 020). Mass-ping в этот хелпер не ходит — его хвост
и так прогоняет все urltest-группы. Повторные срабатывания гасит ядровый
`checking`-CAS (прогон при уже идущем — тихий no-op).

### Семантика, которую нужно знать

- **Fire-and-forget.** Ядро запускает прогон в горутине (`go CheckOutbounds`),
  RPC возвращается сразу и без результатов. Новый `selected` приедет
  groups-стримом (`_applyGroups`), делеи членов лягут в history ядра.
  Поэтому старые `reloadProxies()` (пере-применял ПОСЛЕДНИЙ снапшот — при
  fire-and-forget это no-op на устаревших данных) и bump `pingBatchGen`
  (sort-источник `lastDelay` этот путь не наполняет) убраны.
- **URL/timeout — из конфига группы** (`urltest_url` шаблона + фикс 15s
  ядра), НЕ из per-group ping settings (§040). Так было и в Clash-эпоху:
  `/group/{tag}/delay` для urltest-групп игнорировал query-`url`
  (ядро: `api_meta_group.go` → `urlTestGroup.URLTest(ctx)`). Сведе́ние
  URL'ов — отдельная работа (подставлять resolved ping-URL группы в поле
  `url` при генерации конфига), вне скоупа §308.
- **`cancelPing()` этот прогон не отменяет**: групповой прогон живёт в ядре
  (parented к boxService.ctx), а не в per-call ctx pingClient'а. Epoch-guard
  в `_runAllUrltestGroups` остаётся — он прерывает запуск СЛЕДУЮЩИХ групп.
- **Хвост mass-ping дублирует пробы**: mass-ping только что померил все ноды,
  групповой force-прогон меряет членов снова. Цена принята — это
  единственный способ получить переселект от текущего ядра.

## Что НЕ делаем (и почему)

- **Переселект по обновлению history в ядре** (hook на
  `StoreURLTestHistory`/`DeleteURLTestHistory` + debounce) — системный фикс,
  после которого mass-ping чинил бы выбор сам, а хвост
  `_runAllUrltestGroups` можно удалить. Это ядровая работа —
  `sing-box-lx/SPECS/034` (планируется), не этот репо.
- **Retry после полностью провального прогона** (старт наперегонки с
  туннелем → все «мертвы» → пин на первый узел конфига до тика) — тоже ядро,
  та же будущая спека.
- **Пункт меню «Reselect»** — не нужен: переселект без теста как ручное
  действие непонятен пользователю; «Run URLTest» теперь и тест, и переселект.

## Файлы

- `app/android/app/src/main/kotlin/com/leadaxe/lxbox/vpn/BoxCommandClient.kt` — `urlTestGroup`
- `app/android/app/src/main/kotlin/com/leadaxe/lxbox/vpn/VpnPlugin.kt` — handler `ccUrlTestGroup`
- `app/lib/vpn/cc_channel.dart` — `urlTestGroup`
- `app/lib/controllers/home_controller/ping_orchestration.dart` — `runGroupUrltest`, комментарий `_runAllUrltestGroups`

## Docs to update

- [x] `docs/spec/features/122 commandclient-migration/spec.md` — §4.1: строка Group URLTest (отметка об отклонении + фикс §308)
- [x] `docs/spec/features/008 ping and node management/spec.md` — раздел «Run URLTest (группа)»
- [x] `docs/api/debug-api-reference.md` — `POST /action/urltest?group=` (новая семантика)
- [x] `CHANGELOG.md` — Unreleased → Fixed

## Критерии приёмки (device) — пройдены 2026-07-26

- [x] Стенд: Auto-группа, выбранный узел мёртв (выключить сервер), живые члены есть. «Run URLTest» на группе → в течение прогона группа переключается на живой узел, стрелка `→ node` обновляется без pull-to-refresh, трафик восстанавливается.
- [x] Единичный «Ping» по мёртвому узлу, который выбран Auto-группой → в debug-логе `Ping failed … → group URLTest`, группа переключается на живой. Ping мёртвого узла, НЕ выбранного группой → группового прогона нет.
- [x] Mass-ping при мёртвом выбранном в Auto → после прогона группа сама уходит на живой узел (хвост `_runAllUrltestGroups`).
- [x] Debug API `POST /action/urltest?group=` при мёртвом выбранном → `active_in_group` меняется на живой.
- [x] Регресс: «Run URLTest» на здоровой группе — выбор не скачет без причины (tolerance ядра работает), ошибок в UI нет.

Смоук на живом устройстве (2026-07-26, release APK): автопинг при запуске
прогнал все auto-группы через новый RPC (`Group URLTest started: vpn-{1,2,4}-auto`
в debug-логе), Debug API `POST /action/urltest?group=vpn-1-auto` → `ok`,
`last_error` пуст, фейлов моста в логе нет.
