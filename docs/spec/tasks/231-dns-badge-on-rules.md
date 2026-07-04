# §231 — чип «DNS» на правилах, затрагивающих DNS

> **СТАТУС: РЕАЛИЗАЦИЯ.** Чисто UI (routing_screen + custom_rule_tile +
> preset_params_tab) + один геттер модели. Данные уже есть.

## Проблема (фидбэк 4PDA, #730)

В списке Routing Rules не видно, что правило/пресет **затрагивает
DNS-настройки** (вносит DNS-сервер и/или DNS-правило). У FakeIP, ru-direct и
user-правил с DNS-mirror это неочевидно — глядя на строку, нет напоминания, что
в DNS Settings есть связанные сущности. В DNS Rules всё ясно, а в Routing Rules
— нет.

## Решение

Визуальный **индикатор-чип «DNS»** (иконка `dns_outlined` + текст) на правилах
с активным DNS-аспектом. Два места:

1. **Список правил** — чип рядом с именем (перед ☁-кнопкой/outbound-пикером).
2. **Редактор пресета** — чип в баннере «Based on preset».

(inline/srs правила в редакторе уже имеют выделенную `DnsSection` — там чип
избыточен.)

## Предикат «трогает DNS»

- **Пресет** — новый геттер `SelectableRule.touchesDns = dnsRule != null ||
  dnsServers.isNotEmpty` (тот же split, что в debug-сериализаторе
  `has_dns_rule`/`dns_servers_count` и в гейте билдера `p.dnsRule != null`).
- **User inline/srs** — существующий `CustomRule.dnsMirrorActive` (то, на что
  РЕАЛЬНО гейтится эмиссия DNS-mirror в билдере). НЕ сырой `dns?.enabled`: при
  заданных ports/protocols mirror не эмитится (headless-гейт), и сырой флаг
  над-репортил бы. Чип = «правило реально вносит DNS в конфиг сейчас».
- `CustomRulePreset`/`CustomRuleJson` без `dns`-поля → предикат через пресет /
  false.

**Семантика:** чип только когда DNS-аспект **активен** (выключенный DNS ничего
в конфиг не вносит → чипа нет; не врём).

## Файлы

- `app/lib/models/parser_config.dart` — геттер `SelectableRule.touchesDns`.
- `app/lib/screens/routing_screen/widgets/custom_rule_tile.dart` — параметр
  `touchesDns` + виджет `_dnsChip` (приглушён при выключенном правиле).
- `app/lib/screens/routing_screen.dart` — вычисление `touchesDns` в
  `_buildCustomRuleTile` (пресет → touchesDns, inline/srs → dnsMirrorActive).
- `app/lib/screens/custom_rule_edit/tabs/preset_params_tab.dart` — чип в
  баннере «Based on preset».
- `app/test/services/builder/preset_expand_test.dart` — тесты `touchesDns`.

## Связано

- §228 (FakeIP/ru-direct — dns_rule/dns_servers; их и помечаем).
- §117 (DNS-mirror для user-правил — `dnsMirrorActive`).
- §177 (DNS-бейджи в профайлере — тот же принцип «показать DNS-аспект»).
