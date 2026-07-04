# §240 — фильтр по сети `network` (tcp/udp/icmp) + попап NETWORK & PROTOCOL

> **СТАТУС: РЕАЛИЗАЦИЯ.** Чисто клиентская обвязка — ядро не трогаем
> (`network` в route-rule — стандартный sing-box, есть из коробки).
> GitHub issue #26.

## Проблема

Правила маршрутизации умеют матчить по L7-протоколу (`protocol`: tls/quic/
http/…), но НЕ по транспортному уровню L4 — нельзя выразить «весь UDP», «весь
TCP», «ICMP». Типичные рецепты пользователей недостижимы:

- UDP direct / block QUIC (HTTP/3 over UDP), TCP через прокси;
- ICMP (ping / traceroute) напрямую.

sing-box поддерживает поле `network` в route-rule из коробки. По документации
допустимы **ровно три** значения: `tcp`, `udp`, `icmp`. Отдельного
`ip_protocol` нет; `icmpv6` в `network` тоже нет (проверено по
https://sing-box.sagernet.org/configuration/route/rule/).

## Решение

Новое match-поле `network: List<String>` на `CustomRuleInline` и `CustomRuleSrs`
— **полностью симметрично существующему `protocols`** (routing-rule level, AND
с остальным правилом, OR внутри списка). Значения из закрытого набора
`kKnownNetworks = ['tcp', 'udp', 'icmp']`.

UI: секция PROTOCOL (простыня из ~10 `CheckboxListTile`) заменяется на
компактную секцию **NETWORK & PROTOCOL**:

- **Свёрнутый вид** в форме правила: заголовок + до двух строк выбранных
  значений в виде чипов — строка **Network** и строка **Protocol** — плюс
  кнопка **Edit**, открывающая попап. Пусто → строка-заглушка.
- **Попап** (bottom sheet) с двумя секциями чипов:
  - **Network** — `tcp`, `udp`, `icmp` (новое поле `network`);
  - **Protocol** — существующий L7-набор `kKnownProtocols`.
  Тап по чипу = toggle (live). Clear all / Done.

### Семантика в конфиге (билдер)

`network` эмитится в `_outboundToRoute` точно как `protocols` — новый
опциональный параметр, кладётся `if non-empty` как `rule['network'] = network`.
Между `network` и `protocol` — AND (стандарт sing-box); внутри `network` —
OR (`["tcp","udp"]` = tcp или udp).

Три call-site (`_applyInlineSingle` × 2 — с match и без, `_applySrsSingle`)
прокидывают `network: cr.network`. В inline-ветке «match пуст» условие раннего
skip расширяется: правило не пустое, если задан `network` (сейчас гейт смотрит
только `protocols`/`ipIsPrivate`/`sourceIpIsPrivate`/`inbounds`).

### DNS-mirror гейт

`network` — headless-неproductible поле (как `protocols`): в момент DNS-запроса
транспорт неизвестен. Поэтому `dnsMirrorEligible` и `dnsGateBlocked`
расширяются на `network.isEmpty` — симметрично `protocols`. DNS-follow
недоступен при заданном `network`.

## Модель данных

`custom_rule.dart`:

- `const kKnownNetworks = ['tcp', 'udp', 'icmp'];`
- `List<String> get network` на базовом `CustomRule` (switch inline/srs → поле,
  иначе `const []`) — по образцу геттера `protocols`.
- Поле `network` в `CustomRuleInline` и `CustomRuleSrs`: конструктор,
  `@override`, `toJson` (`if (network.isNotEmpty)`), `fromJson` (`_stringList`),
  `copyWith`.
- `summary`: добавить `if (network.isNotEmpty) parts.add('${network.length} net')`.

## UI

- Новый виджет `NetworkProtocolSection` (заменяет `ProtocolSection` в
  `params_tab.dart` для inline/srs). Свёрнутый вид + кнопка Edit.
- Новый попап `NetworkProtocolSheet` (bottom sheet, две секции чипов).
- Контроллер `edit_controller.dart`: поле `_network`, геттер `network`,
  `toggleNetwork(String, bool)` (по образцу `toggleProtocol`), инициализация
  `_network = r.network.toSet()`, эмиссия `network: _network.toList()..sort()`
  в inline/srs ветках `snapshot()`, расширение `dnsGateBlocked` и
  `hasAnyMatch` на `_network`.

Строки UI — только английские (label «NETWORK & PROTOCOL», «Network»,
«Protocol», «Edit», «Clear all», «Done», хинт про AND). Без §-номеров в
видимых строках.

## Тесты

- `builder/custom_rules_test.dart`: inline и srs эмитят `network` в route-rule;
  AND с `protocol`; icmp; пустой `network` не эмитит ключ; «только network»
  (match пуст) даёт routing-rule без rule_set.
- `models/custom_rule` round-trip: `network` в toJson/fromJson/copyWith.
- DNS-mirror гейт: заданный `network` блокирует mirror (как `protocols`).

## Не входит

- `ip_version` (4/6) — отдельное поле, юзером не запрошено.
- Валидация «icmp + port/protocol бессмысленны» — деградирует само (правило не
  сматчит), жёсткий гейт не городим; максимум мягкий хинт (отложено).
