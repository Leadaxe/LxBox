# §494 — долги Debug API после проверок на эмуляторе

| | |
|---|---|
| **Статус** | **Released в v2.25.0** (20.09.2026, ядро `v1.14.1-lx.8`). Реализовано |
| **Дата** | 2026-09-19 |
| **Источник** | прогон Debug API на эмуляторе после фичи 478 |
| **Связанные** | фича 478, §165, §047 (Intent API), `docs/api/debug-api-reference.md` |

## Проблема

После проверки страховки ядра на эмуляторе остались шесть долгов Debug API:

1. `POST /action/start-vpn-headless?guard=true` гнал страховку через
   `startVPN` (нужна Activity) → сразу `unavailable`, хотя headless-путь без
   флага работает.
2. Не было сброса состояния прогона в памяти без снятия вердиктов.
3. `GET /subs/{id}?warnings=true` отдавал только узлы с предупреждениями; не
   хватало `origin_kind` / `source_kind` у записи.
4. `POST /action/check-config` всегда читал конфиг с диска — нельзя было
   проверить произвольное тело.
5. У вердикта одиночного сервера `source` в `/core_reject/nodes` был пустой
   (`list.name` у UserServer пуст по §243).
6. `POST /action/start-vpn` обходил страховку напрямую через `home.start()`.

## Решение

| № | Было | Стало |
|---|---|---|
| 1 | `guard=true` → `startAndAwaitVerdict` / Activity | `runCoreRejectGuard(headless:true)` → `startAndAwaitVerdictHeadless` / `startVpnHeadless` |
| 2 | — | `POST /core_reject/reset` → `CoreRejectState.resetRunState()` (`phase→idle`, `round→0`; вердикты и плашка не трогаются) |
| 3 | только узлы с warnings | все узлы (`[]` без предупреждений); `origin_kind`, `source_kind` при `warnings=true` |
| 4 | только диск | тело запроса = проверяемый JSON; без тела — как раньше |
| 5 | `list.name` (пусто у UserServer) | `SubscriptionEntry.displayName` |
| 6 | `home.start()` | `runCoreRejectGuard(guard:false)` — прежний старт через Activity, без цикла страховки |

**Intent API (§047):** `actionStartVpn` публичный Intent не обслуживает —
`automation_dispatcher` его не роутит; native `LxBoxIntentReceiver` зовёт
`BoxVpnService.start` напрямую. Поведение Intent API не менялось.

Обновлены `/help` (text + `?format=json`) и `docs/api/debug-api-reference.md`.

## Критерии приёмки

- `POST /action/start-vpn-headless?guard=true` на устройстве с выданным VPN-
  разрешением проходит сигнальный старт headless-путём; фаза читается через
  `GET /core_reject`.
- `POST /core_reject/reset` сбрасывает `phase`/`round`, вердикты в
  `/core_reject/nodes` остаются.
- `GET /subs/{id}?warnings=true` — все теги узлов, пустые списки без warnings,
  поля `origin_kind`/`source_kind`.
- `POST /action/check-config` с телом проверяет переданный JSON.
- `/core_reject/nodes` у одиночного сервера: непустой `source` = display name.
- `POST /action/start-vpn` — `guard=false` через общий runner; Intent API без
  изменений (зафиксировано в спеке).
- `flutter analyze` — без новых issues; затронутые тесты зелёные.

## Ревью

Публичный Intent API (§047) этот путь не зовёт: native `LxBoxIntentReceiver`
и Locale-плагин идут в `BoxVpnService.start` напрямую, `automation_dispatcher`
не роутит `start-vpn`. Поведение наружу не менялось.

`POST /core_reject/reset` во время идущего прогона отвечает 409 — иначе
отвяжется cancel, а автомат потом перезапишет фазу.
