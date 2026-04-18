# 025 — Cloudflare WARP Integration

| Поле | Значение |
|------|----------|
| Статус | Спека (planned) |

## Контекст

Cloudflare WARP — бесплатный VPN на базе WireGuard. В РФ endpoints заблокированы, но:
- API регистрации (`api.cloudflareclient.com`) доступен
- Ключи генерируются без ограничений
- Подключение возможно через кастомные endpoints или через chained proxy

## Кнопка "Add WARP" в Subscriptions

Процесс:
1. **Регистрация** — POST на `https://api.cloudflareclient.com/v0a2158/reg`
2. **Получение ключей** — private_key, public_key, addresses
3. **Создание WireGuard outbound** с WARP credentials
4. **Endpoint** — по умолчанию `engage.cloudflareclient.com:2408`

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
```

### Кастомный endpoint

1. **Ручной ввод** — рабочий IP:port из сканера
2. **Через прокси** — `"detour": "vpn-1"` (chained: proxy → WARP → интернет)
3. **Встроенный сканер** (будущее)

### UI — WARP Setup Screen

```
[Cloudflare WARP logo]

Status: Not registered / Registered ✓

[Register WARP]

Endpoint: [engage.cloudflareclient.com:2408]  [Edit]
☐ Route through proxy (detour)

Account ID: abc123...
Device ID: def456...

[Add to config]
```

### WARP+ (опционально)

Поле для ввода лицензионного ключа:
```
PATCH https://api.cloudflareclient.com/v0a2158/reg/<id>/account
Body: { "license": "<warp_plus_key>" }
```

## Файлы

| Файл | Изменения |
|------|-----------|
| `lib/services/warp_client.dart` | API клиент для WARP |
| `lib/screens/warp_screen.dart` | UI регистрации и настройки |
| `lib/screens/subscriptions_screen.dart` | Кнопка "Add WARP" |
| `lib/services/settings_storage.dart` | Хранение WARP credentials |

## Зависимости

- WireGuard key generation: X25519 (package:cryptography или нативный вызов)

## Риски

- Cloudflare может изменить API
- Endpoints могут быть заблокированы полностью
- Rate limiting на API регистрации

## Критерии приёмки

- [ ] Кнопка "Add WARP" регистрирует устройство через API
- [ ] WireGuard outbound с WARP credentials добавляется в конфиг
- [ ] Можно изменить endpoint
- [ ] Toggle "Route through proxy" добавляет detour
- [ ] WARP нода появляется в списке и пингуется
- [ ] WARP+ ключ применяется (если введён)
