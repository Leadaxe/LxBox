# BoxVPN

Android VPN-клиент на базе **sing-box**. Репозиторий: [github.com/Leadaxe/BoxVPN](https://github.com/Leadaxe/BoxVPN).

## Возможности

### Подписки
- Добавление по URL или direct link (VLESS, VMess, Trojan, SS, Hysteria2, SSH, SOCKS, WireGuard)
- Форматы: Base64, Xray JSON Array (с chained proxy/jump), plain text
- Auto-refresh по интервалу при старте VPN
- Profile-title и subscription-userinfo из HTTP заголовков
- Detail screen: список нод, трафик/лимит, expire, support link
- Quick Start: встроенный пресет бесплатных подписок

### VPN и управление
- Нативный VPN-сервис (без сторонних плагинов, structured concurrency)
- Start/Stop одной toggle кнопкой
- Clash API: выбор группы (Selector), список узлов, переключение
- Mass Ping: 20 параллельных пингов со сбросом
- URLTest группы показывают auto-selected ноду
- Connections screen: живой список соединений, закрытие

### Routing
- Отдельный экран Routing: Proxy Groups + Routing Rules + App Groups
- Выбор outbound для каждого правила (direct/proxy/auto/vpn-X)
- App Groups: именованные группы приложений с outbound (per-app routing через sing-box)
- Route.final: настройка fallback трафика
- SRS rule sets: скачивание при включении, graceful fallback

### Настройки
- **VPN Settings**: MTU, packet sniffing, preferred IP, TUN stack, log level, Clash API
- **App Settings**: тема (Light / Dark / System)
- Clash API: рандомный порт, автогенерация секрета
- Portrait lock

## Быстрый старт

```bash
cd app
flutter pub get
flutter run
```

На главном экране: drawer → **Subscriptions** → **Get Free VPN** → Start.

## Документация

| Документ | Описание |
|----------|----------|
| [`docs/ARCHITECTURE.md`](docs/ARCHITECTURE.md) | Архитектура: пакеты, потоки данных, native код |
| [`docs/BUILD.md`](docs/BUILD.md) | Сборка, CI, подпись APK |
| [`docs/DEVELOPMENT_REPORT.md`](docs/DEVELOPMENT_REPORT.md) | Полная история разработки |
| [`CHANGELOG.md`](CHANGELOG.md) | Список изменений |
| [`docs/spec/features/`](docs/spec/features/) | Спецификации всех фич |

### Фичи

| # | Фича | Статус |
|---|-------|--------|
| 001–010 | MVP → Quick Start | Реализовано |
| 011 | Local Rule Set Cache | Реализовано |
| 012 | Xray JSON Array + Chained Proxy | Реализовано |
| 013 | Native VPN Service | Реализовано |
| 014 | Subscription Detail View | Реализовано |
| 015 | Rule Outbound Selection | Реализовано |
| 016 | Routing Screen | Реализовано |
| 017 | App Groups (Per-App Outbound) | Реализовано |
| 018 | Custom Nodes (Manual + Override) | Спека |
| 019 | Load Balance (PuerNya fork) | Спека |

## Лицензия

Уточнится при первом релизе.
