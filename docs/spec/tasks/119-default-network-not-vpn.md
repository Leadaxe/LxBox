# 119 — default-network: seed из getActiveNetwork() мог быть нашим же VPN

| Поле | Значение |
|------|----------|
| Статус | Code-complete в develop (девайс-репро отсутствует — фикс по root-cause-анализу + non-regression smoke) |
| Дата старта | 2026-06-13 |
| Дата завершения | — |
| Коммиты | — |
| Связанные spec'ы | features/046 (tunnel apps split-tunneling), features/047 (DNS/network deterioration) |

## Источники истины (AOSP / Android docs)

Решения ниже опираются строго на эти первоисточники, не на догадки о прошивках:

- **`NetworkCapabilities.DEFAULT_CAPABILITIES`** — `NOT_VPN` входит в дефолт
  `NetworkRequest.Builder` (вместе с `TRUSTED` и `NOT_RESTRICTED`):
  [NetworkCapabilities.java (Connectivity module, master)](https://android.googlesource.com/platform/packages/modules/Connectivity/+/refs/heads/master/framework/src/android/net/NetworkCapabilities.java)
  — `static { defaultCapabilities = NOT_RESTRICTED | TRUSTED | NOT_VPN; … }`.
  Javadoc `NET_CAPABILITY_NOT_VPN`: *«This capability is set by default.»*
- **per-app default network может быть VPN** — `registerDefaultNetworkCallback()`
  (и тот же per-app default отдаёт `getActiveNetwork()`) описывает сеть
  приложения, которая *«may be a physical network or a virtual network, such as a
  VPN that applies to the application»*:
  [`ConnectivityManager.registerDefaultNetworkCallback()` — Android Developers](https://developer.android.com/reference/android/net/ConnectivityManager#registerDefaultNetworkCallback(android.net.ConnectivityManager.NetworkCallback)).
- **DNS-loop в Tun-режиме** — резолв через сам tun при `auto_route` рекурсивно
  заходит обратно в sing-box:
  [sing-box#3637](https://github.com/SagerNet/sing-box/issues/3637),
  [sing-box#2643](https://github.com/SagerNet/sing-box/issues/2643).

## Проблема (field report)

Field report (4PDA, Михаил, **MIUI Android 13**): при **Allow-list** (только
выбранные приложения через VPN) трафик allowed-приложений **не работает**, пока
в Allow-list не добавить **сам L×Box**. По §046 это должно быть no-op («наш
process сам не зависит от tun»), и на чистом Android / ColorOS (CPH2411)
**не воспроизводится** — allow-list работает без самодобавления.

> Почему репро на MIUI, но не на ColorOS/Pixel — **нам неизвестно** и в спеке не
> утверждается. Различие в тайминге/поведении между прошивками реально, но без
> устройства репортёра его причину мы не установили. Фикс ниже устраняет
> известный код-путь, на котором `defaultNetwork` мог стать нашим VPN,
> **независимо** от того, почему он срабатывал именно на той прошивке.

## Цепочка DNS allowed-приложения

1. `openTun` анонсирует на VpnService DNS-сервер
   ([BoxVpnService.kt:186](../../../app/android/app/src/main/kotlin/com/leadaxe/lxbox/vpn/BoxVpnService.kt)
   `builder.addDnsServer`) → DNS захваченных приложений идёт в TUN → sing-box DNS.
2. DNS Final по умолчанию = `local_dns_resolver` → `LocalResolver`.
3. `LocalResolver` резолвит через `DnsResolver.query(defaultNetwork, …)`
   ([LocalResolver.kt:38,78,118](../../../app/android/app/src/main/kotlin/com/leadaxe/lxbox/vpn/LocalResolver.kt)),
   где `defaultNetwork` **обязан** быть underlying-физикой (иначе DNS уходит
   обратно в tun → loop).
4. `defaultNetwork` берётся из `DefaultNetworkMonitor`. У него **два** источника,
   и ведут они себя по-разному (см. ниже).

## Root cause (по инспекции кода + AOSP)

`DefaultNetworkMonitor.defaultNetwork` пишется из двух источников:

| Источник | Где | Фильтрует ли VPN? |
|---|---|---|
| **seed** `getActiveNetwork()` | [DefaultNetworkMonitor.kt:start()](../../../app/android/app/src/main/kotlin/com/leadaxe/lxbox/vpn/DefaultNetworkMonitor.kt) | **НЕТ** — это прямой геттер, NOT_VPN из NetworkRequest к нему неприменим |
| **callback** из `DefaultNetworkListener` | [DefaultNetworkListener.kt:register()](../../../app/android/app/src/main/kotlin/com/leadaxe/lxbox/vpn/DefaultNetworkListener.kt) | **ДА** — `NetworkRequest` с `NOT_VPN` (он же дефолт), на API ≥ 28 (`requestNetwork` / `registerBestMatchingNetworkCallback`) |

**Баг — в seed, а не в request.** `getActiveNetwork()` возвращает per-app
default, который по документации Android **штатно включает наш собственный VPN**,
если tun уже поднят к моменту `start()`. Этот seed напрямую кладётся в
`defaultNetwork` и используется `LocalResolver`'ом до прихода первого callback'а.
Если seed = наш VPN → `DnsResolver.query(VPN)` → DNS уходит обратно в tun →
loop → allowed-приложения не резолвят имена → «не работает».

**Опровергнутая гипотеза (для истории):** ранняя версия §119 считала, что
`NetworkRequest` «не требовал `NOT_VPN`» и потому
`registerBestMatchingNetworkCallback` возвращал VPN. Это **неверно**: `NOT_VPN`
входит в `DEFAULT_CAPABILITIES` `NetworkRequest.Builder` (см. источники), то есть
callback-путь VPN не отдавал и до §119. `addCapability(NOT_VPN)` в request —
**no-op по поведению** (оставлен как self-documenting/страховка, не как фикс).

«Добавление себя» в allow-list лечит косвенно (меняет сетевой скоупинг процесса
так, что `getActiveNetwork()` начинает отдавать underlying) — это
**симптом-патч**, не причина.

## Решение

1. **Фильтр VPN на seed** — в `DefaultNetworkMonitor.start()`
   `activeNetwork?.takeUnless(::isVpn)`: init-`defaultNetwork` никогда не наш tun.
   Это и есть содержательный фикс §119 — закрывает реальный код-путь, на котором
   `LocalResolver` мог получить VPN.
2. **`addCapability(NET_CAPABILITY_NOT_VPN)`** в `DefaultNetworkListener` request
   — **поведенчески no-op** (NOT_VPN уже в дефолте Builder'а). Оставлен явно как
   self-documenting + страховка от случайного `removeCapability(NOT_VPN)`.
   Комментарий в коде это прямо фиксирует со ссылкой на AOSP.
3. **Постоянный диаг-лог** `LxBoxNet` в `DefaultNetworkMonitor.logDefaultNetwork`
   (`iface` + `vpn=true/false`). Репро у нас нет → следующий field-report
   диагностируется сразу: `adb logcat -s LxBoxNet`. Лог **безусловный**
   (`Log.i`, без debug-gating). Ожидаемые значения:
   - `[init]` — после фильтра всегда `vpn=false`; `true` означало бы обход
     фильтра — копать дальше.
   - `[update]` — из NOT_VPN-request, штатно `vpn=false`; `true` — аномалия
     (underlying не сматчился вопреки NOT_VPN).

**НЕ делаем self-add** (отклонено): он гоняет служебный трафик L×Box через VPN и
делает §046-заметку «adding L×Box has no effect» ложью.

## Затронутые файлы

- `vpn/DefaultNetworkMonitor.kt` — фильтр `takeUnless(::isVpn)` на init-seed;
  helper `isVpn`; `logDefaultNetwork` (init/update) + импорты.
- `vpn/DefaultNetworkListener.kt` — `NET_CAPABILITY_NOT_VPN` в request (явный
  no-op + комментарий со ссылкой на AOSP).
- `services/builder/post_steps/tun_packages.dart` — поправлен устаревший
  коммент-якорь (`557-560` → `208-211`, split-tunneling в `BoxVpnService`). К
  §119-логике отношения не имеет.

## Риски и edge cases

- **Регрессии нет:** на устройствах, где `getActiveNetwork()` и так отдавал
  underlying, `takeUnless(::isVpn)` — тот же результат. Меняется поведение только
  там, где seed был VPN (init при уже поднятом tun).
- **Остаточный путь без фильтра:** `DefaultNetworkListener.get()` fallback-ветки
  ([DefaultNetworkListener.kt:58-60](../../../app/android/app/src/main/kotlin/com/leadaxe/lxbox/vpn/DefaultNetworkListener.kt))
  тоже читает `activeNetwork` без VPN-фильтра, но достижима только на API < 21,
  где `requestNetwork(request, callback)` кинул `RuntimeException`. На целевых
  устройствах (MIUI A13 = API 33) недостижима — фильтровать там не стали, чтобы
  не раздувать фикс. Помечено здесь как известный edge-case.
- **API < 28** (`registerDefaultNetworkCallback` без request) — `NOT_VPN` к
  callback'у не применяется, но seed-фильтр работает на всех API ≥ 23.
- **VPN-only без underlying** — seed после фильтра `null`, callback по NOT_VPN
  тоже ничего не сматчит → `null` → `notifySync` отдаёт «no interface» (как и
  раньше при отсутствии сети).

## Верификация

- **Сборка** (gradle assembleRelease компилирует Kotlin — отдельных Kotlin-юнитов
  в проекте нет).
- **Non-regression smoke на ColorOS (CPH2411):** установка поверх prod, connect,
  allowed-приложение + DNS работают как и раньше; `adb logcat -s LxBoxNet`
  показывает `vpn=false iface=wlan0/rmnet…` (underlying — корректно).
- **MIUI-фикс** на устройстве репортёра локально **не проверяем** (репро нет,
  репортёр недоступен). Фикс — по root-cause-анализу + принципиально безопасен.
  Если будущий field-report покажет `[init] vpn=true` после фикса — фильтр обойдён
  (копать); `[update] vpn=true` — underlying не сматчился вопреки NOT_VPN (копать
  шире выбора сети). Лог уже встроен.

## Технический долг

**TD-119-1 — `logDefaultNetwork` сейчас безусловный, это временно.**

`DefaultNetworkMonitor.logDefaultNetwork` пишет `Log.i("LxBoxNet", …)` на каждый
`[init]`/`[update]` **во всех сборках, включая release, без debug-gating**. Это
сознательный временный выбор: device-repro у нас нет, и безусловный лог — единств.
способ получить `vpn=true/false` с чужого устройства одной командой
(`adb logcat -s LxBoxNet`).

- **Условие снятия:** как только §119-фикс подтверждён на реальном устройстве
  (хотя бы один field-report / прямой репро показал `[init] vpn=false` после
  фикса) — лог теряет назначение и должен быть свёрнут.
- **Что сделать (любой из вариантов):**
  1. **Выключить** — убрать вызовы `logDefaultNetwork` (revert; это +1 helper и 2
     call-site'а, тривиально), **или**
  2. **Перенести в debug-форму** — обернуть в gate, чтобы в release молчал, а
     включался по требованию без пересборки:
     ```kotlin
     if (!Log.isLoggable("LxBoxNet", Log.INFO)) return
     ```
     тогда прод по умолчанию тих, а диагностика поднимается
     `adb shell setprop log.tag.LxBoxNet INFO`. Альтернатива — `BuildConfig.DEBUG`
     (жёстко off в release, без runtime-рубильника).
- **Рекомендация:** вариант 2 (`isLoggable`) — сохраняет рубильник на будущие
  field-report'ы, нулевой шум в проде. Чистый revert (вариант 1) — если §119
  закрыт окончательно и подобных репортов больше не ждём.

> Пока §119 в статусе «device-repro отсутствует» — **не трогать**, лог зарабатывает
> своё место. Снятие — отдельной мелкой таской после подтверждения.
