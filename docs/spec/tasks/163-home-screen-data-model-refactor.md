# 163 — Рефакторинг модели данных главного экрана (три канала)

| Поле | Значение |
|------|----------|
| Тип | Task (рефакторинг модели данных существующей feature — главный экран) |
| Статус | In progress |
| Связано | [feature 122 commandclient-migration](../features/122%20commandclient-migration/spec.md) §14.4, ядровой SPEC 015 (getGroups/getOutbounds) |

Фиксирует **финальную модель данных главного экрана** после миграции на CommandClient: какие источники питают какие части UI, каким механизмом (push/pull/событие), и почему именно так. Цель — единый референс, чтобы решения не пересматривались вслепую.

---

## 1. Принцип: три раздельных канала по природе данных

Главный экран питается из **трёх независимых каналов**. Их нельзя сливать — спутывание было корнем багов (пустые группы, дребезг статуса).

| Канал | Что несёт | Источник | Транспорт | Природа данных | Механизм |
|-------|-----------|----------|-----------|----------------|----------|
| **VPN-статус** | connected / disconnected / connecting / stopping / error+причина | нативный `BoxService.setStatus()` | Android `BROADCAST_STATUS` → EventChannel → `onStatusChanged` → `_handleStatusEvent` | **событие** (дискретный переход) | push-событие |
| **CC-groups** | дерево selector/urltest-групп, выбор ноды (`selected`), `urlTestDelay` внутри групп | ядро: `SubscribeGroups` + `getGroups` (rc.4) | CommandClient gRPC (unix-сокет) | **состояние** (срез дерева) | **гибрид push+pull** |
| **CC-stats** | up/down скорость, uplinkTotal/downlinkTotal, память, connectionsIn/Out | ядро `CommandStatus` | CommandClient gRPC | **поток** (непрерывно меняется) | push |

**Аргумент разделения:** природа данных диктует механизм. Событие (статус) — push-событие. Поток (скорость/память) — push-стрим, pull тут = бессмысленный поллинг. Состояние (группы/выбор) — читается pull'ом по факту изменения, push — лишь для live-довесков. Один механизм на все три = либо лишний поллинг, либо потерянные обновления, либо перетирание.

---

## 2. VPN-статус — нативный broadcast, НЕ CommandClient

**Решение:** VPN connected/disconnected берём из `BoxService.setStatus()` → `BROADCAST_STATUS` → `_handleStatusEvent`. **НЕ** подключать `SubscribeServiceStatus` (даже когда появится в AAR).

**Аргументы:**
1. **Независимость от CommandClient.** `SubscribeServiceStatus` идёт через CommandClient-соединение. Если оно оборвётся при живом ядре (реконнект клиента, пауза), стрим статуса умрёт → UI ложно покажет «VPN упал», хотя туннель работает. Нативный broadcast питается от самого `VpnService` — ближе к источнику истины «туннель up/down».
2. **Фазы уже покрыты нативно.** `setStatus` шлёт `Starting/Started/Stopping/Stopped/revoked` + `errorMessage` → connecting-спиннер и error-причина есть без второго канала. `SubscribeServiceStatus` (5 фаз IDLE/STARTING/STARTED/STOPPING/FATAL) дублировал бы их через более хрупкий канал.
3. **В AAR rc.4 `CommandServiceStatus` отсутствует** (команды: `CommandStatus=1`/`CommandGroup=2`/`CommandClashMode=3`) — вопрос пока чисто теоретический, но решение фиксируем на будущее.

**Дребезг `setStatus(Stopped)`** (несколько teardown-путей слали повторный/запоздалый `Stopped` → перетирал live-state) закрыт **native dedup** в `BoxService.setStatus` (`status==newStatus && error==null` → no-op) + **Dart stale-terminal guard** в `_handleStatusEvent` (повторный терминал при уже-терминальном `prevTunnel` не рвёт стримы). Это лечение источника, не симптома.

---

## 3. CC-groups — гибрид push + pull (НЕ инверсия на чистый pull)

**Решение:** push-подписка (`_cc.groups.listen` → `_onCcGroups`) **остаётся** как источник live-обновлений; pull (`getGroups`) добавлен как **lifeline** там, где push ненадёжен.

### 3.1 Что несёт push (почему нельзя убрать)
`SubscribeGroups`-push будится ядровым `urlTestObserver` и эмитит новый снапшот при:
- **авто-переключении urltest-группы** — ядро само выбрало лучший узел, сменило `selected`. UI узнаёт об этом ТОЛЬКО из push.
- **`urlTestDelay` внутри группы** — delay узлов в urltest-группе обновился.

Убрать push и читать только pull по connected+switchNode = потерять оба: UI покажет старый urltest-выбор и старые delay до ручного действия.

### 3.2 Что несёт pull (lifeline там, где push дырявый)
`getGroups()` (unary, rc.4 SPEC 015) дёргается на **событиях-триггерах**:
- **`connected`** (`_startGroupsPull`) — закрывает потерянный стартовый push (гонка ядрового `waitForStarted`: подписка в фазе STARTING могла пропустить STARTED → снапшот не пришёл → пустой экран при `tunnel=connected`). Ретрай 400мс×12 пока ядро не STARTED (getGroups бросает до STARTED).
- **после `switchNode`** (ручной выбор ноды) — `selectOutbound` меняет выбор, но push с новым `selected` приходит не сразу/не всегда (ручной select ≠ urltest-замер, не гарантированно будит `urlTestObserver`). Pull даёт новый `selected` мгновенно → чинит «горит старая нода до свайпа».
- **`pullToRefresh`** (свайп вниз) — ручной перезапрос.

### 3.3 Семантика возврата `getGroups`
- `null` = ядро не STARTED / нет клиента → НЕ трогаем state (ретрай или оставляем текущее).
- `[]` = STARTED, групп реально нет → применяем (редко, конфиг без selector'ов).
- непустой = снапшот → `_applyGroups`.

Различение `null` vs `[]` критично: `null` не должен обнулять live-данные.

### 3.4 Empty-push guard (защита live от шумного push)
`_onCcGroups`: если `groups.isEmpty && _state.ccGroups.isNotEmpty` → игнор. Ядро изредка шлёт пустой push поверх наполненного дерева (та же гонка) — принять = перетереть `ccGroups/nodes` пустотой (device-факт: nodes мелькали 95→0). Пустых selector-групп при `connected` с трафиком не бывает → пустой push поверх живого = шум. Guard корректен и при наличии pull. Первый легитимный пустой (старт, `ccGroups` ещё пуст) проходит.

---

## 4. CC-stats — push (включая лёгкую статистику в шапке главного)

**Решение:** скорость/память/conns-бейдж — push status-стрим (`CommandStatus`, интервал `1e8`=0.1с).

**Аргумент:** статистика по природе непрерывный поток, меняется сама без «действий». Pull = поллинг по таймеру (ровно то, от чего §122 уходил с Clash). Push идеален: ядро толкает по мере событий.

**Двойное потребление:** один и тот же status-стрим питает И лёгкую статистику в шапке **главного** экрана, И вкладку **Stats**. Главный экран НЕ теряет статистику при переходе groups на pull — статистика на отдельном канале (`_onCcStatus`), не на groups.

**UI-троттлинг** (нагрузка от 0.1с-тика):
- главный экран `_trafficEmitThrottle` = 1с (ребилд node-list из ~95 нод не чаще раза в секунду);
- память Stats `_memoryRefresh` = 3с (медленная метрика, не мельтешит);
- вкладка Stats / Conns берут полный 0.1с-поток.

Корень groups:[] был НЕ в интервале (раньше ошибочно винили `1e8`) → `STATUS_INTERVAL=1e8`.

---

## 5. Delay одиночных узлов (`lastDelay`) — синхронно из RPC, НЕ из groups-push

**Решение:** delay узлов на главном (`state.lastDelay[tag]`, показывается в `NodeRow`) пишется напрямую из ответа `URLTestOutbound`-RPC, не через groups-push.

**Аргумент:** mass-ping (`runMassUrltest`) и одиночный ping (`runNodeUrltest`) зовут `URLTestOutbound` (синхронный unary, rc.2) и пишут `_emit(lastDelay: ...)` сразу из ответа. Инвариант: `delay==0 && error==''` = успех 0мс (не фейл). Это делает delay-обновление **независимым** от groups-push — убирает класс багов «прогнал пинг, а UI не перерисовал». (`urlTestDelay` ВНУТРИ urltest-группы — отдельная вещь, идёт через push, см. §3.1.)

---

## 6. Карта: часть UI ← источник

| Часть главного экрана | Источник | Канал |
|-----------------------|----------|-------|
| Кнопка Start/Stop, статус-индикатор | `_handleStatusEvent` | VPN-статус (broadcast) |
| Список нод (состав, выбор группы) | `ccGroups` ← `getGroups` pull + `SubscribeGroups` push | CC-groups (гибрид) |
| Активная нода в группе (`activeInGroup`) | `group.selected` ← pull (switchNode) + push (urltest auto-switch) | CC-groups (гибрид) |
| urltest-выбор (`urltestNow`) | `group.selected` urltest-группы ← push | CC-groups (push) |
| Пинг узла (`lastDelay`) | `URLTestOutbound`-RPC синхронно | CC (unary RPC) |
| Скорость ↑↓, трафик, conns-бейдж в шапке | `_onCcStatus` | CC-stats (push) |

---

## 7. Критерии приёмки

1. VPN-статус приходит из broadcast; обрыв CommandClient не роняет индикатор статуса.
2. На `connected` группы наполняются детерминированно (pull lifeline), даже если стартовый push потерян; пустого экрана при `tunnel=connected` нет.
3. Ручное переключение ноды (`switchNode`) обновляет активную ноду в UI **без свайпа** (pull даёт новый `selected` сразу).
4. Авто-переключение urltest-группы и `urlTestDelay` обновляют UI через push (без ручного действия).
5. Mass-ping/одиночный ping обновляют delay узлов синхронно из RPC, без зависимости от groups-push.
6. Лёгкая статистика в шапке главного и вкладка Stats питаются от одного status-push; переход groups на pull не ломает статистику.
7. Пустой groups-push поверх живого дерева игнорируется (guard); `null` от `getGroups` не обнуляет state.
8. Дребезг `setStatus(Stopped)` не перетирает live-state (native dedup + Dart guard).

---

## 8. Затронутые файлы (факт)

- `app/lib/controllers/home_controller.dart` — `_startCcStreams` (status+groups listen, connectScreen, `_startGroupsPull`), `_onCcStatus`, `_onCcGroups` (+ empty-push guard), `_applyGroups`, `applyGroup`, `switchNode` (getGroups pull), `pullToRefresh` (getGroups), `_handleStatusEvent` (stale-terminal guard).
- `app/lib/vpn/cc_channel.dart` — `getGroups(): List<CcGroup>?`, `groups`-стрим (push), `status`-стрим.
- `app/android/.../BoxCommandClient.kt` — `getGroups()`, `serializeGroup` (общий push+pull), `STATUS_INTERVAL=1e8`.
- `app/android/.../BoxService.kt` — `setStatus` dedup.
- `app/android/.../VpnPlugin.kt` — `ccGetGroups` (Dispatchers.IO), `BROADCAST_STATUS` receiver.

---

## 9. Вне скоупа

- `SubscribeServiceStatus` для VPN-статуса — отклонён (§2, хрупкий через CommandClient).
- Инверсия groups на чистый pull (убрать push) — отклонена (§3.1, потеря live urltest-обновлений).
- `getOutbounds`-pull — зарезервирован (node-list строится из групп; нужен для плоского списка endpoint'ов/одиночных outbound'ов — будущее).
- Stats-движок и полный управляющий API — отдельные задачи (пункты 3, 4 рефакторинг-плана).
