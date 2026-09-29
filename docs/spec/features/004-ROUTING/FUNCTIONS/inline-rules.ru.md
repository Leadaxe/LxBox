[English](inline-rules.md) · [Русский](inline-rules.ru.md)

# Правило по условиям (Inline)

| Поле | Значение |
|------|----------|
| Фича | [004-ROUTING](../FEATURE.ru.md) |
| Обещания | P4 P5 |
| Состояние | ✅ написана по коду, 2026-09-28 |

## Что делает

Пользователь описывает, какой трафик ловить, прямо полями правила: домены,
IP-сети, порты, приложения, L7-протокол, транспорт, источник, вход, сеть
Wi-Fi — и куда его отправить. Это вид правила по умолчанию для «+ Add rule».
Сюда же относится правило по приложению: пакеты выбираются из списка
установленных приложений и матчатся ядром по `package_name`.

## Параметры

| Секция редактора | Поле | Ключ ядра | Где эмитится |
|---|---|---|---|
| MATCH | Domain | `domain` | headless rule_set |
| | Domain suffix | `domain_suffix` | headless |
| | Domain keyword | `domain_keyword` | headless |
| | IP CIDR (быстрые вставки: Localhost, Wi-Fi subnet, All) | `ip_cidr` | headless |
| | Private IP | `ip_is_private` | правило маршрута |
| | Source IP CIDR | `source_ip_cidr` | headless |
| | Private source IP | `source_ip_is_private` | правило маршрута |
| PORT | Port / Port range (`8000:9000`, `:3000`, `4000:`) | `port` / `port_range` | headless |
| APPS | выбор приложений | `package_name` | headless |
| NETWORK & PROTOCOL | `tcp` · `udp` · `icmp`; `bittorrent` `dns` `dtls` `http` `ntp` `quic` `rdp` `ssh` `stun` `tls` | `network`, `protocol` | правило маршрута |
| INBOUND | `tun-in` · `mixed-in` | `inbound` | правило маршрута |
| WI-FI NETWORK | см. [wifi-conditions](wifi-conditions.ru.md) | `wifi_ssid`/`wifi_bssid` | headless |

Имя правила обязательно и уникально среди видимых имён списка (включая
названия пресетов). Цель и действие — [rule-actions](rule-actions.ru.md).

## Входы / Выходы

**Входы:** текст полей (по строке или через запятую), выбор приложений.
**Выходы:** `route.rule_set[]` типа `inline` с тегом = имя правила и одно
правило маршрута `{rule_set: <имя>, …, outbound|action}`; при пустом
headless-матче — правило маршрута без `rule_set`.

## Правила и инварианты

- Внутри категории условия складываются по ИЛИ, между категориями — по И
  (домены+IP · порты · приложения · протокол · …).
- Нормализация ввода: нижний регистр, срезаются `http(s)://` и хвостовой
  `/`, у суффикса — ведущая точка; IDN → punycode (`.рф` → `xn--p1ai`);
  голый IPv4 получает `/32`, IPv6 — `/128`.
- Проверка: домен — FQDN с буквенным TLD; суффикс допускает голый TLD
  (`ru`); keyword без пробелов; CIDR с корректной маской; порт 0..65535;
  диапазон с хотя бы одной границей и `lo ≤ hi`. Невалидные элементы
  подсвечиваются счётчиком «N · M invalid», нечисловые порты в конфиг не
  попадают.
- Правило без единого условия сохраняется, но в конфиг не идёт; в списке
  подпись «Tap to add match fields».
- Выключенное правило не даёт ни rule_set, ни правила маршрута.
- Коллизия тега rule_set с уже существующим → суффикс ` (2)`.
- Таб View показывает запись хранения и то, что правило даст в конфиг,
  независимо от свича вкл/выкл.
- Правило по приложению видит только трафик, уже попавший в ядро; в режиме
  Proxy атрибуция приложения, по подсказке шаблона, не работает.

## Границы

- Отрицания условия нет; `domain_regex`, `source_port` не выведены в форму —
  доступны через [сырой JSON](raw-json-rules.ru.md).
- Какие приложения вообще идут в туннель —
  [011-SPLIT_TUNNELING](../../011-SPLIT_TUNNELING/FEATURE.ru.md).
- DNS-опция правила — [005-DNS](../../005-DNS/FEATURE.ru.md).

## Ревизии

| # | Ревизия | Статус | Суть |
|---|---|---|---|
| 1 | [030F](../../../tasks/030F-custom-routing-rules/spec.md) | Active (v1.4.0) | Единая модель правил: приложения, домены, IP, порты, протокол, private IP |
| 2 | [030F/new_fields](../../../tasks/030F-custom-routing-rules/new_fields.md) | — | Источник (`source_ip_cidr`, `source_ip_is_private`) и `inbound` |
| 3 | [011](../../../tasks/011-sealed-customrule-split.md) | ✅ Реализовано | Раздельные виды правила: inline / srs / preset |
| 4 | [053](../../../tasks/053-custom-rule-editor-split.md) | Done | Редактор разбит на секции MATCH/PORT/APPS/… |
| 5 | [064](../../../tasks/064-view-tab-preview-independent-of-enabled.md) | done | Превью View не зависит от свича |
| 6 | [144](../../../tasks/144-domain-suffix-validator.md) | Done | Отдельная проверка суффикса, IDN → punycode |
| 7 | [240](../../../tasks/240-network-matcher.md) | в develop | Фильтр `network` и секция NETWORK & PROTOCOL |
