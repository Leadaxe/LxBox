# 106 — WG/AWG parser: raw-`/` в ключе + bare-IP без CIDR

**Дата:** 2026-06-10 · **Статус:** DONE
**Источник:** баг-репорт из desktop (singbox-launcher) — оба воспроизведены и в
LxBox прямым прогоном парсера.

## Баг 1 — private key с raw `/` → нода отклоняется

`wireguard://FgFc1x9371GE/DV6bE…@host` — base64-ключ с сырым `/`. `Uri.tryParse`
трактует `/` как начало path: userInfo обрезается, ключ теряется →
`parseWireguardUri` возвращает `null` (guard `privateKey.isEmpty`). Симптом:
сервер виден в **Sources**, но пропадает из **Preview / all servers**.

**Фикс:** перед `Uri.tryParse` percent-энкодим сырые `/` **только в
userInfo-части** (между `://` и первым `@`); уже-`%2F` не трогаем (там нет
raw `/`); query (где `address=10.0.0.2/32`) не затрагивается. INI-форма
безопасна и так (`_iniToUri` гонит ключ через `Uri.encodeComponent`), JSON —
прямое поле без URL-парсинга.

## Баг 2 — bare IP без CIDR → ядро не стартует

`address=172.16.0.2` (или `allowed_ips` без `/`) — частый вид в AmneziaWG
`.conf`-экспортах. sing-box: `Failed to start … endpoints[0].address …
netip.ParsePrefix("172.16.0.2"): no '/'`.

**Фикс:** helper `ensureCidr` (в `uri_utils.dart`): bare IPv4 → `/32`, bare
IPv6 (есть `:`) → `/128`; пустые и уже-с-`/` не трогаем. Применяется к
`address` и `allowed_ips` во **всех** входах:
- `wireguard_parser.dart` — `localAddresses`, `allowedIps` (накрывает URI и
  INI, т.к. INI идёт через `parseWireguardUri`);
- `json_parsers.dart` (`'wireguard'` case) — `address[]`, `peers[].allowed_ips`.

## Тесты

`test/parser/wireguard_edge_test.dart`:
- raw-`/` ключ → парсится, privateKey с `/` восстановлен; `%2F` — без двойного
  декода;
- bare IPv4 address/allowed_ips → `/32`; bare IPv6 → `/128`; уже-CIDR без
  изменений; emit содержит CIDR-формы;
- JSON endpoint с bare-address → `/32`.
