# 150 — WG-endpoint режет download на LTE без `detour: direct` — расследование

| Field | Value |
|------|----------|
| Status | **Investigating** — корень доказан по коду (split-brain UDP_GRO/runtime-GOOS на Android); остаётся пакетное подтверждение + девайс-замер; фикс не делается до репро |
| Started | 2026-06-20 |
| Trigger | Field report (CoolMask / Иван, 4PDA, 2026-06-15). WireGuard-**endpoint** на мобильном интернете (LTE, МТС) даёт download **0,44 Mbps**; тот же конфиг с `"detour": "direct"` на endpoint'е — **150 Mbps**. На Wi-Fi обе версии работают. Воспроизводится на нескольких версиях подряд; в форке `shtorm-7/sing-box-extended` бага нет. |
| Repro | Speedtest, один телефон (Samsung SM-A736B, Android 16 / OneUI 8), одна сота МТС, разница только в `detour`: **без** — 0,44↓ / 19,4↑ / ping 140; **с** `detour: direct` — 150↓ / 53,3↑ / ping 144. Конфиги — в приложении к таске (ниже). |
| Related | [§128](128-force-direct-out-detour.md) (detour на пустой direct запрещён ядром — **другой** кейс), [§111](111-subscription-detour-without-native-chain.md), [§124](124-perapp-self-protect-allowbypass.md) (protect на сокете), память `project_wg_endpoint_detour_speed` (**содержит опровергнутую гипотезу — см. ниже**) |
| Core repo | `/Users/macbook/projects/sing-box-lx` (фикс — на стороне ядра, не клиента) |

---

## TL;DR

> No-detour WG-endpoint на Android поднимает UDP-сокет к peer через **`StdNetBind`**.
> На сокете **включается `UDP_GRO`** (`controlfns_linux.go:64` — файл компилируется на
> Android, т.к. имя `*_linux.go` без `!android`), и `rxOffload` читается **true**
> (`features_linux.go:21`). НО приёмный разбор GRO-блоба (`splitCoalescedMessages`)
> гейтится на **`runtime.GOOS == "linux"`** (`bind_std.go:272`), а на Android
> `GOOS == "android"` → берётся **else**-ветка с голым `ReadMsgUDP` (`bind_std.go:289`),
> которая отдаёт **склеенный GRO-«суперпакет» как один пакет**. `device/receive.go`
> парсит только первый WG-заголовок → хвост ломает AEAD → **download рушится**.
>
> **Корень = split-brain между build-constraint и runtime-GOOS**: `UDP_GRO` включён
> (build-tag-семейство linux включает android), но split-путь не исполняется
> (`runtime.GOOS=="android" != "linux"`), а настоящий cmsg-парсер выключен
> (`control_linux.go` = `//go:build linux && !android`). Это **детерминированный
> структурный баг**, не «LTE портит сегменты» — LTE лишь чаще триггерит коалесинг
> бёрстами (выше hit-rate). `detour: direct` лечит, уводя сокет на `ClientBind`, где
> offload-кода нет вообще.
>
> **Не подтверждено пакетным замером на устройстве. Фикс не делается до репро.**

> ⚠️ **Правка от 2026-06-20 (вторая итерация ревью).** Прежняя версия этой спеки винила
> «отсутствие RX self-disable в GRO» (`splitCoalescedMessages` без fallback). Это
> **неверно**: на Android та ветка — мёртвый код (`GOOS != "linux"`), и предложенный
> «RX self-disable» был бы **no-op**. Реальный механизм — split-brain выше. Подробности
> и две дополнительно вскрытые дыры — в разделах ниже.

Эта таска — журнал расследования, чтобы не пройти по уже отвергнутым следам.
Гипотезы в разделе «Опровергнутые» отвергнуты по коду намеренно.

---

## Развилка путей — что определяет всё

`transport/wireguard/endpoint.go:200-215`:

```go
var bind conn.Bind
wgListener, isWgListener := common.Cast[dialer.WireGuardListener](e.options.Dialer)
if isWgListener {
    bind = conn.NewStdNetBind(wgListener.WireGuardControl())   // ← NO-DETOUR
} else {
    bind = NewClientBind(..., e.options.Dialer, ...)           // ← DETOUR
}
```

- `WireGuardListener` (интерфейс с единственным методом `WireGuardControl()`,
  `common/dialer/wireguard.go`) реализует **только** `DefaultDialer`
  (`common/dialer/default.go:374`). `DetourDialer` его **не** реализует.
- **No-detour** (Иван без `detour`): dialer endpoint'а = `DefaultDialer` →
  `isWgListener == true` → **`StdNetBind`**. `ClientBind` и `client_bind.go:89`
  **не задействованы**.
- **Detour** (`detour: direct`): dialer = `DetourDialer` → `isWgListener == false`
  → **`ClientBind`** → `client_bind.go:89` `c.dialer.ListenPacket(...)` проксирует
  на `direct`-outbound.

То есть `detour: direct` физически **меняет реализацию UDP-bind'а** — это не «другой
маршрут», а другой код пересылки пакетов.

---

## Гипотезы — статус (отвергнутые помечены, не повторять)

### ❌ Гипотеза 1 — «MTU / фрагментация»

Первая публичная версия. Опровергнута практикой: Иван понижал WG MTU до 1000 — не
помогло. Подтверждается асимметрией: при MTU-проблеме резало бы симметрично, а здесь
download убит (150→0,44), upload жив (53→19), ping не меняется.

### ❌ Гипотеза 2 — «у no-detour endpoint нет network-strategy / умного выбора интерфейса»

Зафиксирована в памяти `project_wg_endpoint_detour_speed` как «сильная гипотеза по
коду». **Опровергнута при дочитывании:**

- На Android (`platformInterface.UsePlatformAutoDetectInterfaceControl() == true`)
  `NetworkManager.ProtectFunc()` (`route/network.go:368`) и `AutoDetectInterfaceFunc()`
  (`route/network.go:340`) возвращают **одно и то же** — оба зовут
  `platformInterface.AutoDetectInterfaceControl(fd)` (привязка к активному интерфейсу).
  Различаются только **не**-на-Android.
- `WireGuardControl()` = `d.udpListener.Control` (`default.go:374`), а в Control на
  Android-ветке (`default.go:115`) уже навешан этот платформенный bind.
  `StdNetBind.listenNet` (`conn/bind_std.go:139`) применяет `externalControl` к
  **каждому** открываемому сокету.
- Вывод: no-detour сокет на Android **уже** привязан к активному интерфейсу через
  `AutoDetectInterfaceControl`. Путь `ListenSerialInterfacePacket` / `NetworkStrategy`
  не даёт дополнительной интерфейс-привязки сверх платформенного вызова. **Разница
  150 vs 0,44 — не в выборе интерфейса.**

### ⚠️ Под-гипотеза «застрявший сокет после хэндовера» — НЕ опровергнута (была закрыта неправомерно)

Прежде помечалась refuted: «`onPauseUpdated` → `device.Up()` → `BindUpdate()`
(`wireguard-go device.go:478`) переоткрывает сокет, значит re-bind есть».

**Это верно только для смены *интерфейса*, не для смены IP внутри интерфейса.**
`BindUpdate` действительно пересоздаёт сокет — но вызывается только по событию
`NetworkWake`, а оно эмитится из `notifyInterfaceUpdate`, который **дедуплицирует по
`Name + Index`** (`experimental/libbox/monitor.go:95-98`):

```go
if oldInterface != nil &&
   oldInterface.Name == m.defaultInterface.Name &&
   oldInterface.Index == m.defaultInterface.Index {
    return   // ← событие подавлено; Addresses НЕ сравниваются
}
```

Тихий хэндовер соты (тот же интерфейс `rmnet`, **новый IP**) → дедуп подавляет событие
→ нет `NetworkWake` → нет `BindUpdate` → re-bind **не происходит**, сокет остаётся на
устаревшем source-IP. Это **живой независимый кандидат**, не опровергнут. Менее
вероятен как *первичный* корень (хуже объясняет чистую асимметрию download/upload, чем
GRO split-brain), но проверять — если GRO-эксперимент не починит.

---

## Главный корень — split-brain build-constraint vs runtime-GOOS (UDP_GRO на Android)

Ключ: **на Android `runtime.GOOS == "android"`, а НЕ `"linux"`** — при том, что в
системе build-тегов Android входит в семейство linux. Отсюда расхождение.

### Сторона build-тега: UDP_GRO включается на Android

Файлы с **именем** `*_linux.go` без явного `&& !android` компилируются на Android:

- `controlfns_linux.go:64` (name-based constraint) — на каждом открываемом сокете:
  ```go
  _ = unix.SetsockoptInt(int(fd), unix.IPPROTO_UDP, socketOptionUDPGRO, 1)  // UDP_GRO=1
  ```
- `features_linux.go:21` (name-based) — `supportsUDPOffload` читает обратно:
  ```go
  opt, _ := unix.GetsockoptInt(fd, IPPROTO_UDP, socketOptionUDPGRO)
  rxOffload = opt == 1   // ← true на Android
  ```
- `bind_std.go:220` → `s.ipv4RxOffload = true`, передаётся в `makeReceiveIPv4`.

### Сторона runtime-GOOS: разбор GRO-блоба НЕ исполняется на Android

`receiveIP` (`bind_std.go:272`):
```go
if runtime.GOOS == "linux" {        // ← на Android FALSE
    if rxOffload {
        br.ReadBatch(...)
        splitCoalescedMessages(...) // ← разбор GRO-«суперпакета» на сегменты
    } ...
} else {                            // ← Android идёт СЮДА
    msg.N, _, _, msg.Addr, _ = conn.ReadMsgUDP(...)  // голый recv, OOB не разбирается
    numMsgs = 1
}
```

- `splitCoalescedMessages` (`bind_std.go:548`) — **мёртвый код на Android** (достижим
  только из `:279`, под `GOOS=="linux"`).
- Настоящий cmsg-парсер `getGSOSize` живёт в `control_linux.go`
  (`//go:build linux && !android`) → на Android берётся **stub** `control_default.go`
  (`!(linux && !android)`). Размер GRO-сегмента негде взять, даже если бы хотели.

### Следствие — детерминированный обвал download

`UDP_GRO=1` заставляет ядро коалесить несколько WG-транспорт-пакетов в один recv
(до ~64КБ). Android-ветка `ReadMsgUDP` возвращает этот блоб как **один** пакет
(`numMsgs=1`, `msg.N` = весь блоб). `device/receive.go` парсит только **первый**
WG-заголовок; хвост блоба идёт как мусор → AEAD-decrypt падает → пакеты дропаются →
**download рушится**. Это не «LTE портит сегменты»: баг структурный и постоянный, LTE
лишь повышает частоту коалесинга бёрстами → выше hit-rate, оттого ярче на сотовой.

### Почему upload выживает (исправлено — прежнее объяснение было шатким)

Upload защищён **двумя независимыми причинами**, и ни одна — не «GSO самоотключается»:

1. **TX-коалесинг гейтится тем же `GOOS=="linux"`** (`bind_std.go:463`): на Android
   `send` идёт в else-ветку (`:470` `WriteMsgUDP` по одному) — коалесинга на отправке
   **нет вообще**.
2. **`BatchSize == 1`** для tun-режима Ивана: без `system`-флага → `newStackDevice`
   (`transport/wireguard/device.go:40`) → `stackDevice.BatchSize()==1`
   (`device_stack.go:268`) → `device/send.go:223` `batchSize=1` → буфер отправки на
   один пакет, склеивать нечего.

То есть проблема **односторонняя по построению**: коалесинг бьёт только приём.

### Почему `detour: direct` лечит

С detour сокет идёт через `ClientBind` (`transport/wireguard/client_bind.go`) — простой
`DialContext`/`ListenPacket`, **offload-кода нет вообще** (ни `UDP_GRO`, ни split).
Пакет-в-пакет → проблемный путь обходится целиком.

### `shtorm-7` без бага

Вероятно собран с conn-веткой, где либо `UDP_GRO` не ставится на android, либо split
гейтится не по `GOOS`. Требует проверки исходника форка (не блокер для фикса).

**Статус корня:** доказан по коду как структурный механизм; остаётся подтвердить
**пакетным замером**, что `recvmsg` на этом сокете реально отдаёт >MTU датаграммы
(снимает остаточное «а коалесит ли GRO вообще»).

---

## Второй кандидат (ниже приоритет) — DF-бит / UDPFragment

`protocol/direct/outbound.go:48` принудительно ставит `UDPFragmentDefault = true`
каждому direct-outbound. У endpoint'а `UDPFragment` зависит от его `DialerOptions`
(`default.go:166-178`: при `!udpFragment` навешивается `control.DisableUDPFragment()` =
DF-бит). Если у endpoint-сокета DF выставлен иначе, чем у direct, поведение
фрагментации исходящих UDP на LTE будет разным. Менее вероятно (не объясняет асимметрию
так чисто, как GSO), но проверить дёшево.

---

## План проверки (эксперимент, не релиз)

**Дискриминирующий эксперимент** — изолирует именно RX/GRO (TX не трогаем):

1. Запатчить `controlfns_linux.go` — **пропускать** `setsockopt(UDP_GRO)` при
   `runtime.GOOS == "android"` (TX/GSO не трогать). Это самый чистый разрез: если корень
   — GRO, отключение ровно его покажет, не меняя ничего на отправке.
   - Эквивалент: гейтить `rxOffload` за `!android` в `features_linux.go` / при передаче
     в `makeReceiveIPv4/6`.
2. Дать Ивану тот же **no-detour** конфиг (приложение ниже).
3. Замер Speedtest на той же LTE-соте:
   - **download починился при живом upload** → корень = GRO-на-android **подтверждён**,
     и минимальный правильный фикс найден тем же шагом (гейт `UDP_GRO`+`rxOffload` за
     `!android`);
   - **не починился** → следующий подозреваемый — тихий хэндовер соты (см. под-гипотезу
     выше), затем DF/UDPFragment.

**Параллельно — пакетное подтверждение** (снимает остаточное сомнение «коалесит ли GRO
вообще»): на том же сокете убедиться, что `recvmsg` отдаёт датаграммы **> MTU** (один
recv > 1392 байт). Если да — коалесинг реально происходит; это прямое доказательство
механизма, независимое от Speedtest.

NB: эксперимент через прод-релиз **не выкатывать**. Память
`feedback_releases_only_ci_built` — артефакт CI; для девайс-теста — отдельная сборка,
не подмена.

---

## Решение

Пока **нет**. Это таска-расследование. Любой код в ядре `sing-box-lx` — только после
того, как замер на устройстве Ивана подтвердит конкретный кандидат. Не объявлять
публично «решением» до репро (ровно как с MTU-гипотезой, которую юзер опроверг).

## Минимальный правильный фикс (когда корень подтверждён замером)

Гейтить UDP-GRO/rxOffload за `!android`, чтобы build-tag и runtime-GOOS перестали
расходиться. Точечно: пропускать `setsockopt(UDP_GRO)` (`controlfns_linux.go:64`) и/или
форсить `rxOffload=false` (`features_linux.go`) при `runtime.GOOS=="android"`. **TX не
трогать** — на Android он и так не коалесит (GOOS-гейт + BatchSize=1).

> ❗ НЕ «добавить RX self-disable в split-путь» — на Android этот путь не исполняется,
> фикс был бы no-op. Чинить надо включение GRO, не его (несуществующий) разбор.

## Acceptance (для будущего фикса, когда корень подтверждён)

- [ ] Пакетно подтверждено: до фикса `recvmsg` отдаёт >MTU блобы, после — нет.
- [ ] No-detour WG-endpoint на LTE даёт download, сопоставимый с `detour: direct`,
      на устройстве Ивана (или эквивалентном LTE-репро).
- [ ] Фикс не ломает multi-peer / Wi-Fi / производительность на стабильной сети.
- [ ] Регресс-проверка plain WG **и** AmneziaWG endpoint'ов.
- [ ] Перепроверить под-гипотезу хэндовера (`monitor.go:95-98` дедуп по Name+Index):
      если останется остаточная деградация при тихой смене соты — отдельный фикс
      (учитывать Addresses в дедупе или re-bind по смене source-IP).

## Приложение — конфиги репро (от Ивана, ключи — тестового юзера на его VPS)

**Нерабочий (без detour):** endpoint `WG` без `detour`, `final: WG`, tun mtu 9000,
wg mtu 1392, direct-outbound с `connect_timeout: 5s`.

**Рабочий (с detour):** тот же + `"detour": "direct"` в объекте endpoint'а.

(Полные JSON — в переписке 4PDA/ТГ от 2026-06-15; `connect_timeout: 5s` на direct
делает его непустым, поэтому запрет §128 не срабатывает — но к корню §150 это
отношения не имеет, см. «Развилка путей».)

## Источники (всё проверено по живому коду 2026-06-20)

**Развилка путей:**
- `transport/wireguard/endpoint.go:200-215` — StdNetBind (no-detour) vs ClientBind (detour).
- `common/dialer/wireguard.go` — `WireGuardListener`; реализует только `DefaultDialer`.
- `common/Cast` (`sing@v0.8.10/common/upstream.go:13`) — рекурсивна по `Upstream()`;
  `DetourDialer.Upstream()` (`common/dialer/detour.go:82`) → direct `*Outbound`, который
  `WireGuardListener` НЕ реализует → каст проваливается → `ClientBind`.
- single-peer Ивана → `isConnect=true` (`endpoint.go:208`) → `client_bind.go:79`
  `DialContext` (НЕ `ListenPacket`).

**Корень (split-brain GRO):**
- `conn/controlfns_linux.go:64` (name-based `*_linux.go`) — `setsockopt(UDP_GRO,1)` на Android.
- `conn/features_linux.go:21` (name-based) — `supportsUDPOffload` → `rxOffload=true` на Android.
- `conn/bind_std.go:272` — RX-разбор под `runtime.GOOS=="linux"`; else `:289` `ReadMsgUDP`.
- `conn/bind_std.go:548` `splitCoalescedMessages` — мёртвый код на Android.
- `conn/control_linux.go` `//go:build linux && !android` → stub `control_default.go` на Android.
- `conn/bind_std.go:463/470` — TX-коалесинг тоже под `GOOS=="linux"` (на Android off).
- `transport/wireguard/device.go:40` → `stackDevice.BatchSize()==1` (`device_stack.go:268`)
  → `device/send.go:223` (upload: нечего коалесить).
- `transport/wireguard/client_bind.go` — detour-путь, offload-кода нет вовсе.

**Под-гипотеза хэндовера (не опровергнута):**
- `experimental/libbox/monitor.go:95-98` — дедуп по `Name+Index`, Addresses игнорируются.
- `wireguard-go device.go:478` `BindUpdate` ← `endpoint.go:316` `onPauseUpdated` —
  re-bind есть, но только по `NetworkWake` (смена интерфейса), не по смене source-IP.
