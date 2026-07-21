# 088 — Wake-heal: эскалирующее восстановление туннеля (failure mode 2)

| Поле | Значение |
|------|----------|
| Статус | ⏸️ On hold (design-документ) — реализации в коде НЕТ (нет USER_PRESENT-ресивера / escalation-ladder / gate-probe). Отложено осознанно вместе с отказом от health-watchdog [§042](../features/042%20health%20watchdog/spec.md) (батарея). Ручной recovery покрыт §087 (force-reset на смену сети) + §030 reload + §031 resetNetwork. Реализовал бы failure mode 2 из §086. |
| Дата | 2026-06-08 |
| Тип | feature / native + Dart |
| Основание | [§086](086-stale-connections-network-change-doze.md) — root-cause найден; §087 закрыл failure mode 1 (смена сети), **mode 2 остаётся**. |
| Зависимости | §087 (network-change reset — соседний failure mode), §042 (health watchdog spec — переиспользуем dual-signal для entry-условия), готовые примитивы `resetNetwork`/`reloadVPN`/`startVPN` (`box_vpn_client.dart`). |
| Файлы (план) | native: wake-receiver (`USER_PRESENT` / Doze-exit); Dart: escalation-helper + gate-probe. |

## Проблема (из §086 failure mode 2)

После долгого простоя / deep Doze туннель «залипает»: пока не сделаешь полный
reset — ничего не грузит. Ручной пинг — **рандом** (иногда оживляет, иногда
нет), потому что под одним симптомом два разных состояния:

- **STATE A** — NAT/outbound staleness: runtime жив, стейл только сокеты →
  `resetNetwork()` лечит.
- **STATE B** — whole-stack timer freeze (Go `CLOCK_MONOTONIC` не идёт во сне,
  все sing-box таймеры замёрзли) → нужен `reloadVPN`/restart.

Заранее не знаешь какой state → **одно фиксированное действие ненадёжно**.

## Цель

**Событийный wake-heal**: на пробуждении детектить мёртвый туннель и
восстанавливать **эскалацией с проверкой результата** — дёшево→дорого,
доходя до restart **только когда реально надо**. Детерминированно (не рандом).

**Жёсткое требование (юзер):** пока экран выключен / телефон спит — **НИЧЕГО**
не делать, батарею не жрать. Только реакция на пробуждение.

## Дизайн

### Лестница с RE-CHECK GATE

```
пробуждение (событие, не таймер)
  ↓
GATE: туннель реально жив? ← РЕАЛЬНЫЙ запрос через туннель (urltest/HTTP-204
  │                          через Clash delay endpoint), НЕ статус-флаг
  │                          (zombie-tunnel: handshake OK ≠ data-path OK)
  ├─ жив   → СТОП (ничего; копейки работы — это и защита батареи)
  └─ мёртв → resetNetwork()  (<1s, лечит STATE A)
               ↓ GATE
               ├─ ожил → СТОП
               └─ мёртв → reloadVPN()  (~3s, лечит STATE B — будит runtime)
                            ↓ GATE
                            ├─ ожил → СТОП
                            └─ мёртв → startVPN/stopVPN restart (last resort)
```

- **GATE = реальный запрос через туннель**, не статус. Защита от zombie-tunnel
  (rethink #2602, sing-box #1415 — liveness-OK при мёртвом data-path).
- Каждая ступень **проверяется** прежде чем эскалировать → детерминизм вместо
  рандома.
- Все три примитива (`resetNetwork`/`reloadVPN`/`startVPN`) **уже** callable
  из Dart.

### Entry-условие (опционально, против ложных heal)
Не запускать лестницу без признаков деградации (переиспользуем §042
dual-signal): `urltest-not-confirming` **AND** `no-traffic-streak ≥ N` (+
`connectionsCount > 0` фильтр, чтобы idle не триггерил). На явном wake-событии
можно сразу GATE — но dual-signal убирает лишние probe'ы при здоровом туннеле.

### Триггеры (всё событийное — нет поллинга)

| Триггер | Источник | Действие |
|---|---|---|
| **Разблокировка** | native `ACTION_USER_PRESENT` | gate → лестница. **USER_PRESENT, не SCREEN_ON** — экран зажигается от ночных уведомлений без разблокировки; на них лечить = лишняя батарея |
| **Выход из Doze** | native `ACTION_DEVICE_IDLE_MODE_CHANGED` (не idle) | gate → лестница |
| **App foreground** | Dart `AppLifecycleState.resumed` (hook есть) | gate → лестница (foreground-путь) |

### Battery (требование юзера — выполнено двойной защитой)
1. **Событийность** — нет периодического таймера → нечему будить устройство во
   сне → zero work пока спит.
2. **Gate-first** — на пробуждении сначала **проверяем**; если туннель жив
   (частый случай) — лестница не запускается. Это же защищает от регрессии
   класса #3400 (мы **не** ресетим вслепую — только когда probe показал смерть).

## Recovery-примитивы (готовы, §086)
- `resetNetwork()` <1s — CloseAll + DNS/transport rebind (STATE A).
- `reloadVPN()` ~3s — `startOrReloadService`, будит runtime без teardown tun
  (STATE B).
- `startVPN`+`stopVPN` 5-10s — full restart (last resort; сегодня это
  **единственное** что есть в `_onTunnelDead` — cliff).

## Что нужно реализовать (план, не в этой таске)
- **Native wake-receiver**: `BroadcastReceiver` на `ACTION_USER_PRESENT` +
  `ACTION_DEVICE_IDLE_MODE_CHANGED`. Только при включённом self-heal. Не путать
  с pause/wake sing-box (#3400-механика — её не трогаем).
- **Dart escalation-helper**: лестница + gate-probe (переиспользует Clash
  `delay`). Точка входа — `onAppResumed` + сигнал от native wake-receiver.
- **Doze whitelist** — нужен чтобы native успел отработать на wake (prompt
  battery-optimization уже есть в app).

## Открытые вопросы (для дизайн-согласования перед реализацией)
- Сколько ждать между ступенями (gate-timeout) — `delay` timeout уже есть.
- Сколько раз ретраить gate перед эскалацией (1 или N с backoff).
- Показывать ли юзеру что идёт self-heal (snackbar «restoring…») или молча.
- Фоновый путь: native гонит лестницу сам (Dart спит) или будит Dart? —
  resetNetwork/reload/restart есть и в native (broadcast), gate-probe — Clash
  HTTP (можно из native или из разбуженного Dart). Решить.

## Связанный follow-up — §087 threading (`lastIfName`)

> Замечание из инспекции §087 (network-change reset). Не блокер, зафиксировано
> чтобы не потерялось.

`DefaultNetworkMonitor.lastIfName` пишется из **двух контекстов**: `notifySync`
(вызван из `start()` на attach) и `checkUpdate` (actor `DefaultNetworkListener`).
`@Volatile` даёт **visibility**, но **не atomicity**. Реальное окно гонки —
только attach-time; самокорректируется на следующем событии (ложный/пропущенный
reset разово). Таска §087 это осознаёт (комментарий про два потока).

**Не критично.** Идеальный hardening — confine `lastIfName` к одному
dispatcher (или весь network-monitor state в один actor/single-thread executor),
но для attach-edge это **overkill**. Оставить как known-minor; трогать только
если на практике увидим ложные/пропущенные ресеты при старте.

## Не в скопе
- Реализация (native receiver, Dart лестница, тесты) — отдельной задачей после
  согласования открытых вопросов.
- §042 watchdog полная реализация (HeartbeatHealth/HealthWatchdog) — связана
  (dual-signal), но отдельна.
- Failure mode 1 (смена сети) — закрыт §087.

## Файлы / источники
- `docs/spec/tasks/088-wake-heal-escalation.md` (этот файл).
- Research: §086 (workflow `wf_3dad08c9-32d`, `wf_c3db7f6b-e01`, 11 агентов).
- Связанные: §086, §087, §042.
