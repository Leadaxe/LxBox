# 119 — default-network: форсить underlying (NET_CAPABILITY_NOT_VPN)

| Поле | Значение |
|------|----------|
| Статус | Code-complete в develop (девайс-репро отсутствует — фикс по root-cause-анализу + non-regression smoke) |
| Дата старта | 2026-06-13 |
| Дата завершения | — |
| Коммиты | — |
| Связанные spec'ы | features/046 (tunnel apps split-tunneling), features/047 (DNS/network deterioration) |

## Проблема (field report)

Field report (4PDA, Михаил, **MIUI Android 13**): при **Allow-list** (только
выбранные приложения через VPN) трафик allowed-приложений **не работает**, пока
в Allow-list не добавить **сам L×Box**. По §046 это должно быть no-op («наш
process сам не зависит от tun»), и на чистом Android / ColorOS (CPH2411)
**не воспроизводится** — allow-list работает без самодобавления.

## Root cause (по инспекции кода)

Цепочка DNS allowed-приложения:

1. `openTun` анонсирует на VpnService DNS-сервер
   ([BoxVpnService.kt:186](../../../app/android/app/src/main/kotlin/com/leadaxe/lxbox/vpn/BoxVpnService.kt)
   `builder.addDnsServer`) → DNS захваченных приложений идёт в TUN → sing-box DNS.
2. DNS Final по умолчанию = `local_dns_resolver` → `LocalResolver`.
3. `LocalResolver` резолвит через `DnsResolver.query(defaultNetwork, …)`
   ([LocalResolver.kt:38,118](../../../app/android/app/src/main/kotlin/com/leadaxe/lxbox/vpn/LocalResolver.kt)),
   где `defaultNetwork` **обязан** быть underlying-физикой (иначе DNS уходит
   обратно в tun → loop).
4. `defaultNetwork` берётся из `DefaultNetworkMonitor` ← `DefaultNetworkListener`
   (NetworkCallback).

**Баг:** `NetworkRequest` в
[DefaultNetworkListener.kt:70-77](../../../app/android/app/src/main/kotlin/com/leadaxe/lxbox/vpn/DefaultNetworkListener.kt)
требовал `INTERNET` + `NOT_RESTRICTED`, но **НЕ** `NOT_VPN`. На Android 12+
регистрация идёт через `registerBestMatchingNetworkCallback(request)`
([:83](../../../app/android/app/src/main/kotlin/com/leadaxe/lxbox/vpn/DefaultNetworkListener.kt)).
Наш собственный VPN-network тоже имеет `INTERNET`+`NOT_RESTRICTED` → «best
matching» на некоторых прошивках (MIUI A13) возвращает **сам VPN** как
`defaultNetwork`. Тогда `LocalResolver` шлёт `DnsResolver.query(VPN)` → loop →
allowed-приложения не резолвят имена → «не работает».

«Добавление себя» лечит косвенно (меняет сетевой скоупинг так, что система
начинает отдавать underlying) — это **симптом-патч**, не причина.

Почему не репро на ColorOS/Pixel: их прошивки сами исключают VPN из дефолта для
VPN-приложения. MIUI конкретной сборки — нет. `NOT_VPN` убирает зависимость от
«доброты прошивки».

## Решение

1. **`addCapability(NET_CAPABILITY_NOT_VPN)`** в `DefaultNetworkListener` request
   → `defaultNetwork` **всегда** underlying-физика, никогда VPN — на всех
   прошивках. Чинит `local_dns_resolver`-путь allowed-приложений **без**
   прописывания себя.
2. **Постоянный диаг-лог** `LxBoxNet` в `DefaultNetworkMonitor.logDefaultNetwork`
   (`iface` + `vpn=true/false`). Репро у нас нет → следующий такой field-report
   диагностируется сразу: `adb logcat -s LxBoxNet`. `vpn=true` = баг налицо;
   после фикса ожидаем всегда `vpn=false`.

**НЕ делаем self-add** (отклонено): он гоняет служебный трафик L×Box через VPN и
делает §046-заметку «adding L×Box has no effect» ложью.

## Затронутые файлы

- `vpn/DefaultNetworkListener.kt` — `NET_CAPABILITY_NOT_VPN` в request.
- `vpn/DefaultNetworkMonitor.kt` — `logDefaultNetwork` (init/update) + импорты.
- `services/builder/post_steps/tun_packages.dart` — поправлен устаревший
  коммент (`557-560` → `208-211`).

## Риски и edge cases

- **Регрессии нет:** на устройствах, где `defaultNetwork` уже underlying
  (ColorOS/Pixel), `NOT_VPN` даёт тот же результат, просто явно. Меняется
  поведение только там, где прошивка возвращала VPN.
- **API < 28** (`registerDefaultNetworkCallback` без request) — `NOT_VPN` к ним
  не применяется, но там система и так отдаёт underlying для VPN-приложения.
- **VPN-only без underlying** — `NOT_VPN`-запрос не сматчит ничего → `null` →
  `notifySync` отдаёт «no interface» (как и раньше при отсутствии сети).

## Верификация

- **Сборка** (gradle assembleRelease компилирует Kotlin — отдельных Kotlin-юнитов
  в проекте нет).
- **Non-regression smoke на ColorOS (CPH2411):** установка поверх prod, connect,
  allowed-приложение + DNS работают как и раньше; `adb logcat -s LxBoxNet`
  показывает `vpn=false iface=wlan0/rmnet…` (underlying — корректно).
- **MIUI-фикс** на устройстве репортёра локально **не проверяем** (репро нет,
  репортёр недоступен). Фикс — по root-cause-анализу + принципиально безопасен.
  Если будущий field-report покажет `vpn=true` после фикса — причина шире выбора
  сети, копать дальше (лог уже встроен).
