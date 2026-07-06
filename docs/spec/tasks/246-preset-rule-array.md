# 246 — preset `rule` как массив route-правил (resolve ipv4_only для direct)

## Контекст / боль

На устройствах без глобального IPv6 (wlan0 с ULA-адресом `fde8:…`) трафик
RU-доменов через `direct-out` умирал: браузер получает AAAA (глобальная
`dns.strategy: prefer_ipv4` **сортирует, но не режет** AAAA), Happy Eyeballs
берёт IPv6 первым → `dial wlan0: connect: network is unreachable` →
`ERR_CONNECTION_RESET` на ya.ru. Диагностика: core-лог, все попытки Chrome шли
на `[2a02:6b8::…]:443 using outbound/direct[direct-out]`.

Глобальный `ipv4_only` чинит, но рубит IPv6 и в туннеле (туннель IPv6 умеет).
Нужен **ipv4_only только для direct-ветки**.

Канонический механизм sing-box 1.14 — route rule action `resolve` со
`strategy` (НЕ deprecated, в отличие от `strategy` в DNS-rule action):
не-терминальное правило, резолвит назначение до outbound.

## Решение

Пресет в `wizard_template.json` эмитит **пару** route-правил:
`resolve ipv4_only` (гейт: только когда `@outbound == direct-out`) + терминальный
route. Для этого `rule` пресета получает форму **массива**.

### Контракт шаблона (`selectable_rules[].rule` / `rules`)

- `rule: {…}` — legacy, один route-rule (как раньше);
- `rules: [{…}, {…}]` — **канонический ключ** массивной формы: упорядоченный
  список route-правил; порядок элементов сохраняется в `route.rules`;
  при обоих ключах побеждает `rules` (`json['rules'] ?? json['rule']`);
- элемент массива может быть `#if`-обёрткой (array-element form §120):
  false без `else` → элемент выпадает.

⚠ Грабля первого прогона: движок читал только `rule`, шаблон использовал
`rules` → пресет молча терял ВСЕ правила (ни warning, ни route.rules —
RU-трафик уезжал в `route.final`, т.е. в туннель). Тест
«канонический ключ "rules"» закрывает регрессию.

Применено в шаблоне к `ru-direct` и `ru-inside`. Условие resolve вынесено в
bool-var `force_ipv4` (default `true`) — явный рубильник в UI, а не хардкод:

```jsonc
"rules": [
  {"#if": {"and": ["@force_ipv4"],
           "value": {"rule_set": [...], "action": "resolve", "strategy": "ipv4_only"}}},
  {"rule_set": [...], "outbound": "@outbound"}
]
```

`geoip-ru` в resolve-правило не входит (матч по IP, резолвить нечего).
Галка off → resolve-элемент выпадает (array-element `#if` без `else`),
остаётся только терминальный route.

`server: "@dns_server"` в resolve-элементе ru-direct: сервер эмитится
**DNS-аспектом** пресета, а resolve-правило — route-аспектом. Выключенная
DNS-галка (или first-build до auto-discovery) → тег повисает → ядро валит
каждое RU-соединение лениво («DNS server not found»). Защита —
`healDanglingResolveServers` (§247): битый `server` снимается + warning,
резолв деградирует в DNS-роутинг.

**Двухслойность фикса (итог device-проверки).** Route-`resolve` в ядре
гейтится на `metadata.Destination.IsDomain()` (route.go actionResolve) —
IP-коннекты он НЕ переписывает. Chrome же коннектится по готовому
IPv6-адресу из своего DNS-ответа → route-слоя недостаточно. Точечный
sniff-override не работает: повторный sniff-action скипается
(«duplicate sniff skipped») до override-ветки. Поэтому:

- **слой 1 (главный)** — `dns_rule` пресета получает `strategy: ipv4_only`
  (map-spread `#if` по `@force_ipv4`): приложение не видит AAAA для
  RU-доменов вовсе → коннект IPv4. Поле `strategy` DNS-rule action —
  deprecated (удалят в 1.16; форк наш, миграция — например predefined-фильтр
  AAAA — отдельной таской к бампу). Работает только при включённой DNS-галке
  пресета (§121) — отражено в tooltip'е force_ipv4;
- **слой 2** — route-`resolve` (не-deprecated) кроет FQDN-destination
  (FakeIP, доменные коннекты, UDP-запросы с доменом).

### Семантика expansion (`preset_expand.dart`)

Терминология: элемент **промежуточный** (non-terminal), если
`action ∈ {resolve, sniff, route-options}`; иначе — **терминальный**
(route/reject/hijack-dns/`outbound`).

- substitute выполняется на **массиве целиком** (иначе array-element `#if`
  не сработает — Dropped-механика живёт в обходе List);
- элемент не-Map / без `outbound`+`action` после substitute → drop (silent,
  как legacy);
- **outbound-override** (`varsValues['outbound']`) и **reject→action
  backstop** применяются ТОЛЬКО к терминальным элементам (каждому);
  промежуточные не трогаются — их судьбу решает `#if` в шаблоне;
- **dangling-rule_set guard** (§011/§045/§219) — поэлементно: битый элемент
  дропается с warning, остальные живут;
- `PresetFragments.routingRule: Map?` → `routingRules: List<Map>`; порядок
  элементов = порядок в шаблоне.

### Файлы

| Файл | Изменение |
|---|---|
| `app/assets/wizard_template.json` | `ru-direct`/`ru-inside`: `rule` → массив `[resolve-#if, route]` (уже внесено) |
| `app/lib/models/parser_config.dart` | `SelectableRule.rule: Map` → `rules: List<Map>` (конструктор принимает `rule:` Map\|List, нормализует); getter `terminalRule` для UI fallback-chain |
| `app/lib/services/builder/preset_expand.dart` | `PresetFragments.routingRules`; цикл по элементам с per-element override/backstop/guard; `mergeFragments` addAll |
| `app/lib/services/builder/post_steps/custom_rules.dart` | `_applyPresetSingle`: `registry.addRule` для каждого из `routingRules` |
| `app/lib/screens/routing_screen/routing_screen_helpers.dart` | `presetOut`: `preset.rule[…]` → `preset.terminalRule[…]` |
| `app/lib/screens/routing_screen.dart` | докстринг fallback-chain: `preset.rule` → `preset.terminalRule` |
| `docs/TEMPLATE.md` | контракт `rule` Map\|List + пример |

### Тесты

- `preset_expand_test.dart`:
  - массив `[resolve, route]` → оба в `routingRules`, порядок сохранён;
  - `#if`-гейт: дефолт (`direct-out`) → 2 правила; override `vpn-1` →
    resolve выпал, у route `outbound: vpn-1`;
  - override `reject` на массиве → терминальный получает `action: reject`;
  - dangling rule_set в resolve-элементе → дропнут только он + warning;
  - legacy Map — регресс (существующие тесты).
- `parser_config`: `fromJson` c `rule:` Map / List / отсутствует;
  `terminalRule` выбирает терминальный элемент.
- e2e: `if_engine_test`/`vpn_mode_test`/`dns_servers_resolver_test` парсят
  реальный шаблон — до фикса модели падают на cast `json['rule'] as Map`.

## Верификация

`flutter analyze` (весь проект — CI гоняет test/ тоже) + `flutter test` +
device-check: ya.ru через direct открывается (dial на `5.255.255.242`),
IPv6-домен через туннель живёт (AAAA не порезан глобально).
