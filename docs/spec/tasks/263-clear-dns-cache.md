# §263 — кнопка «Clear DNS cache» (FakeIP + RDRC)

**Статус:** Реализовано (не device-verified)
**Ядро:** v1.14.0-lx.3 (финал; API идентичен rc.2)
**Файлы:** `dns_settings_screen.dart` (UI), `box_vpn_client.dart` + `box_vpn_client/
{method_names,timeouts}.dart` (Dart method-channel), `VpnPlugin.kt` (handler),
`BoxVpnService.kt` (companion + delete-helper + ACTION), `BoxService.kt` (receiver + filter).
**Тип:** новое разовое действие (не настройка конфига — не идёт в rebuild).

---

## 0. Проблема

sing-box держит DNS-кэш в файле `experimental.cache_file` (`path: "cache.db"`,
`store_fakeip: true` — шаблон:609-613). В нём: FakeIP-аллокации (domain→198.18.x.x) и DNS
RDRC (rejected-domain cache). Файл **персистентный** — переживает reload/рестарт (в этом
смысл `store_fakeip`: стабильные fake-IP между сессиями). Стейл-кэш после смены сети / DNS-
глюков не сбрасывается ничем, кроме удаления файла. В libbox CommandClient **нет RPC** для
сброса кэша (проверено javap: команды Log/Status/Group/ClashMode/Connections/Outbounds/DNS —
сброса нет). Единственный путь — файловый.

## 1. Механика

Кнопка → `BoxVpnClient.clearDnsCache()` → method-channel `clearDnsCache` → Kotlin
`BoxVpnService.clearDnsCache(context)` ветвит по `currentStatus`:

- **VPN running** (Started/Starting): `sendBroadcast(ACTION_CLEAR_DNS_CACHE)` → receiver в
  `BoxService`: `deleteCacheDbFile()` затем `serviceReload()`. `serviceReload` зовёт
  `cs.startOrReloadService(config)` — ядро закрывает старый box-инстанс (освобождает fd
  cache.db) и поднимает новый, который создаёт чистый `cache.db`. Delete **перед** reload:
  старый инстанс держит unlink'нутый inode, новый пишет в свежий файл. Тоннель дропается
  ~3с (как обычный reload §030).
- **VPN off** (Stopped/Stopping): receiver не зарегистрирован (живёт только у работающего
  сервиса) → companion удаляет `cache.db` **напрямую**; чистый создастся при следующем старте.

Путь файла: `filesDir/cache.db` (`BoxApplication.setup` ставит `basePath=workingPath=
filesDir`; шаблон — относительный `path: "cache.db"`). Delete идемпотентен (нет файла →
no-op: свежая установка / уже чисто).

## 2. UI

`dns_settings_screen.dart` — ListTile **в самом низу** (после Default Resolver), отдельным
блоком за `Divider`: «Clear DNS cache» / «Flush FakeIP allocations and cached DNS responses.
Reloads the VPN if running.» Иконка `cleaning_services_outlined` в error-цвете. Тап →
AlertDialog подтверждения (текст зависит от `tunnelUp`: «briefly reload» vs «rebuilt clean
on the next connect») → `clearDnsCache()` → snackbar. **Гейта нет** (кнопка активна всегда —
при выключенном VPN просто удаляет файл, решение владельца).

## 3. Точки изменений

| Слой | Файл | Что |
|---|---|---|
| Dart метод | `box_vpn_client/method_names.dart` | `clearDnsCache = 'clearDnsCache'` |
| Dart таймаут | `box_vpn_client/timeouts.dart` | `dnsCache = 10s` |
| Dart обёртка | `box_vpn_client.dart` | `Future<bool> clearDnsCache()` |
| Kotlin handler | `VpnPlugin.kt` | case `"clearDnsCache"` → `BoxVpnService.clearDnsCache(context)` |
| Kotlin companion | `BoxVpnService.kt` | `ACTION_CLEAR_DNS_CACHE` + `clearDnsCache()` (ветвление) + `deleteCacheDbFile()` |
| Kotlin receiver | `BoxService.kt` | case `ACTION_CLEAR_DNS_CACHE` → delete + `serviceReload()`; `addAction` в IntentFilter |
| UI | `dns_settings_screen.dart` | ListTile + `_confirmClearDnsCache()` |

## 4. Критерии готовности

- [x] `flutter analyze` (весь проект) — чисто.
- [x] `flutter test` — зелёные.
- [ ] Device-verify на CPH2411: (1) VPN up → включить FakeIP, сходить на сайты (набить
      fake-IP), тап «Clear DNS cache» → тоннель мигает ~3с, `cache.db` пересоздан пустым
      (logcat `[dns] cache.db delete=true`), FakeIP заново аллоцирует; (2) VPN off → тап →
      файл удалён без reload; (3) кэш пуст (нет cache.db) → no-op, без ошибок.
