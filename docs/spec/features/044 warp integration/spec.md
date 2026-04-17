# 044 — Cloudflare WARP Integration

## Контекст

Cloudflare WARP — бесплатный VPN на базе WireGuard. В РФ endpoints заблокированы Роскомнадзором, но:
- API регистрации (`api.cloudflareclient.com`) доступен
- Ключи генерируются без ограничений
- Подключение возможно через кастомные endpoints (сканеры рабочих IP) или через chained proxy (WARP через другой прокси)

sing-box нативно поддерживает WireGuard outbound — WARP ключи подставляются напрямую.

## Что делаем

### Кнопка "Add WARP" в Subscriptions

В drawer Subscriptions или отдельная кнопка — "Add Cloudflare WARP". Процесс:

1. **Регистрация** — POST на `https://api.cloudflareclient.com/v0a2158/reg`
2. **Получение ключей** — private_key, public_key, addresses (IPv4 + IPv6)
3. **Создание WireGuard outbound** с WARP credentials
4. **Endpoint** — по умолчанию `engage.cloudflareclient.com:2408`, пользователь может изменить

### API Flow

```
POST https://api.cloudflareclient.com/v0a2158/reg
Headers:
  Content-Type: application/json
  CF-Client-Version: a-7.21-0721
Body:
  {
    "key": "<generated_public_key>",
    "install_id": "",
    "fcm_token": "",
    "tos": "<ISO8601_now>",
    "model": "Android",
    "serial_number": "<random_install_id>",
    "locale": "en_US"
  }

Response:
  {
    "id": "...",
    "account": { "id": "...", "license": "..." },
    "config": {
      "client_id": "...",
      "peers": [
        {
          "public_key": "bmXOC+F1FxEMF9dyiK2H5/1SUtzH0JuVo51h2wPfgyo=",
          "endpoint": {
            "host": "engage.cloudflareclient.com",
            "v4": "162.159.193.10",
            "v6": "2606:4700:100::a29f:c10a"
          }
        }
      ],
      "interface": {
        "addresses": {
          "v4": "172.16.0.2",
          "v6": "fd01:db8:1111::2"
        }
      }
    }
  }
```

### Генерируемый outbound

```json
{
  "type": "wireguard",
  "tag": "warp",
  "server": "engage.cloudflareclient.com",
  "server_port": 2408,
  "local_address": ["172.16.0.2/32", "fd01:db8:1111::2/128"],
  "private_key": "<generated>",
  "peer_public_key": "bmXOC+F1FxEMF9dyiK2H5/1SUtzH0JuVo51h2wPfgyo=",
  "mtu": 1280,
  "reserved": [0, 0, 0]
}
```

### Кастомный endpoint

В РФ стандартный endpoint заблокирован. Варианты:

1. **Ручной ввод** — пользователь вставляет рабочий IP:port (из сканера)
2. **Через прокси** — добавить `"detour": "proxy-out"` чтобы WARP шёл через другой прокси (chained: proxy → WARP → интернет)
3. **Встроенный сканер** (будущее) — перебор known endpoints на доступность

UI: поле "Endpoint" с default `engage.cloudflareclient.com:2408` + toggle "Route through proxy" (добавляет detour).

### Хранение

WARP credentials сохраняются как custom_node (спека 018) с типом wireguard:

```json
{
  "tag": "warp",
  "type": "wireguard",
  "server": "engage.cloudflareclient.com",
  "server_port": 2408,
  "private_key": "...",
  "peer_public_key": "...",
  "local_address": ["172.16.0.2/32"],
  "mtu": 1280
}
```

### UI

**Экран WARP Setup:**

```
[Cloudflare WARP logo]

Status: Not registered / Registered ✓

[Register WARP]  ← кнопка, вызывает API

Endpoint: [engage.cloudflareclient.com:2408]  [Edit]
☐ Route through proxy (detour)

Account ID: abc123...
Device ID: def456...

[Add to config]  ← создаёт WireGuard outbound
```

После добавления — WARP нода появляется в списке как обычная нода, доступна для выбора в группах.

### WARP+ (опционально)

Если у пользователя есть WARP+ лицензия — поле для ввода ключа:
```
PATCH https://api.cloudflareclient.com/v0a2158/reg/<id>/account
Body: { "license": "<warp_plus_key>" }
```

Увеличивает лимит трафика и даёт приоритетные маршруты.

## Файлы

| Файл | Изменения |
|------|-----------|
| `lib/services/warp_client.dart` | **Новый** — API клиент для WARP регистрации |
| `lib/screens/warp_screen.dart` | **Новый** — UI регистрации и настройки |
| `lib/screens/subscriptions_screen.dart` | Кнопка "Add WARP" |
| `lib/services/settings_storage.dart` | Хранение WARP credentials |

## Зависимости

- WireGuard key generation: `dart:typed_data` + `package:cryptography` (X25519) или нативный вызов
- Альтернатива: генерировать ключи на Kotlin стороне через libbox

## Риски

- Cloudflare может изменить API без предупреждения
- Endpoints могут быть заблокированы полностью (без обхода)
- Rate limiting на API регистрации

## Критерии приёмки

- [ ] Кнопка "Add WARP" регистрирует устройство через API
- [ ] WireGuard outbound с WARP credentials добавляется в конфиг
- [ ] Пользователь может изменить endpoint
- [ ] Toggle "Route through proxy" добавляет detour
- [ ] WARP нода появляется в списке и пингуется
- [ ] WARP+ ключ применяется (если введён)
