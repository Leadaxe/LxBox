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

### NodeParser

- `isWireGuardConfig(input)` — определяет INI формат
- `wireGuardConfigToUri(config)` — конвертирует INI → URI
- `_parseWireGuard(uri)` — парсит URI в `ParsedNode` с endpoint-структурой

### ConfigBuilder

- WireGuard ноды (type == 'wireguard') добавляются в `config['endpoints']`, не в `config['outbounds']`
- Tag используется в proxy groups наравне с outbound'ами

### Способы добавления

1. Вставить URI в поле ввода
2. Paste from clipboard
3. Вставить INI конфиг — автоконвертация

## Файлы

| Файл | Изменения |
|------|-----------|
| `node_parser.dart` | `isWireGuardConfig`, `wireGuardConfigToUri`, `_parseWireGuard` |
| `config_builder.dart` | Разделение WG endpoints от outbounds |
| `subscription_controller.dart` | Определение WireGuard INI конфига |
| `subscriptions_screen.dart` | "Paste from clipboard" в popup menu |

## Критерии приёмки

- [x] Парсинг `wireguard://` URI
- [x] Конвертация INI конфига в URI
- [x] WireGuard добавляется в `endpoints[]`, не в `outbounds[]`
- [x] Endpoint структура с `peers[]`
- [x] Нода появляется в списке и участвует в proxy groups

## See also

- [004 subscription parser](../004%20subscription%20parser/spec.md) — parser supports wireguard:// scheme
- [018 detour server management](../018%20detour%20server%20management/spec.md) — WireGuard as detour for other nodes
