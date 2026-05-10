# 051 — CustomRule: wifi_ssid / wifi_bssid conditions (Phase 1: API only)

| Поле | Значение |
|------|----------|
| Статус | Draft |
| Дата | 2026-05-10 |
| Связанные | [`030 custom routing`](../features/030%20custom%20routing/spec.md) — расширяет sealed model; [`050 libbox-debug-build`](./050-libbox-debug-build/findings.md) — F12.3 readWIFIState fix (prerequisite) |
| Затронутые файлы | `app/lib/models/custom_rule.dart`, `app/lib/services/builder/...` (rule emission), `app/lib/services/debug/handlers/rules.dart`, `app/lib/services/debug/serializers/rules.dart`, `test/models/`, `test/builder/`, `test/parser/` |

## Цель

Дать `CustomRuleInline` и `CustomRuleSrs` поддержку условий `wifi_ssid` / `wifi_bssid`, чтобы юзер мог объявлять правила вида «на этом Wi-Fi → direct» **persistent** (через `POST /rules`), не прибегая к временному `PUT /config` + `config_locked`.

UI editor — Phase 2. Эта таска — **только модель + builder + Debug API**.

## Контекст

Sing-box нативно поддерживает `wifi_ssid: [string,...]` и `wifi_bssid: [string,...]` в каждом `route.rules[i]` и `dns.rules[i]`. Условия AND-ятся со всеми остальными полями того же правила, поэтому юзер может комбинировать:

- Чисто wifi: `wifi_ssid:[lexRouter] → direct`
- Wifi + domain: `wifi_ssid:[OfficeWiFi] AND domain:[*.bank.com] → direct`
- Wifi + SRS rule_set: `rule_set:[geosite-ru] AND wifi_ssid:[HomeWiFi] → ru-direct`

Поэтому **отдельный `CustomRuleWifi` kind не вводим** — потеряли бы возможность комбинировать. Расширяем существующие kind'ы.

## Что меняется в модели

### `CustomRuleInline`

```dart
class CustomRuleInline extends CustomRule {
  // existing
  final List<String> domains, domainSuffixes, domainKeywords;
  final List<String> ipCidrs, ports, portRanges, packages, protocols;
  final bool ipIsPrivate;
  final String outbound;

  // NEW
  final List<String> wifiSsids;       // canonical (без quotes)
  final List<String> wifiBssids;      // xx:xx:xx:xx:xx:xx, lower-case
}
```

### `CustomRuleSrs`

```dart
class CustomRuleSrs extends CustomRule {
  // existing
  final String srsUrl;
  final List<String> ports, portRanges, packages, protocols;
  final bool ipIsPrivate;
  final String outbound;

  // NEW
  final List<String> wifiSsids;
  final List<String> wifiBssids;
}
```

### `CustomRulePreset` — **не меняется**

Preset подставляется из template'а; vars-substitution для wifi-условий — отдельная фича (если понадобится). Phase 1 за её скобки.

## Serialization

### `CustomRule.toJson` / `fromJson`

```json
{
  "id": "...",
  "kind": "inline",
  "name": "Home wifi → direct",
  "enabled": true,
  "outbound": "direct-out",
  "domains": [],
  "ip_cidrs": [],
  "ports": [],
  "wifi_ssids": ["lexRouter"],
  "wifi_bssids": ["38:2c:4a:cf:6d:5c"]
}
```

Pравила:
- `fromJson` defaults `wifi_ssids: const []`, `wifi_bssids: const []` — старые backup'ы / settings без этих полей загружаются без ошибок.
- `toJson` пишет ключи **только если non-empty** (skip empty) — backup compactness.
- BSSID нормализация: lower-case при чтении (юзер мог ввести uppercase).

### Migration

**Zero**. Старые rules не имеют этих полей → defaults to empty → behavior unchanged.

## Builder pipeline

При генерации `route.rules[i]` / `dns.rules[i]` из `CustomRule`:

```dart
if (rule.wifiSsids.isNotEmpty) jsonRule['wifi_ssid'] = rule.wifiSsids;
if (rule.wifiBssids.isNotEmpty) jsonRule['wifi_bssid'] = rule.wifiBssids;
```

Для DNS-маршрутизации (если правило затрагивает DNS) — аналогично эмитим `wifi_ssid`/`wifi_bssid` в DNS-rule.

**Order invariant** — wifi-условия не меняют относительный порядок правил в `route.rules[]`. CustomRule rules вставляются на свою позицию (после infrastructure: resolve/sniff/hijack-dns), внутри — в порядке `custom_rules` array. Wifi-conditions — это **дополнительный фильтр** в том же rule, не отдельная sequence.

## Debug API

### `POST /rules`

Body новых полей:

```json
{
  "name": "Home wifi → direct",
  "kind": "inline",
  "enabled": true,
  "outbound": "direct-out",
  "wifi_ssids": ["lexRouter"],
  "wifi_bssids": ["38:2c:4a:cf:6d:5c"]
}
```

Validation в `_ruleFromJsonStrict`:
- `wifi_ssids`: list of strings, non-empty strings, max 32 chars каждое (sing-box hard limit?). Empty list = no wifi condition.
- `wifi_bssids`: list of strings матчащих `^[0-9A-Fa-f]{2}(:[0-9A-Fa-f]{2}){5}$`, normalize to lower-case.

### `PATCH /rules/{id}`

`setIfPresent('wifiSsids', fieldStringList(body, 'wifi_ssids'));`
`setIfPresent('wifiBssids', fieldStringList(body, 'wifi_bssids'));`

### `GET /rules` / `GET /state/rules`

Сериализатор включает `wifi_ssids` / `wifi_bssids` в response (даже если empty — для consistency с другими list-полями).

## Permission flow

Уже работает без новых правок:

1. `BoxService.startSingbox` после `startOrReloadService` вызывает `cs.needWIFIState()`.
2. Если sing-box видит `wifi_ssid`/`wifi_bssid` в любом правиле → `needWIFIState()` returns `true`.
3. Permission check матрица (см. §050):
   - API 28-: `ACCESS_FINE_LOCATION`
   - API 29-32: `ACCESS_BACKGROUND_LOCATION`
   - API 33+: `ACCESS_BACKGROUND_LOCATION + NEARBY_WIFI_DEVICES`
4. Missing → `stopAndAlert("alert:permission_location:...")` → Flutter dialog с runtime prompt + Settings fallback.

Pre-flight permission check **на уровне POST /rules** — out of scope Phase 1 (юзер увидит alert при следующем connect). Phase 2 UI editor добавит preflight на save.

## Тесты

- `test/models/custom_rule_test.dart`: 
  - JSON round-trip с / без wifi-полей
  - default empty при отсутствии в JSON (migration)
  - BSSID normalization (uppercase → lowercase)
- `test/builder/custom_rules_to_route_test.dart`:
  - `wifi_ssid` / `wifi_bssid` правильно эмитятся в sing-box JSON только при non-empty
  - инфраструктура остаётся первой (resolve/sniff/hijack-dns), wifi-rule после
  - комбинации: wifi + domain в одном rule → оба поля в JSON
- `test/parser/...`: если есть reverse parsing existing config'ов — поддержать чтение wifi-условий

## Out of scope (Phase 2 — UI)

- Editor-секция в `RuleEditScreen` с двумя chip-input'ами
- Кнопка «Use current Wi-Fi» — читает `WifiManager.connectionInfo` через MethodChannel; disabled с tooltip если permissions нет
- Pre-flight permission check при save rule с непустыми wifi-полями (показать существующий dialog)
- `CustomRulePreset` поддержка через vars-substitution `{{wifi_ssid_home}}` (если понадобится)

## Workflow для юзера после Phase 1

```
POST /rules?rebuild=true
{
  "name": "Home wifi → direct",
  "kind": "inline",
  "enabled": true,
  "outbound": "direct-out",
  "wifi_ssids": ["lexRouter"]
}
```

→ rule в `settings.custom_rules`, builder автоматически подставит `wifi_ssid` в sing-box config при rebuild. Persistent через рестарты, **без** `config_locked`.

## Acceptance

- [ ] Round-trip JSON tests passing для inline + srs
- [ ] Builder тесты подтверждают эмиссию `wifi_ssid` / `wifi_bssid` только при non-empty
- [ ] `POST /rules` с wifi-полями → правило в storage → rebuild → правило в active config
- [ ] Smoke на устройстве: создать rule через API, reconnect VPN, проверить что трафик при матче ssid идёт через объявленный outbound
- [ ] Без regressions для существующих non-wifi rules (миграционный test проходит на pre-§051 fixture'ах)
