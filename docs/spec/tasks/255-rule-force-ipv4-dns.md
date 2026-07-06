# §255 — `Force IPv4` у пользовательского правила: AAAA-глушилка на DNS-слое

> **СТАТУС: РЕАЛИЗОВАНО** (07.07.2026, НЕ device-verified). Продолжение §253:
> тот же двухслойный Force IPv4, но теперь доступный юзеру на его собственных
> правилах, а не только в пресете ru-direct.

## Задача

§253 вернул Force IPv4 на DNS-слой для **пресета** (ru-direct эмитит
`{ip_version: 6, action: predefined, rcode: NOERROR}` — гасит AAAA локально,
приложение чисто берёт A). Та же боль есть у пользовательских правил: юзер
хочет для своего матча (домен / приложение / source_ip) отрезать IPv6,
оставаясь на обычном роутинге. Отдельно от §247 route-`resolve`
(`strategy: ipv4_only` там уже есть) — это **DNS-слой**, второй слой той же
защиты, единственный работающий для приложений, которые резолвят сами.

## Решение (согласовано с владельцем)

Независимая галка **`Force IPv4 (drop AAAA)`** в секции **DNS** правила
(`DnsSection`), рядом с «Send DNS to dedicated server», но **ортогональная**:

| Аспект | Решение |
|---|---|
| Дом | Секция DNS правила (`sections/dns_section.dart`), не Action & Resolve — это DNS-действие |
| Зависимость от сервера | **Нет.** Глушилка `predefined` отвечает локально, серверу не нужна. Можно Force без dedicated-сервера, сервер без Force, оба вместе |
| Гейт доступности | **Нет port/protocol-фильтров** (тот же headless-DNS-гейт, что у dedicated-server: в момент DNS-запроса порт/протокол неизвестны). Домен / приложение (`package_name`) / source_ip — работает. Порты/протоколы → галка серая с пояснением |
| Матч без домена | Разрешён (кейс владельца: «глючному приложению v4»). Правило по `package_name` без доменов гасит AAAA для всех DNS-запросов этого приложения — грубо, но осознанно |
| Дефолт | **Выкл** (независимая галка на произвольном правиле; дефолт-вкл был бы сюрпризом) |
| Route-resolve (§247) | Не трогаем. Юзер собирает полный force сам: Force IPv4 (DNS) + resolve strategy ipv4_only (route) |

## Семантика ядра (проверено §253, sing-box-lx v1.14.0-lx.2)

- `ip_version` — MATCHER, матчит только A(4)/AAAA(6)-запросы; HTTPS type 65 /
  TXT → IPVersion=0, не матчатся (dns/router.go:550).
- `predefined` + `rcode: NOERROR` без `answer` = authoritative пустой ответ
  «домен есть, AAAA нет» → приложение берёт A. **НЕ reject** (REFUSED →
  drop после 50/30с → ломает fallback).
- `predefined` — serverless (server не нужен).

## Эмитируемое DNS-правило

Для правила с `dns.forceIpv4 == true` (и eligible) — второе DNS-mirror-тело
в `dns.rules`, БЕЗ `server`:

```json
{"rule_set": "<tag правила>", "ip_version": 6, "action": "predefined", "rcode": "NOERROR"}
```

Плюс DNS-безопасные AND-фильтры правила (`package_name` / `source_ip_cidr` /
`inbound` / `wifi_*`) — как у существующего `cr.dns`-mirror'а. `rule_set`
подставляется только когда у правила есть headless-набор (inline с доменами
или srs-tag); если матч только по `package_name`/source_ip — правило без
`rule_set`, матчит по этим полям.

## Взаимодействие с существующим `cr.dns`-mirror'ом

Правило может дать **до двух** rule-mirror'ов:

1. `dns.enabled` (Send to dedicated server) → `{rule_set|match, server}` —
   как сейчас (§117).
2. `dns.forceIpv4` → `{rule_set|match, ip_version: 6, action: predefined,
   rcode: NOERROR}` — **serverless**, новый (§255).

Оба независимы. **Порядок:** AAAA-глушилка эмитится ПЕРЕД server-mirror'ом
(симметрия §253: гейт AAAA первым, маршрут вторым; иначе server-mirror
без ip_version перехватит AAAA-запрос и уведёт на сервер до глушилки).

## Гейт эмиссии — новый `DnsMirrorEntry.serverless`

Проблема: текущая эмиссия rule-mirror'а (dns_rules.dart:143-144) БЕЗУСЛОВНО
подставляет `server: <serverTag>` и тихо пропускает mirror, если сервер не
дожил до `dns.servers`. serverless-глушилка не должна ни получать server,
ни резаться по его отсутствию.

Решение: флаг `bool serverless` на `DnsMirrorEntry` (default false). При
эмиссии (`emitMirrorGroup`):
- `serverless: true` → `outRules.add(body)` как есть (server не подставляется,
  gate по `emittedServerTags` пропускается);
- `serverless: false` → прежнее поведение (подстановка + gate).

Симметрично preset-ветке §253, которая уже эмитит serverless-тела
(там разделение по `presetId != null`; для rule-источника нужен явный флаг).

## Модель (`app/lib/models/custom_rule.dart`)

`RuleDns` — добавить поле (образец существующих bool в RuleResolve):

```dart
class RuleDns {
  const RuleDns({this.enabled = false, this.serverTag = '', this.forceIpv4 = false});
  final bool enabled;
  final String serverTag;
  final bool forceIpv4;    // §255 — AAAA-глушилка (независима от enabled/serverTag)
  // toJson: if (forceIpv4) 'forceIpv4': true
  // fromJson: forceIpv4: j['forceIpv4'] == true
  // copyWith: forceIpv4 параметр
}
```

Геттеры на `CustomRule` (рядом с `dnsMirrorEligible`/`dnsMirrorActive`):

```dart
/// §255 — Force IPv4 (AAAA-глушилка) применима: правило DNS-mirror-способно
/// по headless-гейту (нет port/protocol), НЕ требует serverTag.
bool get forceIpv4Eligible =>
    enabled && ports.isEmpty && portRanges.isEmpty && protocols.isEmpty;

/// §255 — Force IPv4 активна: eligible И галка dns.forceIpv4 включена.
bool get forceIpv4Active => forceIpv4Eligible && (dns?.forceIpv4 ?? false);
```

Отличие от `dnsMirrorEligible`: у Force IPv4 НЕТ требования
`serverTag.isNotEmpty` (глушилка серверу не нужна).

## Билдер (`custom_rules.dart`)

- `DnsMirrorEntry`: поле `bool serverless` (default false).
- `_applyInlineSingle` / `_applySrsSingle`: при `cr.forceIpv4Active` — эмитить
  serverless-mirror ПЕРЕД server-mirror'ом (тот же rule_set-tag/AND-поля,
  что у server-mirror; body = `{ip_version: 6, action: predefined, rcode:
  NOERROR}` + фильтры). `serverTag: ''`, `serverless: true`.
- `dns_rules.dart` `emitMirrorGroup`: rule-ветка — `if (m.serverless) outRules.add(m.body)` без подстановки/гейта; иначе прежнее.

## UI

### `sections/dns_section.dart`
Второй `CheckboxListTile` «Force IPv4 (drop AAAA)» под dedicated-server-блоком,
**независим** от `enabled`:
- `value: dns?.forceIpv4 ?? false`, `onChanged: gateBlocked ? null : onForceIpv4Changed`;
- подпись-хинт: «Answer AAAA queries locally so matched traffic uses IPv4.
  No DNS server required.»;
- при `gateBlocked` (port/protocol) — серый + существующее пояснение
  распространяется на обе галки.

### `edit_controller.dart`
- `setForceIpv4(bool v)`: `_dns = (_dns ?? const RuleDns()).copyWith(forceIpv4: v)`;
  notify. Важно: `RuleDns` может быть только из-за forceIpv4 (enabled=false,
  serverTag='') — snapshot должен сохранять такой dns (не занулять по
  `!enabled`).
- Проверить `snapshot()`/persist: `dns` пишется когда `enabled || forceIpv4`.

### `params_tab.dart`
Проброс `forceIpv4: c.dns?.forceIpv4`, `onForceIpv4Changed: c.setForceIpv4`
в `DnsSection`.

### Список
Чип «DNS» (§231) зажигается и при `forceIpv4Active` — вычисление
`touchesDns` в `routing_screen.dart` (`dnsMirrorActive || forceIpv4Active`);
сам `custom_rule_tile.dart` только рисует по флагу (отдельный маркер не
вводим — Force IPv4 = DNS-аспект, чипа «DNS» достаточно).

## Debug API (`serializers/rules.dart`)
У inline/srs добавить `force_ipv4: cr.dns?.forceIpv4 == true` (симметрия
с `dns`/`resolve`-полями).

## Файлы

| Файл | Изменение |
|---|---|
| `models/custom_rule.dart` | `RuleDns.forceIpv4` + `forceIpv4Eligible`/`forceIpv4Active` |
| `services/builder/post_steps/custom_rules.dart` | `DnsMirrorEntry.serverless` + эмиссия serverless-mirror в inline/srs |
| `services/builder/post_steps/dns_rules.dart` | `emitMirrorGroup`: serverless-ветка без server-подстановки |
| `screens/custom_rule_edit/sections/dns_section.dart` | вторая галка |
| `screens/custom_rule_edit/edit_controller.dart` | `setForceIpv4` + snapshot dns при forceIpv4-only |
| `screens/custom_rule_edit/tabs/params_tab.dart` | проброс |
| `screens/routing_screen.dart` | `touchesDns = dnsMirrorActive \|\| forceIpv4Active` |
| `services/debug/serializers/rules.dart` | `force_ipv4` (read) |
| `services/debug/handlers/rules.dart` | `_fieldRuleDns` read/write симметрия: `force_ipv4` + `enabled`/`server_tag` опциональны |
| `docs/STORAGE.md`, `docs/api/debug-api-reference.md` | `dns.forceIpv4` в схемах |
| тесты | модель (гейты, toJson/fromJson), билдер (serverless-mirror, порядок, гейт port/protocol, без сервера), сериализатор |

## Что НЕ делаем

- Не трогаем пресеты (§253) и route-resolve (§247).
- Не привязываем к dedicated-серверу (владелец: независимая галка).
- Не форсим при port/protocol-фильтрах (физика DNS-слоя).
- Storage-миграция не нужна (новое опциональное bool в RuleDns; старые
  записи → false).

## Связанные

- §253 (Force IPv4 на DNS-слое у пресета — источник механики + JSON),
  §247 (resolve-action правила — route-слой Force IPv4), §117 (mirror-группа
  DNS-правил), §231 (DNS-чип в списке).
