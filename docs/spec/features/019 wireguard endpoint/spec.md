# 019 — WireGuard Endpoint

| Поле | Значение |
|------|----------|
| Статус | Реализовано |

## Контекст

WireGuard — популярный VPN-протокол. Пользователи могут иметь конфиг в двух форматах:
1. **URI**: `wireguard://privatekey@host:port?publickey=...&address=...`
2. **INI конфиг**: стандартный `[Interface]` / `[Peer]`

## Ключевое: WireGuard — это endpoint, не outbound

В sing-box 1.12+ WireGuard — это **endpoint** (`config.endpoints[]`), **НЕ** outbound.

### Структура endpoint

```json
{
  "type": "wireguard",
  "tag": "wg-parnas",
  "mtu": 1408,
  "address": ["10.10.10.2/32"],
  "private_key": "base64...",
  "peers": [
    {
      "address": "212.232.78.237",
      "port": 51820,
      "public_key": "base64...",
      "allowed_ips": ["0.0.0.0/0", "::/0"],
      "persistent_keepalive_interval": 25,
      "pre_shared_key": "base64..."
    }
  ]
}
```

**Outbound WireGuard deprecated с sing-box 1.11.0, будет удалён в 1.13.0.**

## Входные форматы

### 1. wireguard:// URI

```
wireguard://PRIVATE_KEY@HOST:PORT?publickey=KEY&address=ADDR&allowedips=IPS&keepalive=N&mtu=N#LABEL
```

### 2. INI конфиг

```ini
[Interface]
PrivateKey = base64...
Address = 10.10.10.2/32
DNS = 1.1.1.1
MTU = 1420

[Peer]
PublicKey = base64...
Endpoint = 212.232.78.237:51820
AllowedIPs = 0.0.0.0/0, ::/0
PersistentKeepalive = 25
PresharedKey = base64...
```

При вставке INI конфига он конвертируется в `wireguard://` URI, затем парсится стандартным путём.

## Реализация

### Parser v2

- `isWireGuardConfig(input)` в [`services/subscription/input_helpers.dart`](../../../../app/lib/services/subscription/input_helpers.dart) — определяет INI (`[Interface]` + `[Peer]`)
- `parseWireguardIni(config)` в [`services/parser/ini_parser.dart`](../../../../app/lib/services/parser/ini_parser.dart) — INI → canonical `wireguard://` URI → `WireguardSpec` через `parseWireguardUri`
- `parseWireguardUri(uri)` в [`services/parser/uri_parsers.dart`](../../../../app/lib/services/parser/uri_parsers.dart) — URI → `WireguardSpec` (sealed variant of `NodeSpec`)
- `WireguardSpec.emit(vars)` в [`models/node_spec_emit.dart`](../../../../app/lib/models/node_spec_emit.dart) → `Endpoint` (sealed variant of `SingboxEntry`, отдельно от `Outbound`)

### Builder (Parser v2)

Полиморфный `emit(vars)` возвращает `SingboxEntry`, который — sealed: `Outbound | Endpoint`. `EmitContext.addEntry` делает exhaustive switch и кладёт Endpoint в `config['endpoints']`, остальные — в `config['outbounds']`. Никаких runtime-проверок `type == 'wireguard'` в builder'е. Tag используется в proxy groups наравне с outbound'ами.

### Способы добавления

1. Вставить URI в поле ввода → `parseUri` → `WireguardSpec`
2. Paste from clipboard → smart-detect → Paste Dialog
3. Вставить INI конфиг → `parseWireguardIni` → `UserServer` с single-node
4. После любого добавления — auto-regenerate config (v1.3.1+)

## Файлы (обновлено под Parser v2)

| Файл | Изменения |
|------|-----------|
| `lib/services/parser/uri_parsers.dart` | `parseWireguardUri(uri)` → `WireguardSpec` |
| `lib/services/parser/ini_parser.dart` | `parseWireguardIni(config)` → INI → URI → `WireguardSpec` |
| `lib/services/subscription/input_helpers.dart` | `isWireGuardConfig(input)` — detection |
| `lib/models/node_spec.dart` | sealed `WireguardSpec` (variant of `NodeSpec`), `WireguardPeer` |
| `lib/models/node_spec_emit.dart` | `emitWireguard(spec, vars)` → `Endpoint(map)` |
| `lib/models/singbox_entry.dart` | sealed `SingboxEntry` = `Outbound \| Endpoint` |
| `lib/services/builder/build_config.dart` | `EmitContext.addEntry` делает sealed-switch на Outbound/Endpoint |
| `lib/controllers/subscription_controller.dart` | `addFromInput` → WG branch создаёт `UserServer(nodes: [spec])` |
| `lib/screens/subscriptions_screen.dart` | Smart-paste detection + dialog |

## Критерии приёмки

- [x] Парсинг `wireguard://` URI
- [x] Конвертация INI конфига в URI
- [x] WireGuard добавляется в `endpoints[]`, не в `outbounds[]`
- [x] Endpoint структура с `peers[]`
- [x] Нода появляется в списке и участвует в proxy groups

## See also

- [004x subscription parser](../004x%20subscription%20parser/spec.md) — parser supports wireguard:// scheme
- [018 detour server management](../018%20detour%20server%20management/spec.md) — WireGuard as detour for other nodes
