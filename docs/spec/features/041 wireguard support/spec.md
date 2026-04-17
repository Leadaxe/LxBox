# 041 — WireGuard Support

## Статус: Реализовано

## Контекст

WireGuard — популярный VPN-протокол. Пользователи могут иметь конфиг в двух форматах:
1. **URI**: `wireguard://privatekey@host:port?publickey=...&address=...`
2. **INI конфиг**: стандартный файл `[Interface]` / `[Peer]`

BoxVPN должен принимать оба формата и корректно добавлять WireGuard как ноду.

## Ключевое: WireGuard — это endpoint, не outbound

В sing-box 1.12+ WireGuard — это **endpoint** (`config.endpoints[]`), **НЕ** outbound (`config.outbounds[]`).

Документация: https://sing-box.sagernet.org/configuration/endpoint/wireguard/

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

### Отличия от outbound

| Поле | Endpoint (правильно) | Outbound (deprecated) |
|------|---------------------|----------------------|
| Секция конфига | `endpoints[]` | `outbounds[]` |
| Адрес сервера | `peers[].address` + `peers[].port` | `server` + `server_port` |
| Локальный адрес | `address` | `local_address` |
| Публичный ключ | `peers[].public_key` | `peer_public_key` |
| MTU по умолчанию | 1408 | 1408 |

**Outbound WireGuard deprecated с sing-box 1.11.0, будет удалён в 1.13.0.**

## Входные форматы

### 1. wireguard:// URI

```
wireguard://PRIVATE_KEY@HOST:PORT?publickey=KEY&address=ADDR&allowedips=IPS&keepalive=N&mtu=N#LABEL
```

- `PRIVATE_KEY` — в userinfo, URL-encoded
- `publickey` — обязательный
- `address` — обязательный (локальный адрес, напр. `10.10.10.2/32`)
- `allowedips` — опциональный (по умолчанию `0.0.0.0/0, ::/0`)
- `keepalive` — опциональный
- `mtu` — опциональный (по умолчанию 1408)
- `#LABEL` — имя ноды

### 2. INI конфиг (WireGuard native)

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

- `isWireGuardConfig(input)` — определяет INI формат по наличию `[Interface]` и `[Peer]`
- `wireGuardConfigToUri(config)` — конвертирует INI → `wireguard://` URI
- `_parseWireGuard(uri)` — парсит URI в `ParsedNode` с endpoint-структурой

### ConfigBuilder

- WireGuard ноды (type == 'wireguard') отделяются от обычных outbound'ов
- Добавляются в `config['endpoints']`, не в `config['outbounds']`
- Tag ноды используется в proxy groups (selector/urltest) наравне с outbound'ами

### SubscriptionController

- `addFromInput` определяет WireGuard конфиг до проверки на direct link
- Конвертирует INI → URI → добавляет как ноду

## Способы добавления

1. **Вставить URI** в поле ввода на экране Servers
2. **Paste from clipboard** в popup menu — сразу добавляет
3. **Вставить INI конфиг** — автоматически конвертируется в URI

## Файлы

| Файл | Изменения |
|------|-----------|
| `node_parser.dart` | `isWireGuardConfig`, `wireGuardConfigToUri`, `_parseWireGuard` — endpoint структура |
| `config_builder.dart` | Разделение WG endpoints от outbounds, добавление в `config['endpoints']` |
| `subscription_controller.dart` | Определение и обработка WireGuard INI конфига |
| `subscriptions_screen.dart` | "Paste from clipboard" в popup menu |

## Критерии приёмки

- [x] Парсинг `wireguard://` URI
- [x] Конвертация INI конфига в URI
- [x] WireGuard добавляется в `endpoints[]`, не в `outbounds[]`
- [x] Endpoint структура с `peers[]` (не deprecated outbound формат)
- [x] Нода появляется в списке и участвует в proxy groups
- [x] "Paste from clipboard" в popup menu
- [ ] Тестирование подключения через WireGuard endpoint
