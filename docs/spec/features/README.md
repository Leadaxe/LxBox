# Фичи

Спецификации функциональности: пользовательские сценарии, поведение UI/ядра, ограничения, критерии готовности.

**Имя папки:** `NNN <название с пробелами>` — см. [`../README.md`](../README.md). Внутри — `spec.md`, при необходимости `plan.md` и `tasks.md`.

## Индекс

| # | Папка | Кратко | Статус |
|---|-------|--------|--------|
| 001 | [`001 mobile stack/`](001%20mobile%20stack/) | Стек: Flutter + нативный VPN + libbox | Принято |
| 002 | [`002 mvp scope/`](002%20mvp%20scope/) | MVP: Start-Stop / группы / узлы (Android) | Реализовано |
| 003 | [`003 home screen/`](003%20home%20screen/) | Главный экран: группы, узлы, контекст-меню, traffic bar, сортировка, node filter | Реализовано |
| 004 | [`004 subscription parser/`](004%20subscription%20parser/) | Парсер подписок: fetch, decode, parse, Xray JSON array, jump | Реализовано |
| 005 | [`005 config generator/`](005%20config%20generator/) | Генератор конфига: wizard template + vars + подписки → sing-box config | Реализовано |
| 006 | [`006 servers ui/`](006%20servers%20ui/) | UI подписок: detail view, toggles, context menu, paste dialog | Реализовано |
| 007 | [`007 config editor/`](007%20config%20editor/) | Форматирование JSON в редакторе конфига | Реализовано |
| 008 | [`008 ping and node management/`](008%20ping%20and%20node%20management/) | Mass ping, ping settings, URLTest config, цветовая индикация | Реализовано |
| 009 | [`009 ux and theme/`](009%20ux%20and%20theme/) | Dark theme, pull-to-refresh, autosave | Реализовано |
| 010 | [`010 quick start and offline/`](010%20quick%20start%20and%20offline/) | Quick Start, auto-refresh, subscription caching | Реализовано |
| 011 | [`011 local ruleset cache/`](011%20local%20ruleset%20cache/) | Локальный кэш remote .srs rule set файлов | Реализовано |
| 012 | [`012 native vpn service/`](012%20native%20vpn%20service/) | Нативный VPN-сервис, auto-connect on boot | Реализовано |
| 013 | [`013 routing/`](013%20routing/) | Rule outbound selection, routing screen, per-app proxy | Реализовано |
| 014 | [`014 dns settings/`](014%20dns%20settings/) | DNS серверы, правила, strategy, presets | Спека |
| 015 | [`015 speed test/`](015%20speed%20test/) | Built-in speed test: ping, download, upload | Реализовано |
| 016 | [`016 statistics and connections/`](016%20statistics%20and%20connections/) | Statistics by outbound, live connections | Реализовано |
| 017 | [`017 custom nodes and node settings/`](017%20custom%20nodes%20and%20node%20settings/) | Custom nodes, overrides, node settings (tag, detour) | Спека |
| 018 | [`018 detour server management/`](018%20detour%20server%20management/) | Multi-hop chains, jump server naming & visibility | Спека |
| 019 | [`019 wireguard endpoint/`](019%20wireguard%20endpoint/) | WireGuard URI + INI → sing-box endpoint | Реализовано |
| 020 | [`020 security and dpi bypass/`](020%20security%20and%20dpi%20bypass/) | Security hardening, TLS fragment | Частично |
| 021 | [`021 ci cd pipeline/`](021%20ci%20cd%20pipeline/) | GitHub Actions: checks, build, release | Реализовано |
| 022 | [`022 app settings/`](022%20app%20settings/) | Theme, auto-start on boot, keep VPN on exit | Реализовано |
| 023 | [`023 debug and logging/`](023%20debug%20and%20logging/) | Debug screen, log level, sing-box log viewer | Частично |
| 024 | [`024 load balance/`](024%20load%20balance/) | Load Balance через PuerNya fork | Спека |
| 025 | [`025 warp integration/`](025%20warp%20integration/) | Cloudflare WARP регистрация и интеграция | Спека |
