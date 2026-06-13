# 122 — `missing default interface`: LocalResolver падает на null defaultNetwork

| Поле | Значение |
|------|----------|
| Статус | Won't-fix — диагностика завершена, фикс осознанно НЕ делаем (см. «Решение») |
| Дата старта | 2026-06-14 |
| Дата завершения | 2026-06-14 |
| Коммиты | — |
| Связанные | [§119](119-default-network-not-vpn.md) (откуда выделено), upstream PR [SagerNet/sing-box-for-android#61](https://github.com/SagerNet/sing-box-for-android/pull/61) |

## Проблема

`LocalResolver.exchange()`/`lookup()` читают `DefaultNetworkMonitor.defaultNetwork`
**напрямую** и на любом `null` кидают `error("missing default interface")`
([LocalResolver.kt:38,78](../../../app/android/app/src/main/kotlin/com/leadaxe/lxbox/vpn/LocalResolver.kt) +
pre-Q ветка ~118). Это мгновенный throw — DNS-обмен проваливается вместо ожидания
underlying-сети.

Замечание поднято при ревью §119 / upstream PR #61. **Это НЕ регрессия §119** (см.
ниже) и потому вынесено сюда, а не чинится в §119.

## Трассировка старта (по коду, без устройства)

Когда `defaultNetwork` может быть `null` к моменту первого DNS-запроса.

### Порядок в `BoxService.startSingbox()`

```
startSingbox():
  :241  DefaultNetworkMonitor.start(scope) {…}
          ├─ seed = activeNetwork?.takeUnless(::isVpn)   // §119, синхронно
          ├─ DefaultNetworkListener.start(this){…}        // actor.send(Msg.Start) — НЕ блокирует
          │    └─ actor (DefaultNetworkListener.kt:36): register() ставит NetworkCallback в ОС
          └─ return                                       // НЕ ждёт первого Msg.Put
  :246  Libbox.setMemoryLimit(true)
  :254  cs.startOrReloadService(config)                   // tun ↑, парс конфига, СТАРТ DNS
          └─ позже: sing-box → LocalResolver.exchange/lookup → читает defaultNetwork
```

`start()` **не блокирует** до первого callback'а (добор через `get()` у нас за
`SDK_INT < M`, а `minSdk = 26` → ветка мёртвая, [DefaultNetworkMonitor.kt:63](../../../app/android/app/src/main/kotlin/com/leadaxe/lxbox/vpn/DefaultNetworkMonitor.kt)).
Underlying приходит асинхронно: ОС → `onAvailable` → `runBlocking{ actor.send(Msg.Put) }`
→ `defaultNetwork = it`, на потоке ОС-колбэка, гонкой к нашему старт-потоку.

### Три источника `null` — и их вес

| Источник null | Частота | Чинит §119-seed-фильтр? | Чинит require()? |
|---|---|---|---|
| seed = underlying (норма) | почти всегда — **null не возникает** | — | — |
| **стартовая гонка**: seed=null/VPN И первый DNS обогнал callback | редко, узкое окно | n/a (это и есть «после фильтра null») | ✅ |
| **рантайм `onLost`**: `Msg.Lost → network=null` ([DefaultNetworkListener.kt:53](../../../app/android/app/src/main/kotlin/com/leadaxe/lxbox/vpn/DefaultNetworkListener.kt)) при потере сети | повторяется на каждой потере/смене сети | ❌ (одноразовый seed его не покрывает) | ✅ |

Между `:241` и первым DNS есть `setMemoryLimit` + `startOrReloadService` (парс +
поднятие tun, десятки-сотни мс). ОС обычно отдаёт `onAvailable` за единицы-десятки
мс → **callback обычно успевает**. Но гарантии нет (медленное/загруженное
устройство; reload с уже поднятым tun).

## §119 регрессию не вносит

- `takeUnless(::isVpn)` добавил **один** новый путь к null (VPN-seed на старте),
  почти всегда перекрываемый callback'ом до первого DNS.
- Чистый эффект §119: `гарантированный DNS-loop` → `редкий быстрый fail в узком
  окне` — **строго лучше**.
- Главный повторяющийся null — `onLost` — **старше §119**, существовал всегда,
  нашим фиксом не затронут. Это и есть настоящий предмет §122.

## Что делает `error()` (Go-контракт, проверено в исходнике)

Не краш. `LocalDNSTransport.exchange/lookup` в .aar объявлены `throws Exception`.
Go-обёртка `platformTransport.Exchange/Lookup`
([sing-box `experimental/libbox/dns.go`](https://github.com/SagerNet/sing-box/blob/testing/experimental/libbox/dns.go)):

```go
err = p.iif.Exchange(response, messageBytes)   // наш Kotlin exchange()
if err != nil { return err }                    // ← ошибка пробрасывается НАВЕРХ
...
err = group.Run(ctx)
if err != nil { return nil, err }               // failed exchange в DNS-движок
```

То есть `error()` = **failed exchange**, видимый DNS-движку. Что движок делает
выше (фейловер на другой DNS-сервер / SERVFAIL приложению) — зависит от DNS-правил
конфига. **В обёртке тихого ретрая/проглатывания нет** — нельзя утверждать, что
«sing-box просто ретраит и всё ок».

## Решение — won't-fix (осознанно НЕ чиним)

Вердикт: **оставляем `error("missing default interface")` как есть**, фикс
`require()` не делаем. Обоснование от диагностики выше:

- В норме `null` не возникает (seed = underlying).
- Стартовая гонка — узкое редкое окно; апстрим живёт с ней синхронным `error()`
  осознанно, не недосмотр.
- `onLost`-окно реально, но `error()` ≠ краш: это failed exchange, движок отрабатывает
  штатно (см. Go-контракт). На целевых устройствах симптома никто не наблюдал.
- `require()` тянет за собой `suspend`-перестановку в двух методах + новый
  `require()` + обязательный таймаут с onCancel (иначе hang залипает Go-поток).
  Цена > выгоды для не подтверждённого в проде окна. Это и есть оверинжиниринг,
  которого мы избегаем.

Если в будущем `missing default interface` начнёт стрелять в field-report'ах
(лог `LxBoxNet` уже безусловный, §119/TD-119-1) — вернуться к концепту ниже. До
тех пор — **не трогаем**.

### Концепт фикса (справка на случай возврата — НЕ реализуем сейчас)

`LocalResolver` вместо `defaultNetwork ?: error(...)` зовёт блокирующий
`DefaultNetworkMonitor.require()`, который ждёт первый NOT_VPN-callback вместо
мгновенного провала. Покрывает и стартовую гонку, и `onLost`.

- **`require()` у нас НЕТ** — добавить (в апстриме есть, мы не портировали).
  `require(): defaultNetwork ?: get()` — быстрый путь если поле непусто.
- **suspend-перестановка**: получение сети занести **внутрь** `runBlocking` в
  обоих методах + pre-Q ветка `lookup` (сейчас читается до `runBlocking`).
- **Поток безопасен**: `exchange/lookup` уже в `runBlocking` на Go-потоке (не main
  — иначе reference давал бы ANR на каждом DNS; reference в проде). Блокирующее
  ожидание добавляется на поток, который и так блокируется на сетевой round-trip.

### Развилка А — таймаут (РЕШЕНО: с таймаутом)

`get()` non-fallback = `Msg.Get().response.await()` ждёт `Msg.Put` **вечно**. Если
underlying-сети нет вообще (самолётный режим / сеть пропала надолго) — без таймаута
`get()` не вернётся → DNS-обмен **зависнет**, залипнет Go-поток, конечный пул
DNS-воркеров sing-box исчерпается → встанет весь DNS. Hang хуже быстрой ошибки.

→ Обернуть в `withTimeoutOrNull(T)` + реакцию на существующий `ctx.onCancel(signal)`
(что раньше — таймаут или отмена от sing-box). По истечении/null — сохранить
текущий отказ (`error(...)` / `ctx.errorCode`), не ронять поток необработанно.
`T` ≈ 1000–2000 мс (окно гонки — мс; таймаут только чтобы не ждать несуществующую
сеть). Точное значение — при реализации.

> **VPN-only ≠ наш detour.** Наш detour (§111) — outbound-цепочка в конфиге
> sing-box (нода→нода внутри ядра), идёт по обычной underlying-физике; `null`-seed
> он НЕ порождает. «Underlying нет вообще» у нас = только самолётный режим / отвал
> физики, как и у апстрима — нашей специфики, повышающей частоту hang, нет.

## Затронутые файлы (если фикс пойдёт)

- `vpn/DefaultNetworkMonitor.kt` — добавить `suspend fun require()`.
- `vpn/LocalResolver.kt` — `exchange`/`lookup` (+ pre-Q ветка): `require()` под
  `withTimeoutOrNull` + onCancel, внутри `runBlocking`; fallback на отказ.
- Зеркально — апстрим PR #61 (вторым коммитом), если решим отдавать наверх.
