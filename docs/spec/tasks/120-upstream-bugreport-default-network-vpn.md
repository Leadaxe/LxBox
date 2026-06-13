# 120 — upstream bug report: defaultNetwork seed может быть нашим VPN

| Поле | Значение |
|------|----------|
| Статус | Done — upstream PR открыт; локальный issue закрыт как resolved §119 |
| Дата старта | 2026-06-13 |
| Дата завершения | 2026-06-14 |
| Коммиты/ссылки | upstream PR [SagerNet/sing-box-for-android#61](https://github.com/SagerNet/sing-box-for-android/pull/61) (base `dev`); локальный трекинг [Leadaxe/LxBox#10](https://github.com/Leadaxe/LxBox/issues/10) (closed) |
| Связанные | [tasks/119](119-default-network-not-vpn.md) (наш фикс §119) |

## Цель

Зафиксировать публичным issue баг, который мы нашли и пофиксили в рамках §119:
`DefaultNetworkMonitor.start()` сидит `defaultNetwork` из `getActiveNetwork()`
**без фильтра VPN-транспорта**, из-за чего на части прошивок seed может оказаться
нашим же tun → DNS-loop в `LocalResolver` (см. [tasks/119](119-default-network-not-vpn.md),
root cause).

### Почему issue у нас, а не в upstream

Изначально цель была отрепортить наверх в
[SagerNet/sing-box-for-android](https://github.com/SagerNet/sing-box-for-android)
(баг есть и там, см. ниже). **Это оказалось невозможно:**

- У `sing-box-for-android` **отключены и issues, и discussions** (`has_issues:false`,
  `has_discussions:false` — проверено через API).
- SagerNet принимает баги только в главном [`SagerNet/sing-box`](https://github.com/SagerNet/sing-box),
  но его форма `bug_report.yml` содержит **обязательный** integrity-чеклист,
  требующий **локальное CLI-репро без TUN и без GUI-клиента** (с угрозой
  перманентного бана за ложное подтверждение). Наш баг — внутри Android-GUI-клиента
  и завязан на TUN + per-app VPN-скоупинг Android; честного CLI-репро нет и быть
  не может. Отметить эти галочки = солгать форме.

Поэтому баг затрекан публичным issue в **нашем** репо [Leadaxe/LxBox#10](https://github.com/Leadaxe/LxBox/issues/10)
и сразу закрыт как resolved (фикс §119 уже в `develop`). Текст ниже сохранён как
готовый материал на случай, если появится приемлемый upstream-канал (например PR
против `dev`).

## Что в репорте проверено по первоисточникам (2026-06-13)

Фактчек проведён против реального upstream-кода и AOSP — галлюцинаций нет:

- Коммит `19c3a58` = текущий upstream `dev` HEAD; все три пиннутые ссылки на
  строки (`DefaultNetworkMonitor.kt#L19-L20`, `DefaultNetworkListener.kt#L124-L126`,
  `NetworkRequest.Builder`) сверены с фактическим содержимым на этом SHA.
- `NetworkCapabilities.DEFAULT_CAPABILITIES` ⊇ `NOT_VPN`, и `NetworkCapabilities()`
  default-конструктор применяет их → `NetworkRequest.Builder()` несёт `NOT_VPN`
  (цепочка замкнута из AOSP-исходника, не из памяти).
- Баг присутствует и в теге `v1.3.1-rc.1` (строка 19 = unfiltered `activeNetwork`).
- sing-box#3637 / #2643 — реально про DNS-loop в tun.
- Цитата *«…a VPN that applies to the application»* — дословно из javadoc
  `ConnectivityManager.registerDefaultNetworkCallback()` (исправлена атрибуция:
  раньше ссылалась на гайд «Read network state», где фразы нет).
- Permalink'и на нашу реализацию фикса (`Leadaxe/LxBox@2f98bb2`, L45-L48 + L151-L153)
  резолвятся и пиннятся к правильным строкам.

## Шаги

- [x] ~~Создать issue в upstream~~ — невозможно: issues/discussions у SFA
      отключены, форма sing-box требует TUN-free CLI-репро (см. выше).
- [x] Затрекать баг публичным issue в нашем репо → [Leadaxe/LxBox#10](https://github.com/Leadaxe/LxBox/issues/10).
- [x] Закрыть issue как resolved (фикс §119 в `develop`).
- [x] Открыть PR против upstream `dev` с `takeUnless(::isVpn)`-фильтром →
      [SagerNet/sing-box-for-android#61](https://github.com/SagerNet/sing-box-for-android/pull/61).
      Минимальный diff (+14/−1, только `DefaultNetworkMonitor.kt`): фильтр на
      init-seed + helper `isVpn`. Fallback `get()` (API<23, flavor `otherLegacy`)
      не трогали. Форк: `Leadaxe/sing-box-for-android`, ветка `fix/default-network-vpn-seed`.
- [ ] Если upstream примет PR — отметить в [tasks/119](119-default-network-not-vpn.md),
      что локальный патч можно дропнуть после rebase на соответствующий релиз.

## Заметки

- Тон репорта выдержан как downstream-контрибьюция: «наткнулись в LxBox, проверили
  в вашем коде, вот фикс, готовы прислать PR» — не «у вас баг, чините».
- Перед публикацией issue (отправка контента во внешний публичный сервис) —
  подтвердить с юзером, что текст можно постить под его аккаунтом.
- Ссылки на строки upstream пиннятся к `dev` HEAD `19c3a58` (актуально на 2026-06-13).
  При создании issue сильно позже — перепроверить, что HEAD не уехал.

---

## Текст issue (готов к копированию)

### Title

```
DefaultNetworkMonitor.start() may seed defaultNetwork with the app's own VPN → LocalResolver DNS loop on some ROMs
```

### Body

#### Summary

`DefaultNetworkMonitor.start()` seeds `defaultNetwork` from
`ConnectivityManager.getActiveNetwork()` **without filtering out the VPN
transport**. `getActiveNetwork()` returns the *per-app default network*, which —
per Android docs — **may be the VPN that applies to the calling app**. When the
tun is already up at the moment `start()` runs, this seed can be sing-box's own
VPN `Network`. `LocalResolver` then calls `DnsResolver.query(defaultNetwork=VPN)`,
the query re-enters the tun (`auto_route`), and DNS loops — apps under the VPN
fail to resolve names.

This is a race: the async `DefaultNetworkListener` callback later overwrites the
seed with the NOT_VPN-filtered underlying network, but the synchronous
`getActiveNetwork()` seed is used for the first resolutions and on some ROMs the
tun is already up when it's read.

#### How we found it

We hit this in [**LxBox**](https://github.com/Leadaxe/LxBox), a downstream Android
client that builds on this codebase: a field report (MIUI / Android 13,
split-tunneling) showed allowed apps had no DNS until the VPN app itself was
added to the allow-list. We traced it back to the unfiltered `getActiveNetwork()`
seed in `DefaultNetworkMonitor.start()` and verified the fix against the
reference code — it resolves the loop without the allow-list workaround, and is
a no-op on the devices where the bug doesn't reproduce. The fix is described
below.

#### Where

[`app/src/main/java/io/nekohasekai/sfa/bg/DefaultNetworkMonitor.kt#L19-L20`](https://github.com/SagerNet/sing-box-for-android/blob/19c3a58778cb183d3e10c786a366d68ff0e64f8e/app/src/main/java/io/nekohasekai/sfa/bg/DefaultNetworkMonitor.kt#L19-L20):

```kotlin
defaultNetwork = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M) {
    Application.connectivity.activeNetwork          // ← no VPN filter
} else {
    DefaultNetworkListener.get()
}
```

Same unfiltered read on the fallback path:
[`DefaultNetworkListener.kt#L124-L126`](https://github.com/SagerNet/sing-box-for-android/blob/19c3a58778cb183d3e10c786a366d68ff0e64f8e/app/src/main/java/io/nekohasekai/sfa/bg/DefaultNetworkListener.kt#L124-L126).

> Note: the `NetworkRequest` used by `DefaultNetworkListener` is fine — it carries
> `NET_CAPABILITY_NOT_VPN` because that capability is part of
> `NetworkCapabilities.DEFAULT_CAPABILITIES`
> ([AOSP](https://android.googlesource.com/platform/packages/modules/Connectivity/+/refs/heads/master/framework/src/android/net/NetworkCapabilities.java)).
> The callback-sourced `defaultNetwork` is therefore already VPN-free. The gap is
> **only** the direct `getActiveNetwork()` seed, to which the request's
> capabilities do not apply.

#### Why it's ROM-dependent (and why "works on my device")

Whether the seed catches the VPN depends on the ordering of *"tun came up"* vs
*"`getActiveNetwork()` was read"* at service start. That ordering varies by
device/ROM timing.

Observed in the field:
- **Reproduces:** MIUI / Android 13 — with split-tunneling (allow-list), allowed
  apps have no DNS until the VPN app itself is added to the allow-list (a
  symptom-patch that changes per-app network scoping).
- **Does NOT reproduce:** ColorOS / Android 15, AOSP / Android 16 — seed lands on
  the physical network, all good.

#### Docs / source of truth

- `registerDefaultNetworkCallback()` notifies about the *"application's default
  network. This may be a physical network or a virtual network, such as a VPN
  that applies to the application"* —
  [`ConnectivityManager.registerDefaultNetworkCallback()`](https://developer.android.com/reference/android/net/ConnectivityManager#registerDefaultNetworkCallback(android.net.ConnectivityManager.NetworkCallback)).
  `getActiveNetwork()` returns this same per-app default.
- DNS loop in tun mode:
  [sing-box#3637](https://github.com/SagerNet/sing-box/issues/3637),
  [sing-box#2643](https://github.com/SagerNet/sing-box/issues/2643).

#### Suggested fix

Filter out the VPN transport when seeding from `getActiveNetwork()`, so the seed
is never the app's own tun:

```kotlin
defaultNetwork = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M) {
    Application.connectivity.activeNetwork?.takeUnless(::isVpn)
} else {
    DefaultNetworkListener.get()
}

private fun isVpn(network: Network): Boolean =
    Application.connectivity.getNetworkCapabilities(network)
        ?.hasTransport(NetworkCapabilities.TRANSPORT_VPN) == true
```

The async callback (already NOT_VPN-filtered) overwrites the seed shortly after,
so behavior on unaffected devices is unchanged — the filter only removes the
race window where the seed itself was the VPN. Same filter is advisable on the
`DefaultNetworkListener.get()` fallback path.

This is exactly what we shipped in LxBox (package renamed to our namespace, logic
identical): the [`takeUnless(::isVpn)` seed filter](https://github.com/Leadaxe/LxBox/blob/2f98bb286f118b048e2415779127bcbef8ac8ea4/app/android/app/src/main/kotlin/com/leadaxe/lxbox/vpn/DefaultNetworkMonitor.kt#L45-L48)
plus the [`isVpn` helper](https://github.com/Leadaxe/LxBox/blob/2f98bb286f118b048e2415779127bcbef8ac8ea4/app/android/app/src/main/kotlin/com/leadaxe/lxbox/vpn/DefaultNetworkMonitor.kt#L151-L153).
Happy to open a PR against `dev` if useful.

#### Environment

- sing-box-for-android: `dev` branch (HEAD `19c3a58`), also present in `v1.3.1-rc.1`.
- Repro device: MIUI, Android 13.
- Use case: split-tunneling (allow-list / per-app VPN) with `auto_route` +
  `local` DNS strategy (`LocalResolver`).
