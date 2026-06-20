# 150 — WG-endpoint режет download на LTE без `detour: direct` — расследование

| Field | Value |
|------|----------|
| Status | **Investigating** — корень сужен по коду, не подтверждён на устройстве; фикс не делается до замера |
| Started | 2026-06-20 |
| Trigger | Field report (CoolMask / Иван, 4PDA, 2026-06-15). WireGuard-**endpoint** на мобильном интернете (LTE, МТС) даёт download **0,44 Mbps**; тот же конфиг с `"detour": "direct"` на endpoint'е — **150 Mbps**. На Wi-Fi обе версии работают. Воспроизводится на нескольких версиях подряд; в форке `shtorm-7/sing-box-extended` бага нет. |
| Repro | Speedtest, один телефон (Samsung SM-A736B, Android 16 / OneUI 8), одна сота МТС, разница только в `detour`: **без** — 0,44↓ / 19,4↑ / ping 140; **с** `detour: direct` — 150↓ / 53,3↑ / ping 144. Конфиги — в приложении к таске (ниже). |
| Related | [§128](128-force-direct-out-detour.md) (detour на пустой direct запрещён ядром — **другой** кейс), [§111](111-subscription-detour-without-native-chain.md), [§124](124-perapp-self-protect-allowbypass.md) (protect на сокете), память `project_wg_endpoint_detour_speed` (**содержит опровергнутую гипотезу — см. ниже**) |
| Core repo | `/Users/macbook/projects/sing-box-lx` (фикс — на стороне ядра, не клиента) |

---

## TL;DR

> No-detour WG-endpoint на Android поднимает UDP-сокет к peer через **`StdNetBind`**
> (высокопроизводительный путь wireguard-go с **GSO/GRO** offload). С `detour: direct`
> тот же UDP идёт через **`ClientBind`**, у которого GSO/GRO **нет**. Привязка к
> активному интерфейсу (то, на что грешили раньше) у обоих путей на Android
> **идентична** — значит дело не в выборе интерфейса. Текущий главный подозреваемый —
> **UDP-offload (GSO/GRO) в `StdNetBind`**, который на части LTE-сетей/железа бьёт
> приёмный поток (асимметрия: download убит, upload жив). **Не подтверждено на
> устройстве. Фикс не делается до измерения.**

Эта таска — журнал расследования, чтобы не пройти по уже отвергнутым следам в третий
раз. Две гипотезы ниже **опровергнуты по коду** — они зафиксированы намеренно.

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

## Опровергнутые гипотезы (по коду — не повторять)

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

### ❌ Под-гипотеза — «сокет застрял на старом интерфейсе после хэндовера»

Опровергнута: `onPauseUpdated` (`transport/wireguard/endpoint.go:316`) на
`EventNetworkPause/Wake` зовёт `device.Down()/Up()` → `BindUpdate()`
(`wireguard-go device.go:478`) **закрывает и переоткрывает** UDP-сокет и сбрасывает
кэш source-адресов (`markEndpointSrcForClearing`). Re-bind при смене сети **есть** и
общий для обоих путей.

---

## Текущий главный подозреваемый — UDP-offload (GSO/GRO) в StdNetBind

Установлено по коду (`conn/bind_std.go:209,220`):

```go
s.ipv4TxOffload, s.ipv4RxOffload = supportsUDPOffload(v4conn)   // runtime-детект на сокете
...
fns = append(fns, s.makeReceiveIPv4(v4pc, v4conn, s.ipv4RxOffload))
```

- `StdNetBind` при `Open()` **рантайм-детектит** поддержку UDP GSO (TX) / GRO (RX) на
  самом сокете и включает offload. Детект работает и на Android (Linux-ядро).
- `ClientBind` (detour-путь, `transport/wireguard/client_bind.go`) — простой
  `ListenPacket` / `wireConn`, **GSO/GRO-кода нет вообще**: пакет-в-пакет.

Почему это лучший кандидат:

1. **Объясняет асимметрию.** GRO/GSO собирает/разбирает крупные UDP-«суперпакеты» на
   приёме. Если LTE-сеть или железо дропают/портят offload-сегменты на приём — рушится
   именно **download**, а upload (другой offload-путь и часто меньше трафика) выживает.
   Ровно картина Ивана.
2. **Объясняет «MTU не помог».** Offload — про сегментацию на уровне сокета (UDP_GRO /
   UDP_SEGMENT), а не про MTU WG-туннеля. Понижение MTU туннеля offload не отключает.
3. **Объясняет, почему detour лечит.** `ClientBind` без offload = пакет-в-пакет =
   проблемный путь обходится.
4. **Объясняет форк `shtorm-7`** — вероятно собран с другим conn/offload-поведением
   (требует проверки, не факт).

Это **гипотеза**, не доказанный корень. Код сказал максимум; дальше — измерение.

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

Решающий, дешёвый эксперимент — различает кандидат №1 за один замер:

1. Собрать ядро с **принудительным отключением UDP-offload** в `StdNetBind`
   (форсить `ipv4TxOffload/RxOffload = false` и v6, либо короткий gate по
   `runtime.GOOS == "android"`).
2. Дать Ивану тот же **no-detour** конфиг (приложение ниже).
3. Замер Speedtest на той же LTE-соте:
   - download починился без `detour` → **корень = GSO/GRO**, фикс = отключать offload
     для WG-endpoint на Android (или гейтить);
   - не починился → переходим к DF/UDPFragment-кандидату.

NB: эксперимент через прод-релиз **не выкатывать**. Память
`feedback_releases_only_ci_built` — артефакт CI; для девайс-теста — отдельная сборка,
не подмена.

---

## Решение

Пока **нет**. Это таска-расследование. Любой код в ядре `sing-box-lx` — только после
того, как замер на устройстве Ивана подтвердит конкретный кандидат. Не объявлять
публично «решением» до репро (ровно как с MTU-гипотезой, которую юзер опроверг).

## Acceptance (для будущего фикса, когда корень подтверждён)

- [ ] No-detour WG-endpoint на LTE даёт download, сопоставимый с `detour: direct`,
      на устройстве Ивана (или эквивалентном LTE-репро).
- [ ] Фикс не ломает multi-peer / Wi-Fi / производительность на стабильной сети
      (StdNetBind-offload вводился апстримом ради throughput — отключать аккуратно,
      желательно гейтом, а не глобально).
- [ ] Регресс-проверка plain WG **и** AmneziaWG endpoint'ов.

## Приложение — конфиги репро (от Ивана, ключи — тестового юзера на его VPS)

**Нерабочий (без detour):** endpoint `WG` без `detour`, `final: WG`, tun mtu 9000,
wg mtu 1392, direct-outbound с `connect_timeout: 5s`.

**Рабочий (с detour):** тот же + `"detour": "direct"` в объекте endpoint'а.

(Полные JSON — в переписке 4PDA/ТГ от 2026-06-15; `connect_timeout: 5s` на direct
делает его непустым, поэтому запрет §128 не срабатывает — но к корню §150 это
отношения не имеет, см. «Развилка путей».)

## Источники (всё проверено по живому коду 2026-06-20)

- `transport/wireguard/endpoint.go:200-215` — развилка StdNetBind vs ClientBind.
- `common/dialer/wireguard.go` — `WireGuardListener`; реализует только `DefaultDialer`.
- `common/dialer/default.go:97-119, 374` — Control-функция, `WireGuardControl()`.
- `route/network.go:340, 368` — `ProtectFunc == AutoDetectInterfaceFunc` на Android.
- `conn/bind_std.go:139, 209, 220` (wireguard-go) — externalControl + `supportsUDPOffload`.
- `transport/wireguard/client_bind.go:89` — detour-путь, без offload.
- `wireguard-go device.go:316/478` ← `transport/wireguard/endpoint.go:316`
  `onPauseUpdated` → `BindUpdate` (re-bind при смене сети).
