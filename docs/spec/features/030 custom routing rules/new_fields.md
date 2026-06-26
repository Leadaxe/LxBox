# §030 — новые match-поля (`source_ip_cidr` + `inbound`) + headless-ревизия под 1.14

> **Дельта к [`spec.md`](spec.md).** Изначально — народ просит правила с
> source-полями и inbound'ом (§030 закрыла их как YAGNI). При проверке физики
> под ядро **`v1.14.0-lx.1-rc.9`** (`alpha.35`) выяснилось, что headless
> rule_set в 1.14 принимает БОЛЬШЕ полей, чем считал §030 (писался под 1.12) —
> поэтому в эту же переработку входит **перенос `wifi_*` в headless** и
> укладка `source_ip_cidr` в headless. Не отдельная фича: те же
> `CustomRuleInline`/`CustomRuleSrs`, тот же редактор, тот же билдер.

**Статус:** ✅ РЕАЛИЗОВАНО (решения ниже). 1261 тест зелёный; device-проверка
headless `wifi_ssid`/`source_ip_cidr` на 1.14 — pending (smoke на устройстве).
**Связано:** §119 (`mixed-in` inbound), §120 (`#if` inbounds),
§051 (wifi_* — здесь ревизуется), §117 (DNS-mirror).
**Ядро:** `v1.14.0-lx.1-rc.9`, сверено по исходникам
`option/rule_set.go` (`DefaultHeadlessRule`) + `option/rule.go` (`DefaultRule`).

---

## Почему это уже не YAGNI

§030 закрыла `source_ip_cidr/source_port` как «exotic, YAGNI», `process_name`
как «desktop-only». Контекст изменился:

1. **`inbound` стал осмысленным.** §119 даёт L×Box **два** inbound'а:
   `tun-in` (VpnService, всегда) и `mixed-in` (локальный SOCKS/HTTP, режимы
   `proxy`/`vpn_proxy`). До §119 inbound был один → поле = «всё». Теперь
   `inbound: ["mixed-in"]` отделяет трафик прокси-клиентов от VpnService.
2. **`source_ip_cidr`** — фильтр по источнику, симметричен `ip_cidr`.

`process_name` остаётся **за бортом** (Android матчит `package_name`).

---

## Факт-карта ядра 1.14 (сверено по исходникам)

`DefaultHeadlessRule` ([`option/rule_set.go:186-220`](../../../../../sing-box-lx/option/rule_set.go))
vs `DefaultRule` ([`option/rule.go`](../../../../../sing-box-lx/option/rule.go)):

| Поле | headless rule_set | обычный route-rule | DNS-rule (§117) |
|---|---|---|---|
| `domain*` / `ip_cidr` / `port` / `package_name` / `process_name` | ✅ | ✅ | ✅ |
| **`source_ip_cidr`** | ✅ `rule_set.go:193` | ✅ | ✅ `rule_dns.go:154` |
| **`source_port` / `source_port_range`** | ✅ `:195-196` | ✅ | ✅ |
| **`wifi_ssid` / `wifi_bssid`** | ✅ **`:207-208`** | ✅ | ✅ `rule_dns.go:297` |
| `network_type` / `network_is_*` | ✅ `:204-206` | ✅ | ✅ |
| **`source_ip_is_private`** | ❌ **НЕТ** | ✅ `rule.go:83` | ✅ |
| `ip_is_private` | ❌ НЕТ | ✅ `rule.go:85` | ✅ |
| **`inbound`** | ❌ **НЕТ** | ✅ `rule.go:69` | ✅ `rule_dns.go:87` |
| `protocol` (L7) | ❌ НЕТ | ✅ `rule.go:73` | ✅ |

**Вывод для билдера — куда что эмитить:**

| Поле правила | Эмиссия | Изменение vs §030/§051 |
|---|---|---|
| `source_ip_cidr` | **headless `match`** | НОВОЕ (OQ-1 = B) |
| `wifi_ssid` / `wifi_bssid` | **headless `match`** | **ИЗМЕНЕНО**: было route-level (§051, под 1.12) |
| `source_ip_is_private` | route-level | НОВОЕ |
| `inbound` | route-level | НОВОЕ |
| `ip_is_private` / `protocol` | route-level | без изменений |

> ⚠ Расщепление source-оси: `source_ip_cidr` → headless, но
> `source_ip_is_private` (bool) headless НЕ принимает → route-level (как
> `ip_is_private`). Это нормально — они AND-ятся через sing-box formula
> независимо от того, в rule_set поле или в route-rule.

---

## Модель — [`custom_rule.dart`](../../../../app/lib/models/custom_rule.dart)

Поля в `CustomRuleInline` **и** `CustomRuleSrs` (обе ветки несут доп-фильтры):

```dart
// §030/new_fields — source-ось.
List<String> sourceIpCidrs;     // ["192.168.1.0/24","10.0.0.5"] → headless match
bool sourceIpIsPrivate;         // → route-level (headless не принимает)

// §030/new_fields — inbound-ось. → route-level. Значения = ТЕГИ билдера.
List<String> inbounds;          // ["tun-in"] / ["mixed-in"]
```

1. Поля в обоих subclass'ах (default пусто/`false`).
2. Convenience-getters на базовом `CustomRule` (`_ => const []` / `false` для preset).
3. `toJson` (ключи `sourceIpCidrs`/`sourceIpIsPrivate`/`inbounds`, non-empty),
   `fromJson`, `copyWith`.
4. `summary` — `${sourceIpCidrs.length} src` / `${inbounds.length} in`.

**Backward-compat:** опциональны, старые JSON без ключей → пусто.

---

## Билдер — [`post_steps/custom_rules.dart`](../../../../app/lib/services/builder/post_steps/custom_rules.dart)

### 1. headless `match`-мапа `_applyInlineSingle` (~стр. 346-357)

Добавить в `match` (рядом с `package_name`) то, что 1.14 принимает в headless:

```dart
if (cr.sourceIpCidrs.isNotEmpty) match['source_ip_cidr'] = cr.sourceIpCidrs;
// §030/new_fields: wifi_* теперь в headless (1.14, rule_set.go:207-208) —
// ПЕРЕНОС с route-level (§051 был под 1.12). AND с остальным match.
if (cr.wifiSsids.isNotEmpty) match['wifi_ssid'] = cr.wifiSsids;
if (cr.wifiBssids.isNotEmpty) match['wifi_bssid'] = cr.wifiBssids;
```

### 2. route-level `_outboundToRoute` (~стр. 489)

- **Убрать** параметры `wifiSsids`/`wifiBssids` (переехали в `match`).
- **Добавить** `sourceIpIsPrivate` (bool) + `inbounds` (List):
  ```dart
  if (sourceIpIsPrivate) rule['source_ip_is_private'] = true;
  if (inbounds != null && inbounds.isNotEmpty) rule['inbound'] = inbounds;
  ```
- Callers (`_applyInlineSingle`/`_applySrsSingle`) перестают слать wifi в
  `_outboundToRoute`, начинают слать `sourceIpIsPrivate`/`inbounds`.

### 3. Пустой-match-гейт (~стр. 362-369)

Сейчас: «match пуст → skip если нет protocol/ip_is_private/wifi».
- wifi уходит из route-условия (теперь в match — если есть wifi, match НЕ пуст).
- Добавить route-only поля в гейт: правило «только `inbound`» или «только
  `source_ip_is_private`» должно эмитить route-rule без rule_set, не скипаться:
  ```dart
  if (cr.protocols.isEmpty && !cr.ipIsPrivate &&
      !cr.sourceIpIsPrivate && cr.inbounds.isEmpty) {
    return warnings;  // нечего эмитить
  }
  ```

### 4. SRS-ветка `_applySrsSingle`

srs не строит headless `match` (rule_set внешний) → его доп-фильтры **все**
идут route-level. Для srs `wifi_*` остаётся на route-level (там нет своего
match), + добавить `sourceIpCidrs`/`sourceIpIsPrivate`/`inbounds` route-level.
→ `_outboundToRoute` для srs принимает wifi обратно ⇒ **оставить wifi-параметры
в `_outboundToRoute` опциональными** (inline их не шлёт, srs шлёт). Не убираем
из сигнатуры — только inline перестаёт ими пользоваться.

### 5. DNS-mirror (§117) — `addDnsMirror` / srs-mirror

DNS-rule 1.14 принимает `source_ip_cidr`/`inbound`/`wifi_*` напрямую
(`rule_dns.go:87,154,297`). Mirror кладёт в body (как уже `wifi_*`/`package_name`):
```dart
if (cr.sourceIpCidrs.isNotEmpty) mirror['source_ip_cidr'] = cr.sourceIpCidrs;
if (cr.inbounds.isNotEmpty) mirror['inbound'] = cr.inbounds;
```
- `source_ip_is_private` в mirror — **[OQ-4 рек: да]** (DNS-rule принимает).
- inline-mirror шарит тот же headless rule_set (там уже wifi_*/source_ip_cidr) —
  доп-поля для DNS уже внутри rule_set, в body дублировать НЕ нужно (кроме
  route-only `inbound`/`source_ip_is_private`).

---

## UI — [`tabs/params_tab.dart`](../../../../app/lib/screens/custom_rule_edit/tabs/params_tab.dart) + секции

### INBOUND — раскрытие по клику + галочки (решение юзера)

Не висящие чекбоксы, а **раскрывающаяся секция**: свёрнуто — строка-заголовок
с summary; клик раскрывает галочки.

```
├ INBOUND  (any) ▸             ┤   ← свёрнуто
   ↓ tap
├ INBOUND  ▾                   ┤
│ [✓] TUN — system interface   │   → тег `tun-in`
│ [ ] Proxy interface          │   → тег `mixed-in`  (гейт vpn_mode)
```

- **Лейблы человекочитаемые, значение = тег билдера** (НЕ свободный ввод):
  ```dart
  const kInboundChoices = [
    (tag: 'tun-in',   label: 'TUN — system interface'),
    (tag: 'mixed-in', label: 'Proxy interface'),
  ];
  ```
- **Раскрытие** — `ExpansionTile` (или `InkWell`+`AnimatedCrossFade`, TBD по
  стилю редактора). Summary свёрнутого: `any` / `TUN` / `Proxy` / `TUN, Proxy`.
- Галочки — `CheckboxListTile` dense (как `ProtocolSection`).
- **[OQ-5 = РЕШЕНО: гейтить.]** `Proxy interface` (`mixed-in`) в списке только
  при `vpn_mode ∈ {proxy, vpn_proxy}` — гейт через
  [`VpnModeConfig.hasMixed`](../../../../app/lib/services/settings_storage/vpn_mode.dart)
  (`mode != 'vpn'`). В tun-only — только `TUN — system interface`.
  - Прокидка: `CustomRuleEditController` сейчас vpn_mode не знает — добавить
    (читает `_getVpnMode()` или `bool hasMixed` props'ом от screen'а, как
    `dnsServerTags`). `kInboundChoices` фильтруется: `mixed-in` включается
    только при `hasMixed == true`.
  - Стейл-выбор: сохранённый `inbounds:["mixed-in"]` при переключении на
    `vpn`-only — значение в модели остаётся (не теряем), билдер эмитит как
    есть → правило no-op (не fatal). Серый стейл-чип — TBD/низкий приоритет.

Новый файл `sections/inbound_section.dart`:
```dart
class InboundSection extends StatefulWidget {  // _expanded локально
  final Set<String> selected;                  // теги
  final List<({String tag, String label})> choices;  // отфильтровано по hasMixed
  final void Function(String tag, bool checked) onToggle;
}
```

### SOURCE — в `MatchSection`

Рядом с `IP CIDR` + `Private IP`:
```
│ Source IP CIDR [...]     │   chips, cidr-валидация (переисп. validators.dart)
│ [ ] Private source IP    │
```

### Контроллер — [`edit_controller.dart`](../../../../app/lib/screens/custom_rule_edit/edit_controller.dart)
По образцу `protocols`/`ipIsPrivate`:
- `TextEditingController sourceIpCidrCtrl`,
- `bool sourceIpIsPrivate` + `setSourceIpIsPrivate`,
- `Set<String> inbounds` + `toggleInbound(tag, checked)`,
- `bool hasMixed` (из `_getVpnMode`) для гейта,
- сборка/чтение в `_snapshot()` / из `widget.initial`.

**View-таб** подхватит автоматически (через `applyCustomRules`).

---

## Решения (бывшие OQ)

- **[OQ-1] ✅ B — headless** для `source_ip_cidr` (1.14 принимает; reuse в DNS-mirror).
- **[OQ-2] ✅ да** — `source_ip_is_private` берём (route-level, headless не принимает).
- **[OQ-3] нет** — `source_port`/`source_port_range` (ось готова, добавим по запросу).
- **[OQ-4] ✅ да** — `inbound`/`source_ip_cidr`/`source_ip_is_private` в DNS-mirror.
- **[OQ-5] ✅ гейт по vpn_mode** — `Proxy interface` только при `hasMixed`.
- **[OQ-6] ✅ да** — поля в обе ветки (inline + srs).

---

## Тесты — [`test/builder/custom_rules_test.dart`](../../../../app/test/builder/custom_rules_test.dart)

- inline `sourceIpCidrs=["10.0.0.0/8"]` → **headless `match.source_ip_cidr`**.
- inline `wifiSsids=["Home"]` → **headless `match.wifi_ssid`** (НЕ route-level
  больше — **обновить существующие §051-тесты**, они ждали route-level).
- inline `inbounds=["mixed-in"]` (пустой остальной match) → route-rule без
  rule_set с `inbound:["mixed-in"]` (НЕ skip — гейт).
- `sourceIpIsPrivate=true` → route-level `source_ip_is_private:true`.
- srs c source/inbound/wifi доп-фильтрами → route-level (нет своего match).
- DNS-mirror: inline с `source_ip_cidr`+`inbound` → dns-rule с `inbound`
  в body + source_ip_cidr внутри shared rule_set.
- toJson/fromJson round-trip + backward-compat.

---

## Обновление `spec.md` / §051 — ✅ СДЕЛАНО

1. **§030 spec.md «Семантика sing-box» / «Ключевые инварианты»:** обновлено —
   `wifi_*`/`source_ip_cidr` → headless (1.14); `protocol`/`ip_is_private`/
   `inbound`/`source_ip_is_private` → routing-rule level.
2. **§030 spec.md «Out of scope»:** source_ip_cidr/inbound вынесены в раздел
   «Реализовано после v1.4.0»; `source_port`/`process_name`/`source_geoip` остаются.
3. **§051 Builder pipeline:** добавлена пометка о переносе wifi_* → headless с 1.14.

## Затронутые файлы (реализация)

| Файл | Что |
|---|---|
| `app/lib/models/custom_rule.dart` | поля sourceIpCidrs/sourceIpIsPrivate/inbounds (inline+srs) + getters/toJson/fromJson/copyWith/summary |
| `app/lib/services/builder/post_steps/custom_rules.dart` | wifi/source_ip_cidr → headless match; source_ip_is_private/inbound → route; гейт; srs route-level; DNS-mirror |
| `app/lib/screens/custom_rule_edit/edit_controller.dart` | sourceIpCidrCtrl, sourceIpIsPrivate, inbounds, hasMixed (getVpnMode), мутаторы, snapshot |
| `app/lib/screens/custom_rule_edit/sections/inbound_section.dart` | НОВЫЙ — раскрытие+галочки, гейт mixed-in |
| `app/lib/screens/custom_rule_edit/sections/match_section.dart` | Source IP CIDR + Private source IP |
| `app/lib/screens/custom_rule_edit/tabs/params_tab.dart` | wiring MatchSection + InboundSection |
| `app/lib/services/debug/serializers/rules.dart`, `handlers/rules.dart` | source/inbound в GET/POST/PATCH /rules |
| `app/test/builder/custom_rules_test.dart`, `test/services/builder/rule_dns_mirror_test.dart` | wifi→headless + новые source/inbound тесты |

---

## Границы

- Ядро НЕ трогаем — все поля нативны в 1.14.
- `process_name` / `source_geoip` — вне scope.
- Перенос `wifi_*` route→headless: **поведение эквивалентно** (AND-семантика
  та же), но JSON-форма меняется → §051-тесты обновить, device-проверить что
  1.14 headless с `wifi_ssid` парсится (не fatal).
