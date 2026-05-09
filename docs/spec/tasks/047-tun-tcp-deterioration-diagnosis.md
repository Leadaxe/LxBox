# 047 — Tun TCP deterioration: floating race condition

| Поле | Значение |
|------|----------|
| Статус | **Phase 1+2 fixes applied** локально (working tree, uncommitted) через §049 Phase B (LocalResolver port, fileDescriptor → AtomicReference, cleanupStaleResources убран, atomic close для onRevoke, status-flap при reload убран). **Pending:** commit §049 Phase B + on-device retest §047 (30+ min + 8h smoke). Phase 3 (reload Mutex) — TBD по результатам retest'а; в reference тоже не сериализован, спекулятивный. |
| Дата | 2026-05-09 (audit applied; §049 Phase B fixes landed in working tree) |
| Связанные spec'ы | [`048 Per-app trace attribution gaps`](./048-perapp-trace-attribution-gaps.md) — отдельная проблема (события теряются в UI диагностики, **done**); [`049 Sing-box wrapper deep audit`](./049-singbox-wrapper-deep-audit/spec.md) — full diff vs reference 1.13.11; **Phase A done**, **Phase B done in working tree**, on-device retest = это §047 acceptance |
| Затронутые файлы | `app/android/app/src/main/kotlin/com/leadaxe/lxbox/vpn/{BoxVpnService,LocalResolver,PlatformInterfaceWrapper,BoxApplication,Extensions}.kt` (все modified в working tree через §049 Phase B), потенциально template (`tun.mtu`, `tun.stack`) |

---

## TL;DR

После **многих часов** (наблюдалось ~8 часов uptime) активной работы VPN, TCP-traffic от приложений через tun **silently перестаёт работать**. DNS, ICMP, UDP, sing-box internal `/delay` API продолжают работать. Reload tun восстанавливает работу — **до следующей деградации через ~15-30 мин**, потом снова reload, и так далее. Каждый цикл становится короче.

Bug **плавающий, не воспроизводимый по шагам** — типичная race-condition signature с накоплением state.

## Симптомы (что юзер видит)

- Chrome / любой браузер: `ERR_CONNECTION_REFUSED` мгновенно при попытке открыть любой сайт
- Apps (Chrome, Telegram, банковские apps) перестают открывать новые соединения
- Cмежные functions работают: ICMP ping проходит, DNS частично резолвит
- После **Reload tun** через UI (или `POST /action/reload`) всё снова работает 15-30 мин

## Главный сигнал — `/delay` API works когда apps fail

Это **decisive observation**: sing-box internal HTTP client делает TCP через outbound dialer — успешно. Apps делают TCP через tun → sing-box → outbound — fail.

| Test | Path внутри sing-box | Результат при «сломанном» state |
|---|---|---|
| `Clash API /proxies/<tag>/delay` | sing-box internal HTTP → outbound | **200 OK 200-1300ms** ✅ |
| `adb shell nc -w 5 1.1.1.1 443` (через tun) | tun-fd → packet decode → routing → outbound | **exit=1 в ~100ms** ❌ |
| `ping -I tun1 8.8.8.8` (ICMP через tun) | tun-fd → icmp handler | **OK 26-28ms** ✅ |

**Same outbound dialer, разный code path внутри sing-box.** Если бы sing-box internals были broken — `/delay` тоже фейлил бы. **Не фейлит**.

→ **Bug — между tun-fd и outbound dialer**. Это **наша обвязка**, не sing-box internals.

## Размер кода — surface для bugs

| | LOC | Что |
|---|---|---|
| Reference `VPNService.kt` (sing-box-for-android, commit `3b3883e` для libbox 1.13.11) | **191** | Pure native VPN service |
| Наш `BoxVpnService.kt` | **747** | + наш cleanup, command-server recreate, Flutter EventChannel forward, boot receiver, recovery logic |

**3.9× больше surface для race conditions.**

## Race condition signature (подтверждено)

| Свойство | Эвиденс |
|---|---|
| Bug **не воспроизводимый по шагам** | Юзер confirmed (2026-05-09): «плавающий» |
| **Initial deterioration** — после многих часов uptime | Конкретный observed случай — ~8 часов работы |
| **После reload** работает ~15-30 мин до следующей деградации | Каждый последующий cycle короче (накопление) |
| Reload tun **временно** исправляет | Создаёт fresh fd-state, race timer перезапускается |
| Только **TCP** через tun сломан, остальное работает | Race в TCP-write-to-fd path, но не в DNS / ICMP / outbound dialer paths |
| **Накопление stuck sockets** во времени | 451 stuck (FIN-WAIT-1 / LAST-ACK / SYN-SENT), при только 2-10 ESTAB |

Все эти признаки совпадают с **classical race condition** (timing-зависимая, не deterministic).

## Suspects (ranked после §049 deep audit, 2026-05-09)

После полного side-by-side diff с reference `3b3883e` (libbox 1.13.11) выявлены три приоритетных кандидата на root cause. §049 Phase B залил fixes в working tree для #1 и #2 — **готовы к on-device retest'у**. #3 пока спекулятивный (в reference тоже без Mutex'а).

| # | Suspect | Status |
|---|---------|--------|
| #1 | `LocalResolver` circular DNS | ✅ **Fixed in working tree** (`LocalResolver.kt` 1:1 port из reference, §049 F26) |
| #2 | `fileDescriptor` lifecycle race | ✅ **Fixed in working tree** (AtomicReference + atomic close + cleanupStaleResources убран, §049 F2/F3/F4/F5) |
| #3 | `serviceReload` не сериализован vs `doStop` | ⏳ **Не fixed** — спекулятивный, в reference тоже без external Mutex'а; решение по результатам on-device retest'а |

---

### #1 Suspect — `LocalResolver` circular DNS dependency ✅ FIXED in working tree (§049 F26)

**Файлы:** `app/android/app/src/main/kotlin/com/leadaxe/lxbox/vpn/LocalResolver.kt`

Наш impl (18 строк) vs reference (137 строк):

| | Наш | Reference |
|---|---|---|
| `raw()` | `false` | `Build.VERSION.SDK_INT >= Q` (true на современных устройствах) |
| `lookup()` body | `InetAddress.getAllByName(domain)` — **системный resolver, без network binding** | `DnsResolver.getInstance().query(defaultNetwork, domain, ...)` — **жёстко привязан к underlying network (cellular/wifi)** |
| `exchange()` | `errorCode(1)` (не реализовано) | полный impl через `DnsResolver.rawQuery(defaultNetwork, message, ...)` |

**Проблема — circular dependency через TUN:**

```
sing-box rule evaluation
  → LocalResolver.lookup(domain)
    → InetAddress.getAllByName(domain)        // системный resolver
      → kernel routing берёт default route
        → default route указывает на TUN (we're VPN service)
          → packet попадает обратно в наш sing-box через tun-fd
            → sing-box пытается резолвить domain снова
              → может рекурсия / depending on rules
```

**Почему это объясняет §047 better than fileDescriptor race:**

- TCP постепенно деградирует, DNS pool выживает: sing-box's **own** DNS pool работает через outbound dialer — `LocalResolver` дёргается только из специфических rule-set evaluation paths (например, `domain_resolver` для `geoip` matches). Эти paths разрежены — они и накапливают stale state, не deterministic.
- `/delay` API работает: не зависит от LocalResolver (внутренний HTTP client идёт прямо через outbound).
- ICMP работает: не использует LocalResolver вообще.
- Reload помогает временно: каждый reload пересоздаёт DNS cache + клиренсит kernel routing entries — circular state reset до тех пор пока следующее rule evaluation снова не запустит цикл.
- "Каждый цикл короче": каждый прогон LocalResolver через TUN оставляет stale conntrack / kernel resolver state, накапливается.

**Reference's solution:** всегда binds к `DefaultNetworkMonitor.defaultNetwork` (cellular/wifi underlying interface) — **обходит** TUN. Это не optimisation, это **correctness fix**.

```kotlin
// reference LocalResolver.kt:65-66
override fun lookup(ctx: ExchangeContext, network: String, domain: String) {
    val defaultNetwork = DefaultNetworkMonitor.defaultNetwork ?: error("missing default interface")
    // ... DnsResolver.query(defaultNetwork, domain, ...)
}
```

**Применено в working tree (uncommitted):** наш `LocalResolver.kt` теперь 151 строка, портирован 1:1 из reference. `raw() = true` на API≥Q. `lookup()` через `DnsResolver.getInstance().query(defaultNetwork, ...)`. `exchange()` через `DnsResolver.rawQuery(defaultNetwork, message, ...)`. Pre-Q fallback — `defaultNetwork.getAllByName(domain)` (`Network.getAllByName` тоже binds к underlying network с API 21+). См. `§049 F26` в комментарии файла.

---

### #2 Suspect — `fileDescriptor` lifecycle race ✅ FIXED in working tree (§049 F2/F3/F4/F5) (был top-1 до audit)

```kotlin
// BoxVpnService.kt:140
@Volatile private var fileDescriptor: ParcelFileDescriptor? = null
```

`@Volatile` даёт **memory visibility**, но **НЕ атомарность для compound operations**. Манипулируем `fileDescriptor` из **5+ call-sites**:

1. `openTun()` — assign `fileDescriptor = pfd` (новый), called from sing-box internal thread
2. `cleanupStaleResources()` (`:331-343`) — `cs.closeService()` → `cs.close()` → `fd.close()` → `null`. **Order opposite to graceful stop.** На `Dispatchers.IO`. Reference нет аналога.
3. `doStop()` (`:445-456`) — `fd.close()` → `cs.closeService()` → `cs.close()`. На `Dispatchers.IO`. ✓ совпадает с reference order.
4. `onRevoke()` (`:301-309`) — **синхронно на main thread, без coroutine.** Reference: `runBlocking { withContext(Main) { service.onRevoke() } }` → `BoxService.stopService()` → диспатчится в `Dispatchers.IO`. У нас sync на main → ANR vector + race против `serviceScope` worker'ов.
5. `onDestroy()` (`:266-283`) — `serviceScope.cancel()` (non-blocking) → не дожидается завершения in-flight `doStop()` coroutine → может orphanить commandServer + fd.

**Race scenario A** — concurrent close после reopen:
1. `serviceReload` triggers reconfigure → openTun возвращает новый fd
2. Concurrent `doStop` coroutine на IO dispatcher закрывает **старый** ref что становится новым после reassignment
3. Read-modify-write `fd?.close(); fd = null` не атомарно — окно между read и close может содержать reassignment в другой thread

**Race scenario B** — ParcelFileDescriptor.close() vs sing-box dup'd fd:
Sing-box `openTun` возвращает `pfd.fd` (raw int). Sing-box dup'ит. Когда мы `pfd.close()` — kernel закрывает оригинал, dup ещё валиден какое-то время, потом тоже invalidated → silent EBADF на write.

**Reference single-writer convention:** все mutations `BoxService.fileDescriptor` приходят с одного `Dispatchers.IO` worker'а (`GlobalScope.launch(IO){}`). У нас — `serviceScope`+ main + sing-box callback thread. Минимум 3 thread context'а.

**Применено в working tree (uncommitted):**
- `fileDescriptor` теперь `AtomicReference<ParcelFileDescriptor?>` (комментарий: «§049 F2/F3 fix: AtomicReference вместо `@Volatile`»). Идиома `getAndSet(null)?.runCatching { close() }` гарантирует single-close по contract — race scenario A закрыт.
- `commandServer` тоже `AtomicReference<CommandServer?>` (§049 F2/F3).
- `cleanupStaleResources()` **полностью удалён** (§049 F3 fix, комментарий: «создавал 5-й race-mutation site для fileDescriptor → main suspect §047»). Из 5 mutation sites осталось 4 (open / doStop / onRevoke / onDestroy), все используют atomic helpers.
- `onRevoke` использует atomic close helper (§049 F5 fix) — больше не sync на main thread mutating shared state.
- Status-flap `Started → Starting → Started` при reload убран (§049 F4 fix) — fewer Flutter-side rebuilds, fewer competing code-paths за `fileDescriptor`.

Race scenario B (PFD close vs sing-box dup'd fd) в reference тоже не решено — это intrinsic libbox contract; sing-box `dup`'ит и держит свой ref, наш `pfd.close()` всегда после того как sing-box перестаёт писать.

---

### #3 Suspect — `serviceReload` не сериализован vs `doStop` ⏳ NOT fixed (спекулятивный)

`BoxVpnService.serviceReload()` (`:588-608`) — синхронный broadcast-receiver callback на **main looper**. Запускает `cs.startOrReloadService(content, OverrideOptions())` blocking call в Go-runtime. Это окей, broadcasts queue serialized.

**Но:** `serviceReload` НЕ ждёт ничего и НЕ блокирует параллельный `doStop()` coroutine на `Dispatchers.IO`. Возможен interleave:

```
T1 (main):  serviceReload → cs.startOrReloadService(...)
                            → calls openTun callback (sing-box internal)
                            → fileDescriptor = newPfd  ← writes
T2 (IO):    doStop coroutine running
            → fileDescriptor?.close()  ← reads stale, closes new fd
            → fileDescriptor = null
```

**Reference** дополнительно: `runBlocking { serviceReload0() }` создаёт coroutine boundary. У нас raw call — нет даже этого weak boundary.

Каждый interleave может leak'нуть один fd / commandServer ref. Это идеально матчит pattern §047 "каждый цикл reload помогает на меньший интервал".

**Caveat:** в reference (`bg/BoxService.kt:192-249 serviceReload0`) тоже **нет внешнего Mutex**'а вокруг `serviceReload` vs `serviceStop`. Thread-safety `cs.startOrReloadService(...)` — внутренняя ответственность libbox CommandServer. После §049 F2/F3 fix'а наши shared fields (`fileDescriptor`, `commandServer`) — atomic, поэтому single-close contract держится **независимо от** внешней сериализации reload vs doStop. Так что Phase 3 — **conditional**: применять только если on-device retest после §049 Phase B всё ещё показывает deterioration.

---

### Это объясняет ВСЕ симптомы (для всех трёх кандидатов комбинировано)

- TCP via tun fails silently — write to invalidated/stale fd state (#1 indirect через kernel state, #2 direct EBADF)
- DNS/UDP/ICMP work — separate code paths не используют LocalResolver (#1) и не зависят от tun-fd write health (#2/#3)
- `/delay` API works — internal HTTP client прямо через outbound, минует и LocalResolver, и tun-fd
- Reload помогает временно — пересоздаёт state across all 3 layers
- Каждый цикл короче — kernel state накапливается (#1), fd refcount корраптится (#2), commandServer leak'ится (#3)

## Возможные триггеры race (наши custom additions, нет у reference)

1. **Network change events** (wifi ↔ cellular) → IfaceMonitor callback — может close+open fd race
2. **VpnPermission revoke / grant** → triggers `onRevoke` cleanup на main thread синхронно
3. **App lifecycle** (background/foreground) — recovery logic может trigger close
4. **Boot receiver activations**
5. **Subscription auto-update** completion → config rebuild → reload broadcast
6. **Flutter EventChannel** thread context — sing-box callbacks через MethodChannel
7. **`commandServer.pause/wake`** на screen on/off (`:172`) — синхронный call в Go из broadcast-receiver thread; reference тоже делает, но через `Settings.dynamicNotification` flag которого у нас нет, мы pause безусловно в `BG_MODE_ALWAYS`
8. **Re-entry в `commandServer` из `sendNotification`** (`:685-746`) — синхронный `commandServer?.writeMessage(0, ...)` из sing-box callback thread, может deadlock'нуть под load (reference диспатчит в `Dispatchers.Main`)

## Что **уже исключено** как root cause

| Гипотеза | Почему опровергнута |
|---|---|
| Chrome cache (bad-proxy / DNS) | После Chrome force-stop симптомы те же |
| Chrome Secure DNS (DoH) | Disabled в Chrome — не помогло |
| VLESS-Венгрия specific issue | Switch на Францию / wg-parnas / direct-out — те же симптомы |
| Cellular RKN block 2ip.io / mirage.ru | Известная данность, не наша; yandex.ru **тоже** не открывается при том что cellular его пропускает |
| `protect()` ignored (initial hypothesis) | Reference impl делает identically |
| Sing-box internal bug | `/delay` API работает через outbound — internals OK |
| Per-app trace tab пустой | Это **отдельная** §044 attribution issue (см. [§048](./048-perapp-trace-attribution-gaps.md)) |
| MTU 1492 fragmentation | Не объясняет non-determinism (fragmentation deterministic) |

---

## 📋 Detailed evidence (полная диагностика 2026-05-09)

> Сохранено для будущих агентов / forensics. Если bug повторится — сравнивать с этими данными.

### Версии

```
sing-box / libbox: 1.13.11 (com.github.singbox-android:libbox:1.13.11, JitPack)
LxBox app: 1.7.0
sing-box-for-android reference commit: 3b3883e (Bump version 1.13.11)
Device: тестовый телефон 192.168.1.71 (MTK chipset, ОЕМ Android)
```

### Tun config (decoded TunOptions API libbox 1.13.11)

```jsonc
// app/assets/wizard_template.json — defaults
{
  "type": "tun",
  "tag": "tun-in",
  "interface_name": "lxbox",
  "address": "172.16.0.1/30",
  "mtu": 1492,                    // <-- может вызывать fragmentation, suspect H2
  "auto_route": true,
  "strict_route": false,
  "stack": "system"               // kernel stack, not gvisor
}
```

`TunOptions` API в libbox 1.13.11 (decoded из AAR via `javap`):

```java
public interface TunOptions {
    // returns SINGLE address (StringBox.value), не Iterator (это в 1.14+)
    public abstract StringBox getDNSServerAddress() throws Exception;
    // NO getDnsMode() в этой версии (появился в 1.14-alpha)
    public abstract boolean getAutoRoute();
    public abstract RoutePrefixIterator getInet4Address();
    public abstract RoutePrefixIterator getInet4RouteAddress();
    // ...
    public abstract int getMTU();
    public abstract boolean getStrictRoute();
    // ...
}
```

### Timeline воспроизведения (2026-05-09 utc)

```
08:30:59 — 08:31:42  DNS exchange failed loop (16+ events) для 2ip.io, static.2ip.io
                     timeouts 10-20s через UDP DNS path
08:38:08             [vpn] reload → ok=true (ручной reload юзером)
08:38:09             tunnel state: connecting → connected
08:43:38 — 08:55     DNS pipeline OK. Chrome успешно резолвит 2ip.io → 188.40.167.81
                     gcp.gvt2.com, googleapis — все resolved
~08:55-09:03         Снова deterioration без явного триггера
09:03:55             dns: exchange failed for googleads.g.doubleclick.net IN A (10s)
09:03:56             dns: exchange failed for beacons4.gvt2.com IN HTTPS (10s)
09:04                Юзер: «Chrome не открывает 2ip.io» — ERR_CONNECTION_REFUSED
09:05                Disable Chrome Secure DNS — не помогло
09:05-09:08          Switch vpn-1 selector: Венгрия → Франция → wg-parnas → direct-out
                     все варианты — те же симптомы
09:10                TCP probe тестирование через nc
09:11                Подтверждено: 451 stuck sockets, 2 ESTAB
```

### Конкретные core_logs entries (DNS fail loop)

```
ERROR[16646] [945640198 10.0s] dns: exchange failed for 2ip.io. IN A: context deadline exceeded
ERROR[16646] [472318233 10.0s] dns: exchange failed for 2ip.io. IN HTTPS: context deadline exceeded
ERROR[16646] [1309561079 10.0s] dns: exchange failed for static.2ip.io. IN HTTPS: context deadline exceeded
ERROR[16646] [1769866498 10.0s] dns: exchange failed for static.2ip.io. IN A: context deadline exceeded
ERROR[16656] [1197295195 19.72s] dns: exchange failed for 2ip.io. IN A: context deadline exceeded
ERROR[16656] [787379357 19.72s] dns: exchange failed for 2ip.io. IN HTTPS: context deadline exceeded
... (16 events за 1 секунду — Chrome retry loop)
```

Conn-id'ы (945640198, 472318233 etc) **не упомянуты** больше нигде в логах — нет `inbound packet connection`, нет `router: found package name`. Sing-box просто эмитит error.

### TCP socket states (peak deterioration)

```
$ adb shell ss -tn 2>&1 | awk 'NR>1 {print $1}' | sort | uniq -c | sort -rn
 229 LAST-ACK
 184 FIN-WAIT-1
  38 SYN-SENT
   7 CLOSING
  10 ESTAB         # <-- только 10 живых при 451 stuck!
```

### SYN-SENT destinations (с timer info, `ss -tno`)

```
SYN-SENT  172.16.0.1:34252    64.233.164.95:443      timer:(on,35sec,6)
SYN-SENT  172.16.0.1:36608    64.233.162.95:443      timer:(on,1min,6)
SYN-SENT  172.16.0.1:42546    216.239.34.223:443     timer:(on,46sec,6)
SYN-SENT  172.16.0.1:50102    172.253.152.95:443     timer:(on,40sec,6)
SYN-SENT  172.16.0.1:42492    64.233.162.95:443      timer:(on,40sec,6)
SYN-SENT  172.16.0.1:37714    216.239.32.223:443     timer:(on,21sec,6)
SYN-SENT  172.16.0.1:36624    64.233.162.95:443      timer:(on,1min,6)
SYN-SENT  172.16.0.1:41358    173.194.221.95:443     timer:(on,35sec,6)
SYN-SENT  172.16.0.1:53050    142.251.1.95:443       timer:(on,27sec,6)
SYN-SENT  172.16.0.1:41406    157.240.205.142:443    timer:(on,,6)
SYN-SENT  172.16.0.1:41236    173.194.222.95:443     timer:(on,47sec,6)
SYN-SENT  172.16.0.1:53214    172.253.130.95:443     timer:(on,38sec,6)
SYN-SENT  172.16.0.1:46048    31.13.72.53:443        timer:(on,12sec,5)
SYN-SENT  172.16.0.1:38554    108.156.24.193:80      timer:(on,13sec,5)
```

Destinations: Google IPs (216.239.x, 64.233.x, 173.194.x, 172.253.x, 142.251.x — Google services / DoH endpoints), Facebook/Meta (157.240.205, 31.13.72), Amazon CloudFront (108.156.24), Apple (192.12.31). Все retry counter `5-6` (предельный SYN-retry counter Linux/Android).

### Cross-reproduction результаты (через все outbound)

```
URL test ru-upstream → https://ya.ru/      → 200 OK 251ms     ✅
URL test direct-out → https://ya.ru/       → 200 OK 1112ms    ✅
URL test direct-out → https://yandex.ru/   → 200 OK 1174ms    ✅
URL test direct-out → https://2ip.io/      → 504 Timeout 10s  ❌  (cellular RKN block — known)
URL test vpn-1 (Венгрия) → 2ip.io          → 200 OK 606ms     ✅
URL test vpn-2 (ru-upstream) → 2ip.io      → 200 OK 432ms     ✅
URL test через ВСЕ outbound → mirage.ru    → 200 OK или Timeout (зависит от сети)

# Но при этом app traffic через tun ↓
$ adb shell nc -w 5 1.1.1.1 443       → exit=1 в 111ms
$ adb shell nc -w 5 77.88.55.242 443  → exit=1 в 106ms (yandex)
$ adb shell nc -w 5 64.233.165.95 443 → exit=1 в 96ms (Google)
```

### ICMP works через все интерфейсы

```
$ adb shell ping -I tun1 8.8.8.8     → 26-28ms ✅
$ adb shell ping -I ccmni1 8.8.8.8   → 49-174ms ✅ (cellular)
$ adb shell ping -I wlan0 8.8.8.8    → 14ms ✅ (wifi)
```

### Routing works нормально

```
$ adb shell ip route get 188.40.167.81
188.40.167.81 dev tun1 table 1508 src 172.16.0.1 uid 2000

$ adb shell ip route get 77.88.55.88
77.88.55.88 dev tun1 table 1508 src 172.16.0.1 uid 2000
```

Оба IPs идут через `tun1` — kernel routing OK. **Packet попадает в tun-fd** (что верифицировано через `inbound packet connection` события для других conn'ов в тот же период).

### Selectors состояние (выбранные outbound)

```
vpn-1 active: ⚙ wg-parnas (после переключений; пробовали Венгрия/Франция/direct-out — то же)
vpn-2 active: ⚙ wg-parnas
✨auto active: 🇫🇮Финляндия (URLTest pick)
```

При **любом** active node deterioration воспроизводится — это **не специфично к node**.

### Reload tun recovery

```
08:38:08 [vpn] reload → ok=true              # <-- юзер нажал reload в UI
08:38:09 _handleStatusEvent: tunnel=connecting prev=connected
08:38:09 _handleStatusEvent: tunnel=connected prev=connecting
                                              # <-- через 1 секунду tunnel back up
08:38:09 — 08:55:00 (примерно 17 минут):
   DNS успешен для всех доменов (2ip.io, googleapis, gcp.gvt2.com)
   Chrome открывает страницы без ERR_CONNECTION_REFUSED
   Apps работают normally
08:55:00 — снова deterioration без явного triggering event'а
```

### Что юзер пробовал (всё не помогло)

1. **Chrome force-stop + restart** — симптомы те же
2. **Chrome Secure DNS off** — не помогло
3. **vpn-1 selector переключения** (Венгрия → Франция → wg-parnas → direct-out) — то же
4. **vpn-2 selector** (ru-upstream → wg-parnas → direct-out) — то же
5. Одно что **точно** помогло — **Reload tun** через UI

### Как собрать аналогичный snapshot при следующем сбое

```bash
./scripts/lxbox-diag.sh
```

Собирает ~23 файла за 2-3 секунды: `state.json`, `storage.json`, `config.json`, `core/app logs` (полные), `clash_{connections,proxies,rules}.json`, `ss -tn` (full TCP states), `ip route show table all`, `ip rule`, `ip -4 addr`, `getprop`, `adb logcat -d -t 500`. Полный playbook — в `docs/DIAGNOSTICS.md`.

Сравнение с reference impl (clone reference repo at correct version):

```bash
git clone https://github.com/SagerNet/sing-box-for-android
cd sing-box-for-android
git checkout 3b3883e   # libbox 1.13.11 reference
```

Ключевые файлы для diff:
- `app/src/main/java/io/nekohasekai/sfa/bg/VPNService.kt` (vs наш `BoxVpnService.kt`)
- `app/src/main/java/io/nekohasekai/sfa/bg/BoxService.kt` (наш unique — нет аналога, у нас всё в `BoxVpnService.kt`)
- `app/src/main/java/io/nekohasekai/sfa/bg/PlatformInterfaceWrapper.kt` (vs наш одноимённый)

---

## Action plan — current state

§049 Phase B уже залил **Phase 1 (LocalResolver) + Phase 2 (fileDescriptor sync) + большую часть Phase 4 (parity)** в working tree. Phase 3 — conditional, применять только если on-device retest показывает остаточный deterioration. Полный list applied fixes — в [`§049 spec.md`](./049-singbox-wrapper-deep-audit/spec.md) Phase B section.

### Что уже сделано (working tree, uncommitted)

| Fix ID | Что | Где | Закрывает |
|---|---|---|---|
| §049 F2 | `AtomicReference<ParcelFileDescriptor?>` + `closeFileDescriptor()` atomic CAS | `BoxVpnService.kt` | Phase 2 (fd sync) |
| §049 F3 | Удалён `cleanupStaleResources()` + `delay(500)` (5-е mutation site) | `BoxVpnService.kt` | Phase 2 (#2 suspect) |
| §049 F4 | `serviceReload()` без status-flap (Started→Starting→Started → identity) | `BoxVpnService.kt` | Phase 2 |
| §049 F5 | `onRevoke()` через atomic helpers вместо inline mutation | `BoxVpnService.kt` | Phase 2 (#2 suspect) |
| §049 F9 | `Libbox.setLocale(Locale.getDefault())` в bootstrap | `BoxApplication.kt` | Phase 4 (parity) |
| §049 F12.1 | `ConnectionOwner.userName = packages.firstOrNull()` | `PlatformInterfaceWrapper.kt` | Phase 4 (parity) — потенциальный impact на §048 attribution accuracy |
| §049 F12.3 | Полный `readWIFIState()` через `wifiManager.connectionInfo` | `PlatformInterfaceWrapper.kt` + `BoxApplication.kt` | Phase 4 (parity) |
| §049 F17 | `getSystemProxyStatus()` возвращает реальный state | `BoxVpnService.kt` | Phase 4 |
| §049 F22 | Bounded queue для core logs + single-pending drainer (main looper relief) | `BoxVpnService.kt` | Phase 4 (cosmetic для главного bug, но снижает noise) |
| §049 F26 | `LocalResolver`: full `DnsResolver.getInstance().query(defaultNetwork, ...)` (мимо TUN) | `LocalResolver.kt` + `Extensions.kt` | Phase 1 (#1 suspect) |

§049 Phase C прогнал `flutter analyze` (clean) и `flutter test` (518/519; 1 fail был §048 territory, **починен в моём §048 implementation 2026-05-09 — теперь 535/535**) + local APK build (32.3 MB, ok).

### Что ещё надо сделать — порядок

1. **Commit §049 Phase B** — все 5 modified Kotlin файлов в working tree сейчас uncommitted. Без коммита on-device retest не делает смысла (CI/release pipeline качает HEAD).
2. **Local APK install + on-device retest** — 30+ min smoke + ideally 8h+ run для подтверждения что deterioration ушёл. Используем `./scripts/lxbox-diag.sh` для baseline и сравнения.
3. **Если deterioration ушёл** → §047 close (root cause = #1 LocalResolver и/или #2 fileDescriptor race, оба теперь невозможны).
4. **Если deterioration остался** → переходим к Phase 3 (`serviceReload` Mutex) или дальнейший audit (потенциальные suspects вне §049 scope: tun.mtu fragmentation, sing-box internal QUIC stack issues, kernel conntrack table overflow).

### Phase 3 — conditional (только если retest всё ещё показывает deterioration)

1. `private val reloadLock = Mutex()` в `BoxVpnService`
2. `serviceReload` body → `serviceScope.launch { reloadLock.withLock { ... } }`
3. `doStop` тоже под этим же lock'ом

**Caveat:** reference (`bg/BoxService.kt`) тоже **не использует** external Mutex. Thread-safety `cs.startOrReloadService(...)` — внутренняя ответственность libbox CommandServer. Phase 3 = «defensive layer» поверх атомарных полей. Не делаем превентивно.

### Phase 4 leftovers (parity, не §047 critical) — отложено за пределы §049

- `Settings.allowBypass` toggle (требует UI, см. `§049 F15`)
- Split monolith `BoxVpnService.kt` 805 LOC → отдельный Lifecycle class (~700 LOC refactor, риск регресса; AtomicReference уже решает race, см. `§049 F1`)
- Increase `stopAwait` timeout 5s → 15s (`VpnPlugin.stopVpn`)

### Detailed logging — already in code

`BoxVpnService.kt` уже логирует `[vpn] doStop ENTER status=...`, `[vpn] receiver: ACTION_RELOAD`, etc. — есть signal для post-retest forensics если deterioration вернётся.

### Verification

- ✅ `flutter analyze` clean (§049 Phase C)
- ✅ `flutter test` 535/535 (после §048 done)
- ✅ Local APK build 32.3 MB (§049 Phase C)
- ⏳ **Pending:** commit §049 Phase B → install APK на тестовый телефон → 30+ min smoke → 8h+ long-run

## Acceptance criteria

- [x] §049 deep audit done (Phase A — 25 findings)
- [x] **Phase 1 fix:** `LocalResolver` ported from reference (§049 F26)
- [x] **Phase 2 fix:** `fileDescriptor` race устранён через AtomicReference + cleanupStaleResources убран (§049 F2/F3/F4/F5)
- [x] Phase 4 parity fixes applied (§049 F9/F12.1/F12.3/F17/F22)
- [x] `flutter analyze` clean + 535/535 tests pass + APK build success (§049 Phase C)
- [ ] **Commit §049 Phase B** в develop (5 modified Kotlin files в working tree)
- [ ] 30+ min on-device smoke test после install commit'нутого APK — deterioration не воспроизводится
- [ ] 8h+ long-run on-device — deterioration не воспроизводится; если был — собрать `./scripts/lxbox-diag.sh` snapshot для forensics
- [ ] Если §047 повторяется после Phase B retest → Phase 3 (reload Mutex) → ещё один retest
- [ ] Если §047 повторяется после Phase 3 → suspects elsewhere (Open question 1), продолжать audit
- [ ] Documentation в `BoxVpnService.kt` — comments объясняющие thread safety contract (✅ уже добавлены через §049 F2/F3/F4/F5 inline comments)

## Open questions

1. **Что именно триггерит race в production?** — Network change? Subscription update? Flutter UI action? Узнаем через detailed logging.
2. **Можем ли мы force-репродуцировать race?** — Например, через Debug API trigger concurrent reload + revoke broadcasts.
3. **Стоит ли разделить `BoxVpnService.kt` на core (≈ reference 191 LOC) + Flutter layer (~500 LOC)?** — Reference architecture: `VPNService` (191 LOC, thin) + `BoxService` (424 LOC, runtime owner). Может уменьшить surface significantly.
4. **`LocalResolver.exchange()` ёмкость:** наш stub возвращает `errorCode(1)` — sing-box silently downgrade'ится на другой DNS path? Или это создаёт error feedback loop в DNS pool?
5. **`commandServer.pause/wake` cycles** на screen on/off — могут ли они быть отдельным trigger'ом? Reference gates через `Settings.dynamicNotification`, мы pause безусловно.
