# §180 → ФИДБЭК ЯДРУ: `SubscribeDNSQueries` отдаёт `Unimplemented` в rc.7

**Кому:** команда sing-box-lx (SPEC 018)
**От:** LxBox-клиент, §180
**Дата:** 2026-06-26, ядро `v1.14.0-lx.1-rc.7`, устройство dev.71 (OnePlus CPH2411, Android 15)

## Симптом

Клиентская реализация SPEC 018 готова и подписывается корректно, но **ядро rc.7
на устройстве возвращает**:

```
W BoxCommandClient: DnsQuery stream error: dns query stream recv:
   rpc error: code = Unimplemented desc = DNS query tracking not available
```

→ в профайлер LxBox не приходит НИ ОДНОГО DNS-события (0 из 0), хотя ядро DNS
**резолвит** (core-log полон `dns: exchanged A/CNAME …`).

## Что подтверждено со стороны клиента (НЕ баг клиента)

1. **Биндинг присутствует** — `javap` по `libbox-1.14.0-lx.1-rc.7.aar`:
   - `Connection`-соседи: `DnsQuery`, `DnsAnswer`, `DnsAnswerIterator`,
     `DnsQueryHandler{onQuery, onError}`, `DnsQuerySubscription{close()}`.
   - `CommandClient.subscribeDNSQueries(boolean includeAnswers, DnsQueryHandler)
     → DnsQuerySubscription`.
   - `DnsQuery` геттеры: `getDomain/getQueryType/getRcode/getTTL/getSource/
     getFailed/getError/getProcessInfo`, `answers()`.
2. **Вызов проходит штатно** (logcat dev.71):
   ```
   D BoxCommandClient: connected gen=2
   W BoxCommandClient: DnsQuery stream error: … Unimplemented … DNS query tracking not available
   ```
   То есть `subscribeDNSQueries(true, handler)` вызван на ЖИВОМ profilerClient,
   сервер принял и сразу вернул `codes.Unimplemented`.
3. **`with_lx_command` в этом ядре ЕСТЬ** — на том же AAR/устройстве работают
   `SubscribeConnections`, `SubscribeGroups`, `Connection.chain()` (§174),
   `Connection.detour()` (§178, device-verified rc.6). Значит проблема НЕ в общем
   lx-command гейте, а в **отдельной активации DNS-tracking**.

## Гипотеза (по SPEC 018)

`codes.Unimplemented desc = "DNS query tracking not available"` — это явный
ранний-return на сервере, когда `dnstrack.Manager` НЕ зарегистрирован. По SPEC 018
точка 2: *«box.go — создать и зарегистрировать `dnstrack.Manager` (как
trafficManager), гейт `needObservable`»*. Похоже:
- либо `dnstrack.Manager` не создаётся в `box.go` для gomobile/libbox-сборки AAR,
- либо `needObservable`-гейт не включает DNS-наблюдаемость для платформенного
  клиента (включает только connections),
- либо фича за build-тегом, не попавшим в gomobile-сборку `experimental/libbox`
  с `with_xhttp,with_awg` (релиз-ноты rc.7 называют только эти два).

## Что просим

Сборку ядра, где `SubscribeDNSQueries` отдаёт поток (не `Unimplemented`):
зарегистрировать `dnstrack.Manager` в пути инициализации libbox/CommandServer,
проверить `needObservable`-гейт покрывает DNS. Критерий из самого SPEC 018:
*«Каждый успешный резолв эмитит `DnsQueryEvent` с domain + processInfo; провалы
тоже эмитят (failed/rcode/error)»*.

## Состояние клиента до фикса

§180 в коде ЗАВЕРШЁН и forward-compatible: `DnsHandler.onError` ловит
`Unimplemented` без краша, профайлер работает (TCP/UDP), текстовый DNS-парсинг
ВЫПИЛЕН (вариант A). Следствие: **DNS в Live пуст до активации ядра** — как только
ядро перестанет отдавать `Unimplemented`, DNS-события пойдут без правок клиента
(подписка уже на месте). Коммит клиента: `c867180`.
