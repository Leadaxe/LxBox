# 718 — Пресет `tunnel-routes`: в клиентский туннель идут только его собственные сети

| Field | Value |
|-------|-------|
| Status | Draft (спека согласована с владельцем по телу пресета; реализация не начата) |
| Start date | 2026-11-05 |
| Source | вопрос Dimitar Kavlakov в чате 05.11.2026: несколько одновременно работающих WireGuard и OpenVPN, через каждый доступны 1–2 сети /24, остальное должно идти дальше по правилам; у OpenVPN сети присылает сервер при подключении. Решение владельца: «вопрос Димитара решим простым пресетом»; правила, прикреплённые к подписке, — отдельный разговор, сюда не входят |
| Related specs | §578 (пресет `tailscale`, `for_each_node`, поля записи узла), §656 (пресет `tunnel-ingress`, поля `allow_*`, короткий `#if`), §370 (ось порядка `ui.num`), §654 (OpenConnect); контракт — `TEMPLATE_LANG.md` §6.5–§6.7 |

## Problem

Правило маршрута выбирает узел, дальше узел решает сам. Собственные сети
туннеля (allowed_ips у WireGuard, маршруты от сервера у OpenVPN и
OpenConnect) в `route.rules` не попадают. Если правило отправило в узел
адрес вне его сетей, соединение рвётся и к следующему Направлению не
переходит. Чтобы пользоваться туннелем «только для своих сетей», сегодня
надо руками переписать его префиксы в правило; для OpenVPN с динамическими
маршрутами это невозможно в принципе.

Попутная жалоба автора — ошибки DNS на таком узле: шаблонные UDP-серверы
идут через `vpn-1`, и когда там выбран узкий туннель, запросы к 8.8.8.8
уходят туда, где для них нет маршрута. Это следствие той же причины: узкий
туннель выбран общим Направлением, потому что иначе его не задействовать.

## Что даёт ядро

Матчер `preferred_by` (sing-box ≥ 1.13, `route/rule/rule_item_preferred_by.go`):
правило совпадает, если названный узел считает адрес или домен своим.

| Тип узла | Адрес | Домен | Где в ядре |
|---|---|---|---|
| `wireguard` (и AWG) | попадает в allowed_ips какого-то пира | — | `protocol/wireguard/endpoint.go` `PreferredAddress` |
| `openvpn-client` | в наборе `Routes − ExcludedRoutes` текущей конфигурации туннеля, набор пересобирается при каждой её смене | DNS-маршруты, search domains, домены первого по приоритету DNS-сервера | `protocol/openvpn/client.go` `PreferredAddress` / `PreferredDomain` |
| `openconnect` | та же схема через `routeSet` | `preferredDomains` | `protocol/openconnect/client.go` |

Оговорки, проверенные по коду:

- Код OpenVPN/OpenConnect апстримный (коммит «Add openvpn and openconnect»,
  17.07.2026). В таблице `preferred_by` на странице правил маршрута их нет,
  но страница DNS-сервера `openvpn` приводит пример с `preferred_by` — на
  матчер можно опираться.
- Пока туннель не поднят, матчер возвращает «нет»: трафик к сетям туннеля
  проваливается в следующее правило.
- `redirect-gateway` у OpenVPN добавляет в набор `0.0.0.0/0` (или пару
  `0.0.0.0/1` + `128.0.0.0/1` при `def1`; `protocol/openvpn/endpoint.go`).
  Такой узел с включённым флагом заберёт весь трафик — это и есть его
  собственные маршруты, поведение верное, но о нём надо сказать
  пользователю.
- Домен `.` среди присланных сервером совпадает с любым именем
  (`openVPNDomainMatches`): весь DNS уйдёт в этот туннель. Штатное
  поведение OpenVPN, но с пресетом оно сработает молча — сказать в
  USER_GUIDE рядом с `redirect-gateway`.
- DNS-сервер типа `openvpn` / `openconnect` без `accept_default_resolvers`
  на несвои домены отвечает `NXDOMAIN`. Наше DNS-правило отдаёт ему только
  свои домены, поэтому поля остаются по умолчанию.

## Решение

Новый пресет рядом с `tailscale`, по тем же образцам: тело — копия
`tailscale` (§578), флаг на узле — как `allow_*` у `tunnel-ingress` (§656).
Новых понятий в языке шаблона нет.

### A. Поле записи узла `own_routes`

- Bool, по умолчанию `false`. Хранится у своего сервера и у члена папки —
  там же и так же, как `allow_local` / `allow_lan` / `allow_gateway`
  (`SourceRecord`, бэкап `BackupRecord.server` и `BackupRecord.folderNode`,
  Debug API `subs`).
- Пятое имя в закрытом перечне полей, видимых обходу
  (`kPresetNodeRecordFieldNames`, `PresetNodeScope.recordField`). У узла
  подписки — `false`, как у остальных полей записи.
- Перечень закрыт контрактом: без новой версии поле читается как пустое
  значение и пресет молча ничего не выдаёт. Поэтому первым шагом — запрос
  лаунчеру (поле записи, пресет, кейсы корпуса); код после синка.

### B. Пресет `tunnel-routes`

```json
{
  "preset_id": "tunnel-routes",
  "for_each_node": {
    "#filter": {
      "#and": [
        { "@node.body.type": { "#in": ["wireguard", "openvpn-client", "openconnect"] } },
        "@node.own_routes"
      ]
    }
  },
  "ui": {
    "label": "Tunnel routes",
    "description": "Send to each client tunnel only the networks it announces: WireGuard allowed IPs, routes pushed by an OpenVPN or OpenConnect server. Everything else follows the rules below. Turned on per tunnel, in the tunnel's own settings.",
    "default": true,
    "num": 943,
    "isSortable": true
  },
  "vars": [
    {
      "name": "dns_enable",
      "type": "bool",
      "default_value": "true",
      "title": "DNS",
      "tooltip": "Resolve the names a tunnel announces with the tunnel's own DNS."
    }
  ],
  "rules": [
    {
      "#if": [
        { "#and": ["@dns_enable", { "@node.body.type": { "#in": ["openvpn-client", "openconnect"] } }] },
        { "preferred_by": ["@node"], "action": "resolve", "server": { "#tpl": "@{node}-dns" } }
      ]
    },
    { "preferred_by": ["@node"], "outbound": "@node" }
  ],
  "dns_servers": [
    {
      "#if": [
        { "#and": ["@dns_enable", { "@node.body.type": "openvpn-client" }] },
        { "type": "openvpn", "tag": { "#tpl": "@{node}-dns" }, "endpoint": "@node",
          "description": "DNS announced by the tunnel" }
      ]
    },
    {
      "#if": [
        { "#and": ["@dns_enable", { "@node.body.type": "openconnect" }] },
        { "type": "openconnect", "tag": { "#tpl": "@{node}-dns" }, "endpoint": "@node",
          "description": "DNS announced by the tunnel" }
      ]
    }
  ],
  "dns_rules": [
    {
      "#if": [
        { "#and": ["@dns_enable", { "@node.body.type": { "#in": ["openvpn-client", "openconnect"] } }] },
        { "preferred_by": [{ "#tpl": "@{node}-dns" }], "server": { "#tpl": "@{node}-dns" } }
      ]
    }
  ]
}
```

Что здесь решено и почему:

- **Флаг на включение.** Пресет включён по умолчанию, но без `own_routes`
  на узле не выдаёт ничего: у существующих установок конфиг не меняется.
  Флаг на выключение (как `skip_tailscale_presets`) здесь нельзя — WireGuard
  с `0.0.0.0/0` забрал бы весь трафик сразу после обновления.
- **DNS только у OpenVPN и OpenConnect.** У WireGuard доменов нет, для него
  одно адресное правило.
- **Два DNS-сервера вместо одной вставки.** Тип узла `openvpn-client`, тип
  DNS-сервера `openvpn` — одним `#tpl` не выразить.
- **Место `num: 943`** — между `tunnel-ingress` (940) и `tailscale` (945),
  поздний дефолт, как у Tailscale. Приоритет против своих правил и других
  пресетов пользователь задаёт перетаскиванием строки на Rules.
- **Порядок между узлами** — порядок узлов в конфиге (норма обхода). При
  пересекающихся сетях двух туннелей побеждает первый. Отдельной настройки
  нет, у `tailscale` то же ограничение.
- **Условие на `@node.body.type` в теле.** Тело `for_each_node` видит имена
  узла (§6.6), короткий `#if` — норма с 1.1.125. Язык у сторон один, у
  лаунчера `@node` в теле доступен так же.
- **`for_each_node`, а не `for_each_node_do`.** Сбор в список годится, когда
  у правила одно действие на все узлы (`tunnel-ingress`: список inbound →
  reject). Здесь цель правила — сам узел: `preferred_by: [a, b]` с одним
  `outbound` отправил бы сети обоих туннелей в один. То же с DNS: сервер у
  каждого узла свой. Поэтому правило на узел, фрагменты идут подряд.

Результат для узлов `office-ovpn` (OpenVPN) и `lab-wg` (WireGuard), у обоих
флаг включён:

```json
"route": { "rules": [
  { "preferred_by": ["office-ovpn"], "action": "resolve", "server": "office-ovpn-dns" },
  { "preferred_by": ["office-ovpn"], "outbound": "office-ovpn" },
  { "preferred_by": ["lab-wg"], "outbound": "lab-wg" }
]},
"dns": {
  "servers": [ { "type": "openvpn", "tag": "office-ovpn-dns", "endpoint": "office-ovpn",
                 "description": "DNS announced by the tunnel" } ],
  "rules":   [ { "preferred_by": ["office-ovpn-dns"], "server": "office-ovpn-dns" } ]
}
```

### C. Интерфейс

- Тумблер **«Only its own networks»** в настройках узла WireGuard / AWG /
  OpenVPN / OpenConnect, в одном блоке с тумблерами `tunnel-ingress`.
  Подпись: «Send to this tunnel only the networks it announces. It works
  alongside the selected server and does not need to be chosen as a
  direction.»
- У WireGuard, чьи allowed_ips содержат `0.0.0.0/0` или `::/0`, под
  включённым тумблером нотис: «This tunnel announces the default route, so
  it takes all traffic.» Тумблер не блокируется: у OpenVPN тот же случай
  (`redirect-gateway`) заранее не виден, а разное поведение двух типов
  запутает больше, чем предупреждение.
- Строка пресета на Rules — стандартная, с переменной DNS, как у
  «Tailscale networks».

### D. Документация

`docs/TEMPLATE.md` (таблица пресетов), `docs/PROTOCOLS.md` (WireGuard,
OpenVPN, OpenConnect), `docs/USER_GUIDE` (сценарий «несколько туннелей к
своим сетям»), `docs/STORAGE.md` и бэкап (поле записи), Debug API reference
(`subs`), CHANGELOG.

## Чего задача не делает

- Узлы подписки: у них нет записи, флаг поставить некуда. Правила и флаги,
  прикреплённые к подписке, — отдельное решение владельца.
- Условие `preferred_by` в редакторе правил.
- Защиту от утечки, пока туннель не поднят: трафик к его сетям идёт по
  следующему правилу. Для частных сетей это пакеты, которые не дойдут; в
  USER_GUIDE сказать прямо.
- Смену Направлений у шаблонных DNS-серверов. Узкий туннель больше не надо
  выбирать в `vpn-1`, и жалоба на ошибки DNS уходит сама.

## Проверка

1. Корпус контракта (`corpus/template/for_each_node`): узел WG с флагом —
   одно правило; OpenVPN с флагом — правило `resolve`, правило маршрута,
   DNS-сервер, DNS-правило; `dns_enable` выключен — только правила маршрута;
   флаг выключен — пусто; узел подписки — пусто; два узла — порядок по
   конфигу. Кейс с флагом обязателен: опечатка в имени поля выглядит как
   «пресет молчит».
2. Тест перечня полей записи (`own_routes` в `kPresetNodeRecordFieldNames`,
   круг через `SourceRecord` и бэкап).
3. Ядро принимает конфиг: эмулятор, WG-узел с allowed_ips из одной сети /24
   плюс обычный сервер в `vpn-1` — адрес из сети идёт в WG, остальное в
   `vpn-1` (лог маршрутизации).
4. OpenVPN с присланными маршрутами и доменами на живом сервере у нас
   проверить нечем — просим автора вопроса после rc.

## После

- Ответ в чат Dimitar после выхода сборки.
- Разговор про правила, DNS-серверы и DNS-правила, прикреплённые к
  подписке.
