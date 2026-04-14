# BoxVPN

Android VPN-клиент на базе **sing-box**. Репозиторий: [github.com/Leadaxe/BoxVPN](https://github.com/Leadaxe/BoxVPN).

## Возможности

### Подписки и конфигурация
- **Subscription Parser**: добавление подписок по URL или direct link. Поддержка Base64, Xray JSON array, plain text. Протоколы: VLESS, VMess, Trojan, Shadowsocks, Hysteria2, SSH, SOCKS, WireGuard.
- **Config Generator**: wizard template + пользовательские переменные + узлы подписок → готовый sing-box JSON. Regex-фильтры, selector/urltest группы, selectable routing rules.
- **Auto-refresh**: автоматическое обновление подписок по `parser.reload` интервалу при старте VPN.
- **Quick Start**: встроенный пресет бесплатных подписок — один тап до работающего VPN.

### VPN и управление узлами
- **Start/Stop VPN** через libbox (`flutter_singbox_vpn`, Android VpnService).
- **Clash API**: выбор группы (Selector/URLTest), список узлов, переключение.
- **Mass Ping**: пинг всех нод группы одной кнопкой с возможностью отмены.
- **Сортировка**: по задержке (↑↓) или имени (A→Z).
- **Pull-to-refresh** на списке нод.
- **Long-press меню**: Ping, Use node, Copy name.

### Настройки
- Wizard-переменные: log level, Clash API, DNS strategy, resolve strategy и др.
- Selectable routing rules: Block Ads, Russian domains direct, BitTorrent direct, Games direct, Private IPs direct.
- Автоматическая перегенерация конфига при изменении настроек.

### UI/UX
- **Dark Theme**: автоматическое переключение по системным настройкам.
- **JSON-редактор конфига** с pretty-print.
- Импорт конфига: из файла, буфера обмена, JSON5/JSONC (комментарии).
- Debug-экран: последние 100 событий ядра и приложения.

## Быстрый старт

```bash
cd app
flutter pub get
flutter run
```

На главном экране нажмите **Set Up Free VPN** → подписки загрузятся, конфиг сгенерируется → **Start**.

Подробнее о сборке: [`docs/BUILD.md`](docs/BUILD.md).

## Документация

| Документ | Описание |
|----------|----------|
| [`docs/ARCHITECTURE.md`](docs/ARCHITECTURE.md) | Архитектура: пакеты, потоки данных, ключевые решения |
| [`docs/BUILD.md`](docs/BUILD.md) | Сборка, CI, подпись APK |
| [`CHANGELOG.md`](CHANGELOG.md) | История изменений |
| [`AGENTS.md`](AGENTS.md) | Правила для AI-агентов и автоматизации |

### Спецификации

Все спецификации в [`docs/spec/features/`](docs/spec/features/):

| # | Фича | Статус |
|---|-------|--------|
| 001 | [Mobile Stack](docs/spec/features/001%20mobile%20stack/spec.md) | Flutter + libbox + VpnService | ✓ |
| 002 | [MVP Scope](docs/spec/features/002%20mvp%20scope/spec.md) | Start/Stop, группы, узлы | ✓ |
| 003 | [Servers Tab](docs/spec/features/003%20servers%20tab/spec.md) | Clash API, ping | ✓ |
| 004 | [Subscription Parser](docs/spec/features/004%20subscription%20parser/spec.md) | Порт парсера Go → Dart | ✓ |
| 005 | [Config Generator](docs/spec/features/005%20config%20generator/spec.md) | Wizard template + vars → config | ✓ |
| 006 | [Subscription & Settings UI](docs/spec/features/006%20subscription%20and%20settings%20ui/spec.md) | Экраны подписок и настроек | ✓ |
| 007 | [Config Editor](docs/spec/features/007%20config%20editor%20improvements/spec.md) | Pretty JSON | ✓ |
| 008 | [Ping & Node Management](docs/spec/features/008%20ping%20and%20node%20management/spec.md) | Mass ping, sort, context menu | ✓ |
| 009 | [Dark Theme & UX](docs/spec/features/009%20dark%20theme%20and%20ux/spec.md) | Theme, pull-to-refresh, node count | ✓ |
| 010 | [Quick Start & Auto-refresh](docs/spec/features/010%20quick%20start%20and%20auto%20refresh/spec.md) | Get Free VPN, auto-update | ✓ |

## Лицензия

Уточнится при первом релизе.
