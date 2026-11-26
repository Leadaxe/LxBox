# 764 — вкладка Network у узла OpenConnect: состояние подключения к шлюзу

| | |
|---|---|
| **Статус** | Done — в ветке, на устройстве не проверено |
| **Дата** | 2026-11-26 |
| **Повод** | Решение владельца 26.11.2026: у узла OpenConnect вкладка состояния «как для Tailscale» |
| **Связанные** | 581 / 645 (вкладка Network узла Tailscale), 654 (OpenConnect: поток `SubscribeOpenConnectStatus`, второй фактор), 763 (форма OpenConnect) |

## Docs to update

- `docs/USER_GUIDE.md` / `.ru.md` — абзац о вкладках экрана сервера.
- `docs/ARCHITECTURE.md` — строка `cc_openconnect.dart` (модель туннеля).
- `CHANGELOG.md` — Unreleased.

## Problem

У узла Tailscale на экране сервера есть вкладка Network с состоянием сети.
У узла OpenConnect видно только форму и текст источника: подключён ли узел,
к какому шлюзу, каким транспортом, какой адрес и DNS выдал шлюз — в
приложении не узнать. Ядро эти данные уже отдаёт.

## Diagnosis

- Ядро `v1.14.4-lx.37`: поток `SubscribeOpenConnectStatus` →
  `OpenConnectEndpointStatus{EndpointTag, State, StateText, AuthChallenge,
  Error, TunnelInfo}`. `OpenConnectTunnelInfo` (javap AAR): `getServer`,
  `getFlavor`, `getTransport`, `getMTU` (int), `getConnectedSince` (long) и
  итераторы `iPv4()`, `iPv6()`, `dns()` (`StringIterator`).
- Состояния ядра (`adapter/openconnect.go`): `connecting`, `auth-pending`,
  `connected`, `error`. Других нет.
- `connected_since` — **секунды Unix** (`daemon/started_service.go`:
  `ConnectedSince.Unix()`), `0` — время не задано.
- `IPv4` / `IPv6` в ядре — `netip.Prefix` (строка с длиной префикса, вида
  `10.212.134.5/32`), `DNS` — адреса. `Server` — значение поля `server`
  узла как записано (хост, хост:порт или URL). `Transport` ядро пишет, как
  только узнало активный транспорт, независимо от состояния: при
  `connecting` карта `tunnel` бывает неполной.
- LxBox: `ServiceCommandClient.openConnectEndpointMap` (процесс `:bg`)
  кладёт в карту endpoint'а `tunnel` = `{server, flavor, transport, mtu,
  connected_since}`; списков адресов и DNS нет. Карта уходит в окно
  (`:ui`) через `lxbox/cc/openconnect` и `ccGetOpenConnectStatus` как есть,
  без пересборки по ключам. Dart-модель `CcOpenConnectStatus` поле `tunnel`
  не разбирает вовсе.
- Поток — широковещательный: вкладка, открытая после подключения, до
  следующего обновления ядра ничего не получит; текущий снапшот берётся
  `ccGetOpenConnectStatus` (так же делает `HomeController`).

## Solution

**Натив.** В карту `tunnel` добавлены `ipv4`, `ipv6`, `dns` — списки строк
из итераторов (тем же `stringList`, что у браузерного челленджа). Путь в
окно прежний.

**Модель.** `CcOpenConnectTunnel{server, flavor, transport, mtu,
connectedSince, ipv4, ipv6, dns}`, `CcOpenConnectStatus.tunnel` (`null` —
ключа нет). Числа разбираются через `num`; списков нет (старая карта) —
пустые списки.

**Вкладка.** `OpenConnectStatusTab` (`app/lib/widgets/`), подпись
`Network`; у узла OpenConnect (`protocol == openconnect`) встаёт как у
Tailscale: после JSON (INI у OpenConnect нет), перед Diagnostics. Статус
берётся по тегу работающего конфига (`TagResolver.displayTag`), как у
Tailscale. Данные: подписка на `CcChannel.openConnectStatus` и снапшот
`getOpenConnectStatus` при открытии и при каждом включении VPN.

Что показано:

| Условие | Вид |
|---|---|
| VPN выключен | строка `Start VPN to see the network.` |
| ответа ещё нет | индикатор загрузки |
| узла нет в снапшоте | строка `The node is not in the running config.` |
| `connected` | строки ниже |
| `auth-pending` или висит челлендж | `State: Waiting for sign-in`, под ним текст состояния ядра, если есть |
| `connecting` | `State: Connecting…` |
| `error` | `State: Error`, строка `Error` — текст ошибки ядра (`Error`, пустой — `StateText`) |
| иное (новое слово ядра) | `State:` — `StateText`, пустой — слово состояния |

Строки при `connected` (пустое значение — строки нет):

```
State        Connected · since 14:20
Gateway      fw2.example.com:42319 · fortinet
Transport    DTLS
Address      10.212.134.5 · fd00::5
DNS          10.0.0.1, 10.0.0.2
MTU          1350
```

- `since`: в тот же день — `HH:mm`, иначе `yyyy-MM-dd HH:mm`, местное
  время; `connected_since == 0` — просто `Connected`.
- `Gateway` — `server` как пришёл и через ` · ` `flavor`.
- `Transport` — слово ядра как есть.
- `Address` — IPv4, затем IPv6 через ` · `; у префикса хоста (`/32`
  IPv4, `/128` IPv6) длина отброшена, иначе — как пришло.
- `MTU` — при значении > 0.
- Строки адресов ядра показываются только при `connected`: в остальных
  состояниях карта `tunnel` неполная.
- Вид строк — как у Tailscale: `ListTile` dense, название — значение;
  **тап** по строке копирует значение (у Tailscale копирование тапом, не
  долгим нажатием), снэкбар `Copied`.

Тексты: новые ключи `Transport`, `MTU`, `Connected · since %s` (ru, zh);
остальные (`State`, `Gateway`, `Address`, `DNS`, `Error`, `Connected`,
`Connecting…`, `Waiting for sign-in`, `Network`, `Copied`, оба пустых
состояния) уже есть в словаре.

Приватность: адреса, DNS и шлюз — данные пользователя; модель не пишется
в журнал, дамп поддержки и Debug API (снапшот OpenConnect там не
сериализуется).

**Не сделано (будущее).** Сети шлюза (split-include / split-exclude):
ядро наружу их не отдаёт; строка появится, когда ядро добавит поле в
`OpenConnectTunnelInfo`.

## Verification

- Юнит: разбор карты статуса — без `tunnel`; `tunnel` старого вида (без
  списков); полная карта.
- Виджет: подключён (все строки, `since`), VPN выключен (пустое
  состояние), узла нет, ошибка (текст ядра).
- На устройстве не проверено: нужен шлюз OpenConnect.
