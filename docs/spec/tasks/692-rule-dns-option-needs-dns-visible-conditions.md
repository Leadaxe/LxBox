# 692 — DNS-опции правила только при условиях, видимых DNS-слою

| Поле | Значение |
|------|----------|
| Статус | Done (эмулятор не гоняли) |
| Дата начала | 2026-10-29 |
| Источник | лог владельца: `Stopped: … initialize dns router: validate dns rule[3]: Legacy Address Filter Fields in DNS rules is deprecated in sing-box 1.14.0 …`; решение владельца: «галка DNS правила должна исчезать, если нет нужных условий» |
| Связанные | §117 (DNS-опция правила, зеркало), §256 (Force IPv4), §683 (Answer = Fixed IP), §247 (resolve-гейт по домену), §246 (защита legacy `strategy`) |

## Проблема

VPN не стартует: ядро отвергает конфиг на инициализации DNS-роутера.
`dns.rules[3]` ссылается на rule_set, где нет ничего, кроме `ip_cidr`.

Ядро с 1.14.0 (upstream, коммит «Reject pure-IP rule-set references without
match_response», 30.08.2026; в lx.21 и lx.23 уже было) работает в двух
DNS-режимах. Старый режим: `ip_cidr`/`ip_is_private`/чисто-IP rule_set в
DNS-правиле матчат адреса ответа и дают предупреждение. Новый режим
включается, когда хоть одно DNS-правило несёт `query_type`, `ip_version`,
`match_response`, `response_*`, `evaluate`/`respond`, `race`,
`disable_optimistic_cache`, `speculative`. Наш шаблон несёт `query_type`
(FakeIP §228) и `ip_version: 6` (Force IPv4 ru-direct §253), поэтому режим
у всех пользователей новый. В нём ссылка DNS-правила на rule_set
«только IP» без `match_response` — ошибка старта
(`dns/router.go`, `validateLegacyDNSModeDisabledDefaultRule`:
`metadata.ContainsIPCIDRRule && !metadata.ContainsNonIPCIDRRule`).

LxBox такое правило даёт тремя путями:

1. Inline-правило, где из условий только `ip_cidr`, и включена DNS-опция
   (сервер, Force IPv4 или Fixed IP): headless-набор получается чисто IP,
   зеркало в `dns.rules` ссылается на него.
2. Правило `.srs` с DNS-опцией, где файл чисто адресный (geoip-набор).
3. DNS-правило `kind:srs` с вкладки DNS, указывающее на geoip-набор.

Гейт `dnsMirrorEligible` / `forceIpv4Eligible` (§117/§256) режет только
порты, протоколы и `network`; условие «есть что матчить на DNS-слое» он
не проверяет. Смысловая сторона: DNS-слой видит имя запроса, приложение,
источник, wifi и inbound; IP назначения он узнаёт только после ответа.
Зеркало для чисто IP-условия бессмысленно, а для resolve это уже учтено
(`resolveEligible` требует домен, §247).

## Решение

### Условия, видимые DNS-слою (inline)

Правило inline считается DNS-способным, если после гейта портов/протоколов
у него есть хоть одно из условий:

- домены: `domain`, `domain_suffix`, `domain_keyword`;
- приложения: `package_name`;
- источник: `source_ip_cidr`;
- wifi: `wifi_ssid`, `wifi_bssid`;
- `inbound` — только если список `ip_cidr` пуст.

Исключение с `inbound` — из устройства ядра: `inbound` лежит на самом
DNS-правиле, а не в rule_set; при `ip_cidr` + `inbound` набор всё равно
чисто IP, и ядро отвергает ссылку независимо от остальных полей правила.
Без `ip_cidr` зеркало идёт без rule_set, только с `inbound` — ядро это
принимает.

Чисто IP-правило (`ip_cidr` и/или routing-level `ip_is_private`,
`source_ip_is_private`, `protocol`, `network` без перечисленного выше) —
не DNS-способно: зеркало не строится, секция «DNS & Resolve» в редакторе
не показывается.

Правила `.srs` остаются DNS-способными всегда: содержимое файла не
разбирается, подсказка «Works only if the rule-set contains domains» уже
есть. Путь 2 и путь 3 этой задачей не закрываются (см. «Нерешённое»).

### Код

- `CustomRule.dnsLayerEligible` — новый предикат в `custom_rule.dart`;
  входит в `dnsMirrorEligible` и `forceIpv4Eligible` (через него и в
  `dnsFixedActive`). Сборка (`custom_rules.dart`), вкладка DNS
  (`dns_settings_tab.dart`), контроллер DNS и чип «DNS» получают новое
  поведение без правок: все они идут через эти предикаты.
- `CustomRuleEditController.dnsSectionVisible` — live-гейт по текущему
  состоянию формы, то же условие; `params_tab.dart` показывает
  `DnsResolveSection` только при нём. Для `.srs` — всегда.
- Существующие записи с чисто IP-условием и включённой DNS-опцией:
  поле `dns` в хранилище не трогается, зеркало просто не эмитится —
  конфиг владельца стартует. Если пользователь добавит домен, опция
  оживёт с прежними настройками.

## Риски и граничные случаи

- Пользователь, у которого «работало» зеркало с чисто IP-набором в
  старом режиме ядра (до появления в шаблоне `query_type`/`ip_version`),
  теряет его молча: в новом режиме оно и так валит старт.
- `package_name`-only правило остаётся DNS-способным: набор несёт
  не-IP item, ядро принимает.
- `.srs` с geoip по-прежнему валит старт при включённой DNS-опции.

## Проверка

- `app/test/services/builder/rule_dns_mirror_test.dart` — новые кейсы:
  `ip_cidr`-only + DNS/Force IPv4/Fixed IP → зеркало не эмитится;
  `ip_cidr` + `inbound` → не эмитится; `inbound`-only → эмитится без
  rule_set; `ip_cidr` + `package_name` → эмитится.
- На устройстве: не проверено.

## Нерешённое / follow-up

- `.srs` с чисто IP-содержимым под DNS-опцией (пути 2 и 3) — **не делаем,
  решение владельца 29.10.2026** («ничего не надо»). Рассмотренные варианты:
  флаги `ContainsIPCIDRRule`/`ContainsNonIPCIDRRule` от ядра через libbox в
  sidecar `<id>.meta.json`; свой разбор `.srs` в Dart; миграция ядра
  `evaluate` + `match_response`. Подсказка «Works only if the rule-set
  contains domains» остаётся единственной защитой.
- Снятие на сборке по образцу §246 для правил, пришедших мимо модели
  (raw JSON, импорт) — не делалось.
