# 045 — `ru-direct` preset: GeoIP IP-range fallback layer

| Поле | Значение |
|------|----------|
| Статус | Released (v1.7.0) |
| Дата | 2026-05-08 |
| Связанные spec'ы | [`033 preset bundles`](../features/033%20preset%20bundles/spec.md) — расширяет; [`011 local ruleset cache`](../features/011%20local%20ruleset%20cache/spec.md) — переиспользует .srs кэш; [`030 custom routing rules`](../features/030%20custom%20routing%20rules/spec.md) — routing rule shape |
| Затронутые файлы | `app/assets/wizard_template.json`, `app/lib/services/builder/preset_expand.dart`, `app/lib/screens/routing_screen.dart`, `app/lib/screens/custom_rule_edit_screen.dart`, `app/lib/models/custom_rule.dart`, `app/test/services/builder/preset_expand_test.dart` |

## Цель

Добавить четвёртый routing-слой к существующим в `ru-direct` preset'е:

1. **Domain match** (`ru-domains` rule_set, suffix `.ru`/`.su`/IDN) — уже есть.
2. **Service-list** (`ru-inside` rule_set отдельным preset'ом) — уже есть.
3. **Package-name** (`Ru Apps` inline rule с `package_name`) — уже есть в template.
4. **GeoIP IP-range** — **новый**, ловит случаи где первые три промахнулись.

Это решает класс багов вида «российский сервис не открывается через VPN», когда:
- Sniff не успел извлечь SNI (timeout 1s, короткое TCP, QUIC)
- TLS 1.3 ECH (encrypted SNI)
- TLS session resumption (нет ClientHello)
- CDN-домен на не-`.ru` TLD (e.g. `*.trbcdn.net` для Тинькоффа, `*.cdn-tinkoff.ru → CNAME *.edgecdn.ru → A 193.17.93.x` где CNAME-target имеет `.ru`, но реальный sniffed SNI клиента — другой)
- Package-name detection не успевает / отсутствует (WebView subprocess, isolated process, short-lived)

GeoIP-rule матчится по **destination IP**, который видим на L3 всегда — никаких failure modes.

## Контекст: live-инцидент 2026-05-08

Юзер: «Tinkoff не открывается через VPN». Снапшот в `/tmp/lxbox-debug-2026-05-08-tinkoff/`.

Анализ:
- DNS работает: `id.tbank.ru → 178.130.128.26`, `cfg.t-bank-app.ru → 178.130.128.41`, `cdn.t-bank-app.ru → CNAME edgecdn.ru → 193.17.93.194`, `certs.t-bank-app.ru → CNAME trbcdn.net → 81.222.127.186` — все за 16-34ms.
- TCP к `178.130.128.x` (RU API через `ru-domains → direct`) — установились, дошли до LAST-ACK / FIN-WAIT-1.
- TCP к `81.222.127.*` / `193.17.93.*` (CDN) — **0 сокетов** (приложение не дошло до них или их routing уехал в `route.final = vpn-1 = 🇵🇱Польша` через зарубежный VLESS-выход → Тинькофф backend GeoIP-блок).
- App-logs: `raw.githubusercontent.com → No route to host`, `api.github.com → Connection refused`. UpdateChecker идёт через `vpn-1` selector → Польша не работала.

«Ru Apps» rule (package_name `ru.tinkoff.investing`) **должен был** покрыть весь трафик от приложения, но пропустил CDN-запросы. Гипотезы (см. сегодняшнее обсуждение): WebView/isolated subprocess с другим UID, либо короткие connections где process detection lags.

GeoIP-rule снимает все три источника промахов разом.

## Решение

### Schema change в `wizard_template.json` — `ru-direct` preset

Добавить второй rule_set + новый bool var + `rule.rule_set` стать массивом.

```jsonc
{
  "preset_id":   "ru-direct",
  "label":       "Russian domains & IPs direct",                              // CHANGED
  "description": "Route Russian TLDs (.ru/.su/IDN) and Russian IP ranges directly. GeoIP layer catches CDN/QUIC/ECH/short-TLS cases where domain detection fails.",  // CHANGED
  "default":     true,
  "vars": [
    {"name": "outbound",     "type": "outbound",    "default_value": "direct-out", ...},
    {"name": "dns_server",   "type": "dns_servers", "default_value": "yandex_udp", ...},
    {"name": "dns_ip",       "type": "enum",        "default_value": "77.88.8.8",  ...},
    {                                                                          // NEW
      "name":          "geoip_enabled",
      "type":          "bool",
      "default_value": "true",
      "title":         "GeoIP IP-range fallback",
      "tooltip":       "Route Russian-AS IPs directly even when domain match fails (CDN/QUIC/ECH). Auto-downloads geoip-ru.srs (~150 KB) on first use."
    }
  ],
  "rule_set": [
    {"tag": "ru-domains", "type": "inline", "rules": [{"domain_suffix": ["ru","su",...]}]},
    {                                                                          // NEW
      "tag":             "geoip-ru",
      "enabled":         "@geoip_enabled",
      "type":            "remote",
      "format":          "binary",
      "url":             "https://raw.githubusercontent.com/runetfreedom/russia-v2ray-rules-dat/release/sing-box/rule-set-geoip/geoip-ru.srs",
      "update_interval": "168h"
    }
  ],
  "dns_rule": {"rule_set": "ru-domains", "server": "@dns_server"},              // unchanged — DNS routing только по domain
  "rule": {
    "rule_set": ["ru-domains", "geoip-ru"],                                    // CHANGED: array (sing-box OR-семантика)
    "outbound": "@outbound"
  },
  "dns_servers": [...]                                                          // unchanged
}
```

### Code change в `preset_expand.dart` — два мини-фикса

#### 1. `enabled: "@var"` гейтинг для rule_set entries (новая convention)

Convention: если `rule_set[i].enabled` присутствует — это или **string-substitution** (`"@varname"`) или **bool literal**. Если резолвится к `false` — фрагмент пропускается (не попадает в `expandedRuleSets`).

В loop по `preset.ruleSets`, перед текущей логикой:

```dart
final enabledRaw = rs['enabled'];
if (enabledRaw is String) {
  final substituted = _substitute(enabledRaw, varsMap);
  if (substituted is! String || substituted.toLowerCase() != 'true') continue;
} else if (enabledRaw is bool && !enabledRaw) {
  continue;
}
// remove перед добавлением в expandedRuleSets — sing-box не знает поля enabled на rule_set
final copy = _deepCopy(rs);
final result = _substitute(copy, varsMap);
if (result is Map<String, dynamic>) {
  result.remove('enabled');
}
// ...existing logic (tag/type validation, remote→local resolve)...
```

`enabled` отсутствует → always-on (default behavior, не ломает existing 5 preset'ов).

#### 2. Dangling-guard расширить на `List<String>` (для array `rule.rule_set`)

Текущий код (строки 199-219) проверяет `String` форму. Расширить:

```dart
final refTag = result['rule_set'];
final expandedTags = {for (final rs in expandedRuleSets) rs['tag'] as String};

if (refTag is String && refTag.isNotEmpty) {
  if (!expandedTags.contains(refTag)) {
    warnings.add('preset "${preset.presetId}": routing rule skipped — references missing rule_set "$refTag" (download SRS first)');
  } else {
    routingRule = result;
  }
} else if (refTag is List) {
  final present = refTag.whereType<String>().where(expandedTags.contains).toList();
  if (present.isEmpty) {
    warnings.add('preset "${preset.presetId}": routing rule skipped — none of [${refTag.join(", ")}] available in expanded rule_sets');
  } else {
    // Один остался → даунгрейд до single string (sing-box принимает оба формата, но идиоматичнее)
    result['rule_set'] = present.length == 1 ? present.first : present;
    routingRule = result;
  }
} else {
  routingRule = result;
}
```

Behaviour:

| `rule_set` shape | `expandedRuleSets` | После guard | Sing-box config |
|---|---|---|---|
| `"ru-domains"` | `[ru-domains]` | string `"ru-domains"` | OK |
| `"ru-domains"` | `[]` (skipped) | rule dropped + warning | OK |
| `["ru-domains","geoip-ru"]` | `[ru-domains, geoip-ru]` | array `["ru-domains","geoip-ru"]` | OR-match |
| `["ru-domains","geoip-ru"]` | `[ru-domains]` (geoip-ru skipped из-за missing .srs или disabled var) | string `"ru-domains"` (downgrade) | OK |
| `["ru-domains","geoip-ru"]` | `[]` | rule dropped + warning | OK |

## Decisions

### Почему extension существующего `ru-direct`, а не новый отдельный preset

- **Один toggle в Routing UI** вместо двух (concise UX).
- **Семантически связано**: «Russian destinations direct» — domain + IP — единая концепция.
- **Default true работает на новых установках** out-of-the-box.
- Минус: расширение требует code change в expand_preset (два мини-фикса). Vs новый preset = только template change.

Trade-off оправдан: code change мелкий и **полезный сам по себе** (`enabled: "@var"` convention переиспользуется на rule_set/dns_rule/dns_servers в будущем; array-form `rule.rule_set` — стандартный sing-box syntax).

### Почему `enabled: "@var"` convention, а не `@if`-мета-директива

- **Симметрия со storage**: DNS-servers / DNS-rules уже имеют `enabled` поле в storage refs (см. STORAGE.md §043+§044). Переносим аналогию в template-side.
- **Без нового syntax**: `enabled` — обычное поле, substitution standard. Никаких новых кодов.
- **Расширяема**: тот же паттерн работает на `dns_rule.enabled`, `dns_servers[i].enabled`, `rule.enabled` (для будущих use-cases).

### Почему `download_detour` НЕ указан

В существующих preset'ах (`ads-all`, `ru-inside`) тоже не указан. Sing-box по дефолту качает через `route.final` — это нужно потому что `raw.githubusercontent.com` блокируется DPI в РФ через `direct-out`, но достижим через VPN-выход. Если юзер на VPN — скачается. Если VPN выключен — пойдёт через что задано в final.

### Почему `update_interval: "168h"` (неделя)

`runetfreedom/russia-v2ray-rules-dat` обновляется ежедневно, но GeoIP allocations на уровне RIPE/RIR меняются медленно. Неделя — баланс между свежестью и нагрузкой на github.

## Migration

Zero migration. Backward-compat:

- **Existing user** на v1.6.1 c включённым `ru-direct` preset → его `custom_rules[].varsValues` не содержит `geoip_enabled` → applies default value `"true"` → новый rule_set автоматически активируется.
- **Existing user** который **выключил** `ru-direct` целиком → ничего не меняется (preset disabled).
- **Existing user** с custom override `outbound` (например, vpn-2 для роутинга РФ через российскую VPN-ноду) → override применяется к **обоим** rule'ам (domain + geoip), что желаемо.
- **Edge case**: юзер в edge case 1 (РФ-VPN-нода с российским IP, не хочет geoip-роутить через эту ноду) — выключит switch `geoip_enabled` в Routing UI.

`varsValues['geoip_enabled']` персистится в `lxbox_settings.json.custom_rules[].varsValues` через standard preset-vars механизм. Никаких миграций storage не требуется.

## Edge cases

| Сценарий | Поведение |
|---|---|
| Свежая установка, `geoip-ru.srs` ещё не скачан | `srsPaths['geoip-ru']` пуст → фрагмент `geoip-ru` пропускается с warning, dangling-guard даунгрейдит rule до `"ru-domains"`. Domain-routing работает как в v1.6.1. После первого `RuleSetDownloader` tick — фрагмент активируется на следующем rebuild. |
| Internet режется DPI (github недоступен через `route.final`) | То же — .srs не скачивается, domain-routing продолжает работать. Юзер видит warning в Debug log. |
| Юзер toggle'ит `geoip_enabled` off | `enabled: "@var"` substitutes к `"false"` → фрагмент пропускается → даунгрейд до single `"ru-domains"` rule. Behavior идентичен v1.6.1. |
| Юзер toggle'ит `geoip_enabled` off, потом on | На rebuild фрагмент возвращается. .srs уже в кэше после первого включения. |
| Edge case: юзер удалил cached .srs вручную через filesystem | `RuleSetDownloader` не видит cache → ставит в queue download → следующий rebuild с downloaded .srs активирует. |

## UI follow-up fixes (выявлено на smoke-тесте 2026-05-08)

### 1. `bool` var не рендерился в preset detail screen

`_buildPresetVarWidget` (`custom_rule_edit_screen.dart`) поддерживал только `outbound`/`dns_servers`/`enum` — для `bool` падал в default case с текстом `(unsupported var type: bool)`. Юзер не мог выключить новый toggle.

**Fix**: добавлен `case 'bool'` с `Switch` widget. Storage convention — string'ом `"true"/"false"` (как требует substitution в `expand_preset.dart`).

### 2. RoutingScreen UI guard скачивал ВСЕ remote rule_set'ы, игнорируя `enabled: "@var"`

`_remoteRuleSetsOf(preset)` итерировал по всем remote rule_set'ам preset'а независимо от их `enabled` поля. Поэтому `_presetNeedsDownload` возвращал `true` даже когда юзер выключал toggle (если .srs не скачан) → switch блокировался, правило вообще нельзя было активировать без интернета.

**Fix**: `_remoteRuleSetsOf` принимает опциональный `CustomRulePreset rule` параметр; если передан — учитывает `enabled: "@var"` гейтинг через новый helper `_isRuleSetEnabled`. Все callsites где есть rule в контексте — теперь передают rule. Cleanup-callsites (delete-on-rule-removed) намеренно вызывают без rule — clear всех cached files preset'а, чтобы орфаны не зависали.

### 3. Subtitle preset rule дублировал title

`_ruleSubtitle` в `routing_screen.dart` строил `<preset.label> · <vars> — tap to edit`. Но `preset.label` — это и есть `rule.name` (snapshot template-label'а), который и так в title. Плюс 🔒 иконка визуально сигнализирует "это preset" — дублирование text'а.

**Fix**: убран `preset.label` из `_ruleSubtitle`. Показываются только non-default var-значения; если их нет — просто `Tap to edit`.

Параллельный fix — `CustomRulePreset.summary` (`models/custom_rule.dart`) больше не содержит `preset: <id>` префикс (был такой fallback path; сейчас `_ruleSubtitle` имеет приоритет, но summary тоже почистили для consistency).

### 4. Back-dialog в preset editor имел только 2 опции (Keep / Discard)

Юзер мог потерять unsaved changes — без явного Save в самом dialog. Добавлена 3-я кнопка **Save**. Все три — `TextButton` (не FilledButton, чтобы вмещались в строку на phone width); Save выделен `cs.primary` цветом и bold weight'ом.

### 5. `ru-direct` label/description без слова "direct"

Изначально новый label был `"Russian domains & IPs direct"`. Но юзер может выбрать `vpn-2` (РФ-VPN-нода) как outbound — тогда трафик не direct, а через VPN. "direct" в названии вводит в заблуждение.

**Final**: `label: "Russian domains & IPs"`, `description: "Route Russian TLDs (.ru/.su/IDN) and Russian IP ranges directly."` (description оставляет "directly" как описание дефолтного outbound'а).

### 6. URL в template — `rule-set-geoip/`, не `rule-set-ip/`

Изначальный URL `runetfreedom/.../rule-set-ip/geoip-ru.srs` → 404. Правильный путь — `rule-set-geoip/geoip-ru.srs`. Параллельно поправлено.

## Acceptance criteria

- [ ] Template содержит расширенный `ru-direct` preset с 4 vars и 2 rule_set entries.
- [ ] `expandPreset` поддерживает `enabled: "@varname"` гейтинг для rule_set, фрагмент пропускается при `false`.
- [ ] `expandPreset` поддерживает `List<String>` форму `routing_rule.rule_set`, даунгрейдит до single string при одном expanded tag'е, dropps rule + warning при empty filtered list.
- [ ] Existing 5 preset'ов проходят все existing тесты (no regressions).
- [ ] Новые тесты: 4 case'а — geoip on+downloaded / on+not-downloaded / off+downloaded / off+not-downloaded.
- [ ] `flutter analyze` чистый, `flutter test` зелёный.
- [ ] Smoke-тест на телефоне: после install и toggle preset'а — Tinkoff CDN-запросы идут через `direct-out`, видно в `core_logs` rule_set: geoip-ru match.

## План имплементации

1. Эта спека (✓)
2. `wizard_template.json` — расширение `ru-direct`
3. `preset_expand.dart` — `enabled: "@var"` гейтинг + List dangling-guard
4. `preset_expand_test.dart` — 4 новых test case'а
5. `pubspec.yaml` — bump build number (1.6.1+16 → 1.6.1+17, локал-тест)
6. `flutter analyze && flutter test`
7. `scripts/build-local-apk.sh` + `scripts/install-apk.sh` → юзер тестирует
8. После подтверждения — release flow для v1.6.2 (CHANGELOG, RELEASE_NOTES, docs/releases/v1.6.2.md, tag, CI publishes 4 APK).
