# Фичи

Спецификации функциональности: пользовательские сценарии, поведение UI/ядра, ограничения, критерии готовности.

**Имя папки:** `NNN <название с пробелами>` — см. [`../README.md`](../README.md). Внутри — `spec.md`, при необходимости `plan.md` и `tasks.md`.

**Правила (см. [`../README.md`](../README.md) и [`../tasks/054-spec-reorg-features-vs-tasks.md`](../tasks/054-spec-reorg-features-vs-tasks.md)):**
- В `features/` лежат **только живые продуктовые / архитектурные** концепции.
- Исторические решения (MVP scope, начальный стек), миграции, рефакторы, superseded спеки — в [`../tasks/`](../tasks/).
- Номера монотонные «вперёд». Освобождённые номера (001, 002, 004, 005, 013, 039, 041) — **не переиспользуются**, чтобы archive-ссылки не ломались.

## Индекс

| # | Папка | Кратко | Статус |
|---|-------|--------|--------|
| 003 | [`003 home screen/`](003%20home%20screen/) | Главный экран: группы, узлы, контекст-меню, traffic bar, сортировка, node filter | Реализовано |
| 006 | [`006 servers ui/`](006%20servers%20ui/) | UI подписок: detail view, toggles, context menu, paste dialog | Реализовано |
| 007 | [`007 config editor/`](007%20config%20editor/) | Форматирование JSON в редакторе конфига | Реализовано |
| 008 | [`008 ping and node management/`](008%20ping%20and%20node%20management/) | Mass ping, ping settings, URLTest config, цветовая индикация | Реализовано |
| 009 | [`009 ux and theme/`](009%20ux%20and%20theme/) | Dark theme, pull-to-refresh, autosave | Реализовано |
| 010 | [`010 quick start and offline/`](010%20quick%20start%20and%20offline/) | Quick Start, auto-refresh, subscription caching | Реализовано |
| 011 | [`011 local ruleset cache/`](011%20local%20ruleset%20cache/) | Локальный кэш remote .srs rule set файлов | Реализовано |
| 012 | [`012 native vpn service/`](012%20native%20vpn%20service/) | Нативный VPN-сервис, auto-connect on boot | Реализовано |
| 014 | [`014 dns settings/`](014%20dns%20settings/) | DNS серверы, правила, strategy, presets | Реализовано |
| 015 | [`015 speed test/`](015%20speed%20test/) | Built-in speed test: ping, download, upload | Реализовано |
| 016 | [`016 statistics and connections/`](016%20statistics%20and%20connections/) | Statistics by outbound, live connections | Реализовано |
| 017 | [`017 custom nodes and node settings/`](017%20custom%20nodes%20and%20node%20settings/) | Custom nodes, overrides, node settings (tag, detour) | Реализовано |
| 018 | [`018 detour server management/`](018%20detour%20server%20management/) | Multi-hop chains, jump server naming & visibility | Реализовано |
| 019 | [`019 wireguard endpoint/`](019%20wireguard%20endpoint/) | WireGuard URI + INI → sing-box endpoint | Реализовано |
| 020 | [`020 security and dpi bypass/`](020%20security%20and%20dpi%20bypass/) | Security hardening, TLS fragment | Частично |
| 021 | [`021 ci cd pipeline/`](021%20ci%20cd%20pipeline/) | GitHub Actions: checks, build, release | Реализовано |
| 022 | [`022 app settings/`](022%20app%20settings/) | Theme, auto-start on boot, keep VPN on exit | Реализовано |
| 023 | [`023 debug and logging/`](023%20debug%20and%20logging/) | Debug screen, log level, sing-box log viewer | Частично |
| 024 | [`024 load balance/`](024%20load%20balance/) | Load Balance через PuerNya fork | Спека |
| 025 | [`025 warp integration/`](025%20warp%20integration/) | Cloudflare WARP регистрация и интеграция (one-tap Get WARP) | Реализовано |
| 026 | [`026 parser v2/`](026%20parser%20v2/) | Sealed `NodeSpec` + 3-слойный pipeline parser/builder | Реализовано |
| 027 | [`027 subscription auto update/`](027%20subscription%20auto%20update/) | Auto-refresh подписок: 4 триггера + spam-gates | Реализовано |
| 028 | [`028 antidpi sni obfuscation/`](028%20antidpi%20sni%20obfuscation/) | Mixed-case SNI как post-step | Реализовано |
| 029 | [`029 haptic feedback/`](029%20haptic%20feedback/) | Тактильный отклик на ключевых действиях | Реализовано |
| 030 | [`030 custom routing rules/`](030%20custom%20routing%20rules/) | Unified `CustomRule` + inline и SRS-rules | Реализовано |
| 031 | [`031 debug api/`](031%20debug%20api/) | Localhost HTTP-сервер для интроспекции | Реализовано |
| 032 | [`032 quick connect/`](032%20quick%20connect/) | QS-tile + home shortcut | Реализовано |
| 033 | [`033 preset bundles/`](033%20preset%20bundles/) | Селектор preset-бандлов | Реализовано |
| 034 | [`034 app icon/`](034%20app%20icon/) | Финальная иконка приложения | Реализовано |
| 035 | [`035 mcp server/`](035%20mcp%20server/) | MCP-обёртка над Debug API | Спека |
| 036 | [`036 update check/`](036%20update%20check/) | Проверка обновлений на launch + manual | Реализовано |
| 037 | [`037 naive proxy/`](037%20naive%20proxy/) | NaïveProxy outbound: parser + emit + share-URI | Реализовано |
| 038 | [`038 crash diagnostics/`](038%20crash%20diagnostics/) | Crash diagnostics (merged into §043 diagnostics platform) | Реализовано |
| 040 | [`040 backup restore ui/`](040%20backup%20restore%20ui/) | Backup & restore UI | Реализовано |
| 042 | [`042 health watchdog/`](042%20health%20watchdog/) | Health watchdog (heartbeat metrics + auto-recovery) | Реализовано |
| 043 | [`043 applog per-source quotas/`](043%20applog%20per-source%20quotas/) | Diagnostics platform (Debug API + AppLog + Crash diagnostics) | Реализовано |
| 044 | [`044 per-app traffic profiler/`](044%20per-app%20traffic%20profiler/) | Per-app traffic profiler | Реализовано (v1.7.0) |
| 045 | [`045 tls ech/`](045%20tls%20ech/) | TLS ECH (Encrypted Client Hello) | Спека |
| 046 | [`046 tunnel apps split-tunneling/`](046%20tunnel%20apps%20split-tunneling/) | Tunnel apps: OS-level split-tunneling | Реализовано (v1.7.1) |
| 047 | [`047 public intent api/`](047%20public%20intent%20api/) | Public Intent API (Tasker / automation) | Спека |
| 048 | [`048 home-node-filters/`](048%20home-node-filters/) | Фильтры узлов на главном экране (`NodeFilter`) | Реализовано |
| 070 | [`070 sort-options/`](070%20sort-options/) | Опции сортировки узлов | Реализовано |
| 071 | [`071 manual-node-reorder/`](071%20manual-node-reorder/) | Ручной порядок узлов (drag-reorder) | Реализовано |
| 074 | [`074 add-server-wizard/`](074%20add-server-wizard/) | Мастер добавления сервера | Реализовано |
| 076 | [`076 settings-and-config-lifecycle/`](076%20settings-and-config-lifecycle/) | Жизненный цикл настроек и сборки конфига | Реализовано |
| 097 | [`097 awg2-amneziawg2/`](097%20awg2-amneziawg2/) | AmneziaWG / AWG2 + XHTTP (core-swap на sing-box-lx) | Реализовано (v2.0.0) |
| 105 | [`105 support-message/`](105%20support-message/) | Сообщение поддержки | Реализовано (v2.0.0) |
| 117 | [`117 dns-rework/`](117%20dns-rework/) | DNS-rework под sing-box 1.14 | Реализовано (v2.0.6) |
| 118 | [`118 subscription-fetch-identity/`](118%20subscription-fetch-identity/) | Идентичность fetch'а подписок (User-Agent и пр.) | Реализовано (v2.0.6) |
| 119 | [`119 vpn-mode/`](119%20vpn-mode/) | VPN Mode (vpn / proxy / vpn_proxy), data-driven вкладка | Реализовано |
| 120 | [`120 template-engine-typed-vars-and-if/`](120%20template-engine-typed-vars-and-if/) | Типизированный движок шаблона + декларативный `#if` | Реализовано |
| 121 | [`121 libbox-1.14-adoption/`](121%20libbox-1.14-adoption/) | Адаптация на ядро sing-box 1.14 (libbox 1.14 API) | Реализовано |
| 122 | [`122 commandclient-migration/`](122%20commandclient-migration/) | Переход управляющего канала на libbox CommandClient (отказ от Clash API) | Реализовано |
| 123 | [`123 subscription-model/`](123%20subscription-model/) | Модель подписок BoxService / CommandClient (три клиента, энергомодель) | Реализовано |
| 124 | [`124 background-mode-tunnel-sleep/`](124%20background-mode-tunnel-sleep/) | Tunnel sleep mode (`never`/`lazy`/`always`): pause/wake туннеля ради батареи; инвариант «нет утечки на паузе» | Реализовано |
| 125 | [`125 configurable-channels/`](125%20configurable-channels/) | Настраиваемые каналы роутинга (CRUD ≤10, node_filter, auto-двойник) | Реализовано (v2.6.0) |
| 126 | [`126 first-run-wizard/`](126%20first-run-wizard/) | Мастер первого запуска | Реализовано (v2.8.0) |
| 127 | [`127 xhttp-full-url-params/`](127%20xhttp-full-url-params/) | Полный XHTTP: URL-параметры транспорта | Реализовано (v2.8.0) |
| 128 | [`128 idle-suspend/`](128%20idle-suspend/) | Idle-suspend туннеля (`route.lx_idle_suspend`, kernel SPEC 020) | Реализовано (v2.8.2) |
| 129 | [`129 file-subscription/`](129%20file-subscription/) | Подписка из файла (`file:<uuid>`) + редактируемый источник online↔file | Реализовано (v2.8.2) |
| 130 | [`130 masque-warp-transport/`](130%20masque-warp-transport/) | MASQUE-транспорт для WARP (QUIC/CONNECT-IP) | Реализовано (v2.9.0) |
| 234 | [`234 server-folders/`](234%20server-folders/) | Папки серверов (folder): контейнер ручных серверов, per-member toggle, перенос между папками | Спека |

## Демотированные / superseded (теперь в `../tasks/`)

| Старый № | Что было | Куда переехало |
|----------|----------|----------------|
| 001 | Mobile stack decision | [`../tasks/055-mobile-stack-decision/`](../tasks/055-mobile-stack-decision/) |
| 002 | MVP scope | [`../tasks/056-mvp-scope-historical/`](../tasks/056-mvp-scope-historical/) |
| 004x | Subscription parser v1 (superseded by §026) | [`../tasks/057-subscription-parser-v1-superseded/`](../tasks/057-subscription-parser-v1-superseded/) |
| 005x | Config generator v1 (superseded by §026) | [`../tasks/058-config-generator-wizard-v1-superseded/`](../tasks/058-config-generator-wizard-v1-superseded/) |
| 013 | Routing v1 (superseded by §030) | [`../tasks/059-routing-v1-superseded/`](../tasks/059-routing-v1-superseded/) |
| 039 | libbox 1.13 migration (one-shot) | [`../tasks/060-libbox-1-13-migration/`](../tasks/060-libbox-1-13-migration/) |
| 041 | DNS rules refactor (live spec → §014) | [`../tasks/061-dns-rules-refactor/`](../tasks/061-dns-rules-refactor/) |
