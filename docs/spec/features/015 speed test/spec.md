# 015 — Built-in Speed Test

| Поле | Значение |
|------|----------|
| Статус | Реализовано |

## Контекст

Пользователю нужно проверить скорость соединения через VPN-туннель, не выходя из приложения.

## Концепция

Трёхфазный тест: **Ping → Download → Upload**, проходящий через активный VPN-туннель.

### Фазы теста

#### 1. Ping (латентность)
- HTTP GET на `ping_url` выбранного сервера (не общий URL, а конкретный сервер)
- Каждый speed test сервер имеет свой `ping_url` в `wizard_template.json`
- Fallback: если `ping_url` не указан, используется `download_url`
- 5 замеров, trimmed mean (без min/max)

#### 2. Download
- 4 параллельных потока для насыщения канала
- Warm-up: 1MB калибровка, затем основной замер (10-25MB)
- Real-time обновление скорости каждые 500мс
- Таймаут: 15 секунд на фазу
- Fallback: Cloudflare → Hetzner → custom

#### 3. Upload
- POST на Cloudflare `__up` endpoint
- Прогрессивный размер: 1MB калибровка, затем 5-10MB

### Серверы

| Приоритет | Провайдер | Download URL | Upload URL |
|-----------|-----------|-------------|------------|
| 1 | Cloudflare | `speed.cloudflare.com/__down?bytes=N` | `speed.cloudflare.com/__up` |
| 2 | Hetzner | `speed.hetzner.de/10MB.bin` | — |
| 3 | Custom | Настраивается пользователем | — |

### История

В `SharedPreferences`, максимум 10 записей:

```json
"speed_test_history": [
  {
    "timestamp": 1713200000,
    "ping": 42,
    "download": 85.3,
    "upload": 23.1,
    "proxy": "auto-proxy-out",
    "vpnEnabled": true
  }
]
```

## Файлы

| Файл | Изменения |
|------|-----------|
| `lib/screens/speed_test_screen.dart` | Multi-stream, real-time UI, история |
| `lib/services/speed_tester.dart` | Логика теста |
| `lib/services/settings_storage.dart` | getSpeedHistory / saveSpeedHistory |

## Критерии приёмки

- [x] Тест проходит через VPN-туннель
- [x] Download использует 4 параллельных потока
- [x] Скорость обновляется в реальном времени
- [x] Ping — trimmed mean из 5 замеров
- [x] История последних 10 тестов
- [x] Отображается текущий прокси/direct
- [x] Fallback на альтернативный сервер при ошибке
