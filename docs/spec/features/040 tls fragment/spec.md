# 040 — TLS Fragment (DPI Bypass)

## Статус: Спека

## Контекст

DPI (Deep Packet Inspection) у провайдеров анализирует первый пакет TLS ClientHello, в котором открытым текстом лежит SNI (Server Name Indication) — имя домена. По SNI блокируют соединения к прокси-серверам.

**TLS Fragment** — разбивает ClientHello на несколько маленьких TCP-пакетов. DPI не может собрать полный SNI из фрагментов и пропускает соединение. Сервер собирает все фрагменты и обрабатывает нормально.

sing-box 1.12+ поддерживает два режима фрагментации:
- **fragment** — TCP фрагментация ClientHello (разбивает на мелкие TCP сегменты)
- **record_fragment** — TLS record фрагментация (разбивает на несколько TLS records в одном TCP пакете). Рекомендуется пробовать первым — мягче, лучше совместимость

## Реализация

### sing-box конфиг

Параметры добавляются в TLS объект каждого outbound:

```json
{
  "type": "vless",
  "server": "example.com",
  "tls": {
    "enabled": true,
    "fragment": true,
    "record_fragment": false,
    "fragment_fallback_delay": "500ms"
  }
}
```

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
| TLS Fragment | Switch | Включает `record_fragment` (мягкий вариант, рекомендованный sing-box) |
| TLS Record Fragment | Switch | Включает `fragment` (агрессивный вариант, если первый не помогает) |
| Fallback delay | Text | Таймаут auto-detection (500ms по умолчанию)  |

**Примечание**: `size`/`sleep` параметры (как в Hiddify) не поддерживаются стандартным libbox — это фича форка Hiddify-next. В стандартном sing-box 1.12 фрагментация управляется только boolean флагами.

### ConfigBuilder — только первый хоп

Fragment применяется **только к first-hop outbound'ам** — тем, у которых нет `detour`.

Логика:
```
Телефон → [TLS к jump-серверу] → Jump → [TLS к финальному серверу] → Прокси
           ↑ DPI видит это                ↑ DPI НЕ видит (внутри туннеля)
```

При chained proxy (jump server) устройство устанавливает TLS с jump-сервером напрямую — DPI анализирует только этот handshake. Соединение от jump к финальному серверу идёт уже внутри туннеля, DPI его не видит.

Outbound'ы с `detour` — это inner hops, их TLS handshake проходит через туннель первого хопа. Фрагментировать их бессмысленно и потенциально вредно (лишний overhead).

```dart
// config_builder.dart — _applyTlsFragment
for (final ob in outbounds) {
  if (ob.containsKey('detour')) continue; // skip inner hops
  final tls = ob['tls'];
  if (tls?['enabled'] != true) continue;
  tls['fragment'] = true; // или record_fragment
}
```

Метод `_applyTlsFragment` вызывается как post-processing после сборки всех outbound'ов (из подписок и preset groups).

## Файлы

| Файл | Изменения |
|------|-----------|
| `wizard_template.json` | Добавить vars: tls_fragment, tls_record_fragment, tls_fragment_fallback_delay |
| `config_builder.dart` | Добавить fragment поля в TLS объекты outbound'ов |
| `settings_screen.dart` | Добавить 3 поля в VPN Settings |
| `settings_storage.dart` | Хранение настроек |

## Критерии приёмки

- [x] Switch "TLS Fragment" в VPN Settings (секция DPI Bypass)
- [x] Switch "TLS Record Fragment" в VPN Settings
- [x] Поле "Fragment Fallback Delay" с дефолтом 500ms
- [x] Fragment применяется только к first-hop outbound'ам (без `detour`)
- [x] Inner hops (с `detour`) не фрагментируются
- [x] При выключении — поля не добавляются
- [x] Autosave как остальные настройки
- [x] Секции с заголовками и описаниями в VPN Settings
- [ ] VPN запускается с fragment без ошибок (требует тестирования)
- [x] Настройки сохраняются между перезапусками

## Исследование: другие методы обхода DPI

Помимо TLS fragment, существуют другие техники (из проектов GoodbyeDPI, zapret):

### Доступные без root (потенциально реализуемы)

| Техника | Описание | Применимость |
|---------|----------|-------------|
| **SNI case mixing** | `example.com` → `eXaMpLe.CoM` | Нужен патч libbox — sing-box не поддерживает |
| **TLS record splitting** (tlsrec) | Два TLS record в одном TCP пакете | Покрывается `record_fragment` в sing-box |
| **WARP as detour** | Трафик до прокси через WireGuard→Cloudflare | Реализуемо — у нас есть WireGuard |
| **REALITY** | Маскировка TLS под легитимный сайт | Поддерживается sing-box, зависит от сервера |

### Требуют root/kernel (не реализуемы в приложении)

| Техника | Описание | Почему нет |
|---------|----------|-----------|
| **Fake packets + TTL** | Фейковый ClientHello с маленьким TTL | Raw sockets, root |
| **Bad checksum** | Пакеты с битой TCP checksum | Raw sockets |
| **IP fragmentation** | Фрагментация на уровне IP | Raw sockets, kernel config |
| **TCP window manipulation** | Изменение размера окна | Packet interception driver |
| **Reverse fragment order** | Отправка фрагментов в обратном порядке | Raw sockets |

### Рекомендуемая стратегия обхода DPI

1. **Первый уровень**: TLS record fragment (мягко, хорошая совместимость)
2. **Второй уровень**: TLS fragment (агрессивнее)
3. **Третий уровень**: WARP as detour (WireGuard через Cloudflare скрывает SNI полностью)
4. **Серверная сторона**: REALITY протокол (DPI видит легитимный SNI)

### Ссылки

- [sing-box TLS docs](https://sing-box.sagernet.org/configuration/shared/tls/)
- [GoodbyeDPI](https://github.com/ValdikSS/GoodbyeDPI) — Windows DPI bypass
- [zapret](https://github.com/bol-van/zapret) — Linux/macOS DPI bypass
- [Cloudflare WARP registration API](https://github.com/ViRb3/wgcf) — WireGuard конфиг от Cloudflare
