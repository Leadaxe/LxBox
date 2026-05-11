# Wi-Fi-aware routing

Правила роутинга которые **зависят от текущей Wi-Fi сети**. Решает кейсы вида:
- *На домашнем Wi-Fi → весь трафик direct, без VPN.*
- *На рабочем Wi-Fi → банкинг direct, остальное через VPN.*
- *На мобильной сети → весь трафик через VPN.*
- *На Wi-Fi конкретного провайдера (по BSSID) → специальный outbound.*

Раньше это было возможно только через временный override `PUT /config` + `config_locked` — теперь персистентно через обычный `CustomRule`.

| | |
|---|---|
| Где живёт | `Routing → Rules` (editor правила, поля `Wi-Fi SSID` / `Wi-Fi BSSID`) |
| Spec | [`docs/spec/tasks/051-custom-rule-wifi-conditions.md`](../spec/tasks/051-custom-rule-wifi-conditions.md) |
| Реализация в | v1.7.3 (Phase 1+2+3 закрыты) |
| Storage | `vars.wifi_history` + `vars.auto_record_wifi_history` ([STORAGE.md](../STORAGE.md#wifi_history--051-phase-3)) |
| Debug API | `/wifi_history` CRUD ([reference](../api/debug-api-reference.md#wi-fi-history--wifi_history)) |

## TL;DR

1. Открыть `Routing → Rules`, создать или открыть правило.
2. В editor'е найти секцию **Wi-Fi conditions**.
3. Заполнить SSID и/или BSSID:
   - **Add current** — берёт ssid/bssid текущей сети одним тапом (через sing-box `readWIFIState`).
   - **Pick saved** — выбор из истории посещённых сетей (`wifi_history`).
   - **Manual** — впечатать SSID или BSSID руками (для сетей куда юзер ещё не подключался).
4. Save — правило применяется при следующем rebuild config'а.

Правило с `wifi_ssid:[HomeWiFi] → direct` означает буквально: *когда Wi-Fi сеть = `HomeWiFi`, трафик идёт через outbound `direct` (не через VPN)*. Если сеть не `HomeWiFi` — правило не матчится, edits применяются по дальнейшим правилам.

## Комбинация с другими условиями

Wi-Fi conditions **AND-комбинируются** со всеми остальными match-полями того же правила (стандартная sing-box rule formula: OR within а category, AND across):

| Правило | Семантика |
|---|---|
| `wifi_ssid:[Home]` → `direct` | Любой трафик на домашнем Wi-Fi → direct |
| `wifi_ssid:[Office] AND domain:[*.bank.com]` → `direct` | Банкинг direct **только** на рабочем Wi-Fi (на других — стандартное поведение default rules) |
| `wifi_bssid:[aa:bb:cc:dd:ee:ff] AND port:[443]` → `proxy-A` | HTTPS через `proxy-A` только на одном конкретном AP |
| `rule_set:[geosite-ru] AND wifi_ssid:[Home]` → `ru-direct` | Country-specific routing per Wi-Fi (требует cached SRS) |

`wifi_ssid` принимает массив (OR): `wifi_ssid:[Home, Office]` матчится на любой из перечисленных.

## SSID vs BSSID — что когда использовать

- **SSID** — имя сети (например `HomeWiFi`). Удобно: одно правило покрывает все AP в одной сети (домашний роутер с 2.4 + 5 GHz radio = два разных BSSID, один SSID). Уязвимо к подмене: злоумышленник может поднять fake AP с тем же SSID.
- **BSSID** — MAC-адрес конкретного AP. Точная привязка: правило сматчится только на этот конкретный физический роутер. Полезно когда тебе важна именно физическая локация (офис), а не имя.

В редакторе можно заполнить оба — будет AND (точная привязка к конкретной сети + конкретному AP).

## Auto-record visited networks (opt-in)

Чтобы **Pick saved** picker не был пустым, можно включить auto-record в `App Settings → Diagnostics → Auto-record Wi-Fi networks`. После включения:

- Native `WifiNetworkObserver` слушает `ConnectivityManager.NetworkCallback` и наблюдает изменения текущей сети.
- Когда юзер **проводит на сети ≥5 минут** (stickiness debounce), сеть пишется в `wifi_history`.
- 5 минут — фильтр от random transitions: проехал мимо кофейни — не записываем; реально работаешь в кофейне час — записываем.
- Cap **50 записей**, LRU evict (newest-first, oldest падает с tail).

**Privacy default — off.** Локальное логирование посещённых сетей это privacy-след, даже если данные не покидают устройство. Юзер opt-in'ит сознательно.

## Permissions

Wi-Fi rules require special permissions, поскольку Android 13+ ограничивает доступ к SSID/BSSID:

| Permission | Когда нужен | Что произойдёт без |
|---|---|---|
| `ACCESS_BACKGROUND_LOCATION` | API 29+, всегда для VPN-foreground-service | sing-box получает `<unknown ssid>`, правила не матчатся |
| `NEARBY_WIFI_DEVICES` | Android 13+ (`targetSdk≥33`) | sing-box получает `<unknown ssid>` даже с location grant |

При попытке старта VPN с активным wifi-правилом и missing permissions — показывается **actionable dialog** с кнопками:
- **Allow Wi-Fi info** — runtime prompt для `NEARBY_WIFI_DEVICES` (one tap).
- **Open Settings** — для `ACCESS_BACKGROUND_LOCATION` (нельзя выдать через runtime prompt на API 30+, только через системные настройки).

Permissions можно проверить заранее в `App Settings → Diagnostics → System setup` — там interactive ListTile-блок c live-статусом каждой permission.

## Известные ограничения

- **Cross-product trap** ([§051 spec](../spec/tasks/051-custom-rule-wifi-conditions.md)). Если в одном правиле перечислить много SSID и много доменов, sing-box интерпретирует это как cartesian product (каждый SSID × каждый домен). Для `wifi_ssid:[A,B,C], domain:[x.com, y.com, z.com]` это 9 условий. Производительности это не вредит, но семантика может быть неинтуитивной — каждое условие связкой OR. Если хочешь *именно* «(A OR B OR C) AND (x.com OR y.com OR z.com)» — это и так работает (стандартная sing-box rule). Документировано как известный риск.
- **Sticky 5-min debounce** жёстко зашит. Не настраивается в UI — если нужно записать сеть быстрее, используй **Add current** в editor'е вручную, или `POST /wifi_history` через Debug API.
- **Auto-record не работает когда VPN off** — `WifiNetworkObserver` запускается только когда foreground service активен. Это сознательно — фоновый observer без VPN был бы лишним battery footprint'ом.

## Debug API

Для тестов / restore / batch-import:

```bash
# List
curl -s -H "$HDR" "$BASE/wifi_history" | jq

# Inject (для test fixture)
curl -X POST -H "$HDR" -H "Content-Type: application/json" \
  -d '{"ssid":"OfficeWiFi","bssid":"11:22:33:44:55:66"}' \
  "$BASE/wifi_history"

# Remove specific
curl -X DELETE -H "$HDR" -H "Content-Type: application/json" \
  -d '{"ssid":"OfficeWiFi","bssid":"11:22:33:44:55:66"}' \
  "$BASE/wifi_history"

# Wipe all
curl -X DELETE -H "$HDR" "$BASE/wifi_history/all"
```

Полный reference — [Debug API → Wi-Fi history](../api/debug-api-reference.md#wi-fi-history--wifi_history).

## См. также

- [§051 spec](../spec/tasks/051-custom-rule-wifi-conditions.md) — модель + builder + Phase 3 implementation notes.
- [§050 findings](../spec/tasks/050-libbox-debug-build/findings.md) — почему `readWIFIState` раньше падал refnum 42 и как починили (real cause = unhandled `SecurityException` через JNI).
- [§030 custom routing](../spec/features/030%20custom%20routing%20rules/spec.md) — родительская модель `CustomRule` которую расширили wifi-полями.
- [STORAGE.md → wifi_history](../STORAGE.md#wifi_history--051-phase-3) — schema хранилища.
- [Debug API → Wi-Fi history](../api/debug-api-reference.md#wi-fi-history--wifi_history) — endpoint reference.
