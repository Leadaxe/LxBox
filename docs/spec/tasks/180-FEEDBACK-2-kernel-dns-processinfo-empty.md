# §180 → ФИДБЭК ЯДРУ #2: `DnsQuery.ProcessInfo` пуст — DNS не атрибутируется

**Кому:** команда sing-box-lx (SPEC 018, после rc.8-фикса service-registry)
**От:** LxBox-клиент, §180
**Дата:** 2026-06-26, ядро `v1.14.0-lx.1-rc.8`, устройство dev.72 (OnePlus CPH2411, Android 15)

> ✅ **ПРИНЯТО ЯДРОМ — фикс едет в rc.9.** Команда обновила SPEC 018 (раздел
> «Пункт 3 — ProcessInfo (ИСПРАВЛЕНО в rc.9)»). Корень подтверждён и углублён:
> DNS на TUN хайджекается на FAST-PATH (`route.go:91-94/226-228`), который
> `return` ДО `matchRule`; `searchProcessInfo` живёт ВНУТРИ `matchRule` → fast-path
> DNS (большинство на VPN, особенно UDP) эмитится с `ProcessInfo==nil`.
> Детерминированно (два code-path), не гонка. Важно: `found package name` в логе —
> часто от TCP-коннекта того же app, НЕ от DNS-запроса (вот почему я видел package,
> но DNS был unattributed). Фикс rc.9: `searchProcessInfo` ПЕРЕД fast-path hijack
> (идемпотентно+кэш). Клиент правок не требует — device-verify на rc.9.

## Контекст

rc.8 починил `Unimplemented` (service-registry key mismatch) — **DNS-стрим теперь
работает**, события идут (119 DNS за 60с на активном устройстве, cnameChain есть,
dnsFail структурны). Спасибо. Но всплыла **вторая проблема**: атрибуция к приложению.

## Симптом

**`DnsQuery.ProcessInfo` пуст у 119 из 119 событий** — все DNS приходят
`unattributed`, хотя на устройстве активны известные приложения (YouTube, Chrome,
GitHub-резолвы видны: `youtubei.googleapis.com`, `github.com`,
`avatars.githubusercontent.com` — все без process).

```
confidence-распределение: Counter({'unattributed': 119})
DNS с process: 0 / 119
```

## Доказательство, что это баг ядра (НЕ клиента)

1. **Клиент читает ProcessInfo правильно** — тем же кодом, что для connections
   (где атрибуция РАБОТАЕТ): `q.getProcessInfo()` → `processPath` +
   `packageNames().next()`. На `Connection` этот же паттерн даёт package; на
   `DnsQuery` — пусто.
2. **Router В ЭТОТ ЖЕ МОМЕНТ определяет package** — core-log параллельно с DNS:
   ```
   INFO router: found package name: com.android.chrome
   INFO router: found package name: com.google.android.youtube
   INFO router: found package name: com.teslamotors.tesla
   ```
   То есть атрибуция в ctx ядра ДОСТУПНА (router её резолвит для тех же доменов),
   но в `DnsQuery.ProcessInfo` не попадает.
3. **Непостоянство → тайминг.** В одном раннем замере 3/58 DNS имели process
   (`youtube`, `tesla`), при этом ДРУГИЕ запросы того же Tesla
   (`signaling.vn.teslamotors.com`) — unattributed. На холодном старте — 0/119.
   Похоже, `ProcessInfo` заполнен только когда router успел связать запрос с
   package ДО точки эмита DNS-события; большинство резолвов уходит раньше.

## Расхождение со SPEC 018

SPEC 018 «Согласованная форма» обещает `ProcessInfo *adapter.ConnectionOwner` в
каждом событии, и пункт 3 явно: *«ProcessInfo непуст на cached/optimistic путях…
Атрибуция cached-DNS корректна»* — на устройстве это НЕ так.

Точка эмита (`dns/client_log.go` / `Exchange` на путях провала) берёт
`adapter.ContextFrom(ctx).ProcessInfo`. Гипотеза: в момент DNS-эмита
`metadata.ProcessInfo` в ctx ещё nil — package определяется router'ом ПОЗЖЕ
(или в другом ctx), чем происходит резолв. SPEC 018 сам отмечал, что
`package_name_regex` в DNS-правилах матчит → package «известен к моменту резолва»,
но на практике в эмит-ctx его нет.

## Что просим проверить

- В точке `manager.Emit(DnsQueryEvent{... ProcessInfo})` — реально ли
  `adapter.ContextFrom(ctx).ProcessInfo` заполнен, или nil для большинства путей?
- Возможно, ProcessInfo надо брать после `FindProcessInfo`/router-фазы, а DNS
  hijack (`route/dns.go`) эмитит ДО неё → ctx ещё без owner.
- Критерий из SPEC 018 п.3: атрибуция должна работать на exchanged/cached, не
  только в редких случаях.

## Состояние клиента

§180 НЕ требует правок под это — `processInfo` читается корректно, как только
ядро начнёт его заполнять, атрибуция пойдёт без изменений клиента. Сейчас DNS в
Live работает (стрим + cnameChain + dnsFail), но почти весь unattributed.
Параллельно клиент пофиксил СВОЙ баг: ядро отдаёт `DnsAnswer.RData` полной
RR-строкой (`"google.com. 29 IN A 64.233.165.139"`), не голым значением — клиент
теперь извлекает последнее поле (это НЕ к ядру, просто FYI по формату RData).

Коммит клиента: см. §180 (rc.8-пин + rdata-фикс).
