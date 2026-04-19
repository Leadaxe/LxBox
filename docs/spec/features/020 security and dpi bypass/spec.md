# 020 — Security & DPI Bypass

| Поле | Значение |
|------|----------|
| Статус | Частично реализовано |

## 1. Security Hardening

### Контекст

Статья на Habr описывает уязвимости в мобильных VLESS-клиентах: локальный SOCKS5 без авторизации, открытый API, приватные пространства Android.

### Что уже защищено

| Мера | Статус |
|------|--------|
| TUN-only inbound (нет SOCKS5/HTTP на localhost) | ✅ |
| Clash API на random порту (49152-65535) | ✅ |
| Clash API secret (32 hex, `Random.secure()`) | ✅ |
| Clash API только localhost | ✅ |
| VPN Service not exported | ✅ |
| BootReceiver not exported | ✅ |
| Геомаршрутизация RU domains → direct | ✅ |
| Authorization header во всех Clash API запросах | ✅ |

### Рекомендации (roadmap)

**Приоритет 1:**
- [x] Валидация Clash API secret при каждом запросе
- [ ] Аудит логов на утечку credentials

**Приоритет 2:**
- [ ] Encrypted storage для secrets (Android Keystore)
- [ ] Маскировка credentials в Config Editor
- [ ] Маскировать URL в списке подписок

**Приоритет 3:**
- [ ] Certificate pinning
- [ ] network_security_config.xml
- [ ] ProGuard/R8 obfuscation

## 2. TLS Fragment (DPI Bypass)

**Status:** Реализовано

### Контекст

DPI анализирует первый пакет TLS ClientHello с SNI. **TLS Fragment** разбивает ClientHello на несколько маленьких TCP-пакетов.

sing-box 1.12+ поддерживает:
- **fragment** — TCP фрагментация ClientHello
- **record_fragment** — TLS record фрагментация (рекомендуется первым)

### Переменные в wizard_template.json

```json
"vars": {
  "tls_fragment": "false",
  "tls_record_fragment": "false",
  "tls_fragment_fallback_delay": "500ms"
}
```

### UI (VPN Settings)

Секция **DPI Bypass**:

| Поле | Тип | Описание |
|------|-----|----------|
| TLS Fragment | Switch | Включает `record_fragment` |
| TLS Record Fragment | Switch | Включает `fragment` (агрессивный) |
| Fallback delay | Text | Таймаут (500ms по умолчанию) |

### ConfigBuilder — только первый хоп

Fragment применяется **только к first-hop outbound'ам** (без `detour`):

```
Телефон → [TLS к jump-серверу] → Jump → [TLS к финальному серверу] → Прокси
           ↑ DPI видит это                ↑ DPI НЕ видит
```

Outbound'ы с `detour` — inner hops, фрагментировать бессмысленно.

**Почему это критично, а не просто "optimization":**

- **Бесполезность**. TLS внутреннего хопа происходит **внутри туннеля
  первого хопа**. Локальный DPI его не видит — фрагментировать handshake
  нечему.
- **Разрыв цепочки**. Некоторые сервера/транспорты (REALITY, kcp, трюки
  с утилизацией TCP MSS) чувствительны к формату TLS records. Фрагментация
  от inner-ноды может сломать handshake с сервером, и вся цепочка отвалится.
- **Двойная фрагментация**. Если бы мы ставили `fragment` и на первом и на
  inner-хопе, после шифрования первого туннеля inner TLS-handshake попадает
  в TCP-пакеты первого — фрагментация первого хопа уже их раскрошит. Повторное
  фрагментирование on top = хаос, непредсказуемые MTU-драмы.

Инвариант: **`tls.fragment` и `tls.record_fragment` только там, где outbound
НЕ содержит ключ `detour`**. Реализация — `applyTlsFragment` в
`lib/services/builder/post_steps.dart`.

### Рекомендуемая стратегия обхода DPI

1. TLS record fragment (мягко)
2. TLS fragment (агрессивнее)
3. WARP as detour (WireGuard через Cloudflare)
4. Серверная сторона: REALITY протокол

### Ссылки

- [sing-box TLS docs](https://sing-box.sagernet.org/configuration/shared/tls/)
- [GoodbyeDPI](https://github.com/ValdikSS/GoodbyeDPI)
- [zapret](https://github.com/bol-van/zapret)

## Файлы

| Файл | Изменения |
|------|-----------|
| `wizard_template.json` | Clash API defaults, TLS fragment vars |
| `services/builder/build_config.dart` | `_ensureClashApiDefaults` (переехал из v1 `config_builder.dart`) |
| `services/builder/post_steps.dart` | `applyTlsFragment` (first-hop-only, см. инвариант выше) |
| `clash_api_client.dart` | Authorization header |
| `settings_screen.dart` | DPI Bypass секция |
| `AndroidManifest.xml` | Services not exported |

## Критерии приёмки

- [x] Нет SOCKS5/HTTP inbound на localhost
- [x] Clash API на рандомном порту с обязательным secret
- [x] TLS Fragment switches в VPN Settings
- [x] Fragment применяется только к first-hop outbound'ам
- [x] Autosave как остальные настройки
- [ ] Аудит логов на утечку credentials
- [ ] Encrypted storage для secrets
- [ ] network_security_config.xml
