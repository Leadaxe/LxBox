# 691 — TUN: адреса в обход туннеля (`route_exclude_address`)

| Поле | Значение |
|------|----------|
| Статус | Done (эмулятор — см. «Итог») |
| Дата начала | 2026-10-29 |
| Источник | владелец: «нужна графическая опция для параметра `tun.route_exclude_address` — не гонять через ядро трафик на локальные адреса (NAS, большие файлы)»; галка «Custom tunnel routes» непонятна — включаешь, в интерфейсе ничего не меняется |
| Связанные | §232 (галка `route_address_enable`), §046 (`applyTunPackages`), §690 (свои пулы FakeIP) |

## Проблема

1. Исключить адреса из маршрутов TUN нельзя. Трафик в локальную сеть
   (NAS, принтер, медиасервер) идёт в TUN, через пользовательский стек ядра
   и `direct-out` обратно в сеть: лишний CPU и батарея на больших объёмах.
   Пресет `private-ip` → direct этого не убирает — трафик всё равно проходит
   через ядро.
2. Галка `route_address_enable` («Custom tunnel routes») заменяет маршрут
   по умолчанию половинками (`0.0.0.0/1` + `128.0.0.0/1`, `::/1` +
   `8000::/1`). Через туннель идёт то же самое; это обход для прошивок, где
   маршрут по умолчанию у VPN ведёт себя странно (§232). Заголовок обещает
   «свои маршруты», которых нет.

## Решение

### Поле «Bypass the tunnel»

Var раздела TUN (VPN Settings), рядом с адресами TUN:

| Поле | Значение |
|---|---|
| имя | `tun_route_exclude` |
| тип | `text_list`, `options` + `options_open` (чипы + свои строки) |
| дефолт | пусто |
| опции | `192.168.0.0/16`, `10.0.0.0/8`, `172.16.0.0/12`, `169.254.0.0/16`, `fe80::/10` (`fd00::/8` не предлагается: накрывает IPv6-адрес TUN `fdfe:dcba:9876::1/126`) |
| заголовок | Bypass the tunnel |

В шаблоне tun-inbound — map-spread
`"#if exclude": [{"@tun_route_exclude": "#notEmpty"}, {"route_exclude_address": "@tun_route_exclude"}]`:
пустой список — ключа нет, конфиг байт в байт как раньше.

Нативная часть готова: `BoxVpnService.kt` на Android 13+ вызывает
`excludeRoute` по `inet4/6RouteExcludeAddress`, ниже — ядро само вычитает
исключения из `inet4/6RouteRange`. Применяется на `establish()`: нужен
полный перезапуск VPN, как у списка приложений §046.

Подсказка называет условия явно: трафик к этим адресам идёт мимо VPN и
мимо ядра — правила, DNS-перехват и статистика его не видят; не добавлять
сети, которые нужны через VPN-узел (корпоративная 10.x за WireGuard /
OpenConnect); не пересекать с пулом FakeIP (§690) и адресом TUN.

### Защита сборки

Post-step `healTunRouteExclude` после `applyTunPackages`. Из
`route_exclude_address` tun-inbound снимается строка, если:

1. не разбирается как CIDR (адрес + `/N` в пределах семейства) — иначе
   ядро не стартует на разборе префикса;
2. накрывает адрес самого TUN (`address` tun-inbound, `tun_address` /
   `tun_address6`) — иначе DNS-перехват и сам туннель ломаются.

Каждая снятая строка — предупреждение сборки (`emitWarnings`, как у
соседних heal-шагов) с причиной. Опустевший список — ключ снимается.
Пересечение с пулом FakeIP и сетями за узлами не проверяется.

### Галка `route_address_enable`

Поведение не меняется. Заголовок «Custom tunnel routes» → «Split default
route», подсказка: «Send all traffic to the tunnel as two half-ranges per
address family instead of one default route. The same traffic goes through
the tunnel; turn on only if the device ignores the VPN's default route.»

## Файлы

- `app/assets/wizard_template.json` — var `tun_route_exclude`, map-spread в
  tun-inbound, заголовок и подсказка `route_address_enable`.
- `app/lib/services/builder/post_steps/heal_tun_route_exclude.dart` +
  `post_steps.dart` (part) + вызов в `build_config.dart`.
- `app/assets/l10n/{ru,zh}/template.json`.
- `app/test/services/builder/heal_tun_route_exclude_test.dart`.
- `docs/TEMPLATE.md`, `docs/GUARDS.md`, `CHANGELOG.md`.

## Проверка

- Тест шага: валидные строки остаются; мусор и `172.16.0.0/12` при TUN
  `172.16.0.1/30` снимаются с предупреждением; всё снято — ключа нет;
  IPv6 — так же по `tun_address6`.
- Golden-конфиги не меняются (поле пустое).
- Эмулятор: `192.168.0.0/16` в поле → в конфиге `route_exclude_address`;
  VPN поднимается; `ip route` / `dumpsys connectivity` — исключение в
  маршрутах VPN-сети.

## Итог эмулятора (29.10.2026, сборка GH run 40777953843 на develop e89864e8)

- VPN Settings → Core → TUN: поле «Bypass the tunnel» с чипами и «Other
  values, one per line»; галка «Split default route» с новой подсказкой.
- Выбраны `192.168.0.0/16`, `10.0.0.0/8`, `172.16.0.0/12`, режим VPN,
  старт: VPN поднялся, таблица VPN (`ip route show table 1018`):
  `default dev tun0`, `throw 10.0.0.0/8`, `throw 192.168.0.0/16`,
  `172.16.0.0/30 dev tun0` — `172.16.0.0/12` снят защитой (накрывает
  `172.16.0.1/30`), туннель жив.
- Предупреждение защиты пишется в журнал приложения (`AppLog.warning`, как у
  остальных heal-шагов), баннера на экране нет.
