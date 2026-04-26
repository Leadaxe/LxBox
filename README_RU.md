# L×Box

[![GitHub](https://img.shields.io/badge/GitHub-Leadaxe%2FLxBox-blue)](https://github.com/Leadaxe/LxBox)
[![License](https://img.shields.io/badge/License-GPLv3-blue.svg)](LICENSE)
[![Version](https://img.shields.io/github/v/release/Leadaxe/LxBox?label=version)](https://github.com/Leadaxe/LxBox/releases)
[![Dart](https://img.shields.io/badge/Dart-3.11%2B-blue)](https://dart.dev/)

Android-клиент с глубокими оптимизациями по производительности и безопасности [sing-box](https://sing-box.sagernet.org/) для гибкой маршрутизации сетевого трафика, предназначенный для сетевых специалистов различного уровня подготовики. Мульти-подписки, умные правила, встроенный тест скорости.

**[Скачать последний релиз](https://github.com/Leadaxe/LxBox/releases/latest)** | **[English README](README.md)**

---

## Скриншоты







---

## Возможности

**Серверы и подписки** — управление источниками прокси

Добавляйте серверы по URL подписки, прямой ссылке, WireGuard URI/INI или raw sing-box JSON outbound. Умный диалог вставки определяет формат автоматически и показывает превью. Включение/отключение подписок без удаления. Офлайн-rehydrate — ноды восстанавливаются из кеша тела при старте app. Per-subscription настройки detour серверов.

- **10 протоколов**: VLESS, VMess, Trojan, Shadowsocks, Hysteria2, **TUIC v5**, **NaïveProxy**, SSH, SOCKS, WireGuard
- Форматы: Base64, Xray JSON Array (chained proxy), plain text, raw sing-box JSON
- Per-subscription picker **Update interval** (1/3/6/12/24/48/72/168h), учитывает заголовок `profile-update-interval`
- Subtitle в строке подписки: `124 nodes · 🔄 24h · 🕐 3h ago · (2 fails)`
- Fallback имени из `Content-Disposition: filename=...` (RFC 5987)
- Быстрый старт с комьюнити-курируемой подборкой тестовых серверов

**Автообновление подписок** — 4 триггера, жёсткие гейты против спама

Подписки обновляются в фоне без спама провайдерам. Каждый запрос зажат в рамки, процессов в свободном полёте нет.

- **Триггеры**: запуск app · через 2 мин после активации туннеля · раз в час · сразу по остановке туннеля · manual ⟳ (force)
- **Gates**: `minRetryInterval=15min` (persisted через `lastUpdateAttempt`), `maxFailsPerSession=5` (in-memory, размораживается на рестарт app), `10s ± 2s` между подписками, `_running`/`_inFlight` dedup-флаги, `inProgress` guard от двойных кликов
- Crash-safe init sweep: зависший `inProgress` на диске сбрасывается в `failed`
- Rebuild config **никогда** не триггерит HTTP — только локальная сборка из загруженных nodes
- См. [спека 027](docs/spec/features/027%20subscription%20auto%20update/spec.md)

**Главный экран** — подключение и управление нодами

Запуск/остановка туннеля одним нажатием с анимированным статусом. Выбор группы прокси, сортировка нод по пингу/имени, массовый пинг. Панель трафика с реалтайм скоростью, соединениями и аптаймом.

- **Разметка строки ноды** (v1.3.1+): `[ACTIVE зелёная] ПРОТОКОЛ · · · 50MS →` — лейбл протокола (VLESS/Hy2/WG/TUIC/SS) из типа outbound'а, ping справа с цветом по latency
- Группы прокси: `auto-proxy-out`, VPN ①/②/③
- Фильтр нод: выбор участников автоподбора
- Переключатель видимости detour серверов (⚙)
- Sticky restart warning под Stop — не пропадает при отмене Stop-диалога
- Long-press: Ping · Use this node · View JSON · **Copy URI** (vless://, wireguard://, …) · Copy server (JSON) · Copy detour · Copy server + detour

**Маршрутизация** — единая модель правил (v1.4.0)

Блокировка рекламы, прямая маршрутизация для .ru доменов, BitTorrent через прокси, per-app, матчинг приватных IP. Все пользовательские правила — единый `CustomRule` со всеми match-полями параллельно (OR внутри категории, AND между — per sing-box default rule formula).

- **3 вкладки**: Channels (proxy groups) · Presets (read-only каталог → Copy to Rules) · Rules (твой реестр)
- **Match-поля**: domain, domain_suffix, domain_keyword, ip_cidr, port, port_range, packages (per-app), protocols (tls/quic/bittorrent/…), ip_is_private, remote .srs rule-set
- **SRS только локально** — никаких авто-обновлений, ручное скачивание через ☁, правило заблокировано пока нет кэша
- **Drag-reorder** + **long-press → Delete с подтверждением**
- **Params / View табы** в редакторе — View показывает готовый sing-box-фрагмент конфига
- **Dirty-aware save** — back с несохранёнными → диалог "Discard changes?"
- Fallback для нераспознанного трафика (`route.final`)
- См. [спека 030](docs/spec/features/030%20custom%20routing%20rules/spec.md), [спека 011](docs/spec/features/011%20local%20ruleset%20cache/spec.md)

**Detour серверы** — цепочки прокси для приватности

Multi-hop цепочки: трафик идёт через промежуточный сервер перед финальным прокси. Полезно при работе в сетях с гео-ограничениями на уровне провайдера или локали: поставьте домашний WireGuard как detour → заграничный мобильный интернет превращается в тоннель к дому.

- Добавил свой сервер (paste URI / paste JSON / WG INI) — он становится кандидатом для detour
- **Mark as detour server** switch в Node Settings — добавляет префикс `⚙` 
- **Override detour** per-subscription: маршрутизирует все её ноды через ваш сервер
- Register / Use toggles для detour-серверов из подписок
- Detour dropdown в Node Settings persist'ит через `overrideDetour` (без JSON roundtrip drift'а)

**Настройки DNS** — полный контроль резолвинга

16 пресетов DNS (Cloudflare, Google, Yandex, Quad9, AdGuard) с UDP/DoT/DoH вариантами. Кастомные серверы через JSON. Стратегия, кэш, правила.

- Включение/отключение серверов переключателями
- Стратегия DNS: prefer_ipv4 / prefer_ipv6 / ipv4_only / ipv6_only
- Редактор правил DNS, DNS Final, Default Domain Resolver
- Bundle-пресет "Russian domains direct" (spec 033) — self-contained правило `.ru/.su/.рф/.рус/.москва/.moscow/.tatar/.дети/.онлайн/.сайт/.орг/.ком` + свои Yandex DNS-серверы + переменные `@out`/`@dns_server`

**Устойчивость соединений** — совместимость с packet inspection

Три ортогональных параметра тюнинга TLS-handshake — комбинируются на одном outbound.

- **TLS Fragment** — разбивает ClientHello по TCP-сегментам
- **TLS Record Fragment** — разбивает handshake на несколько TLS-записей
- **Mixed-case SNI** (v1.3.0+) — рандомизирует регистр `server_name` (`WwW.gOoGle.CoM`). Повышает совместимость с системами инспекции пакетов, использующими exact-match по SNI. По RFC 6066 поле case-insensitive — сервер обрабатывает любой регистр без изменения поведения. Менее эффективно против систем с нормализацией.
- Все параметры применяются только к первому хопу (внутренние хопы идут внутри туннеля и не требуют дополнительной обработки).

**Haptic feedback** — вибро на события туннеля

Короткая вибрация на состояниях туннеля, ошибках и тапах. Респектит системную настройку Android Touch feedback.

- Tap Start/Stop → лёгкий tick
- Туннель активирован → средний impact; user disconnect → лёгкий
- Revoked / heartbeat fail (только **первый**, не на каждый tick) → тяжёлый
- Manual subscription fetch success/fail → лёгкий/средний
- Авто-триггеры не вибрируют; throttle 100 мс защищает от спама
- Toggle в App Settings → Feedback (default **on**)
- См. [спека 029](docs/spec/features/029%20haptic%20feedback/spec.md)

**Тест скорости** — измерение соединения

Встроенный тест скорости с 10 серверами по всему миру. Per-server пинг к конкретному серверу скачивания. Параллельные потоки, upload тест, история за сессию.

- Серверы: Cloudflare, Hostkey (5 городов), Selectel, Tele2, OVH, ThinkBroadband
- Настраиваемые потоки (1/4/10), upload method per server
- История с именем сервера

**Статистика и соединения** — что происходит

Реалтайм трафик по outbound с раскрывающимися карточками. Каждое соединение: хост, протокол, правило, трафик, длительность, цепочка прокси, имя приложения. Закрытие отдельных соединений.



**Настройки ядра** — конфигурация маршрутизации

Организованы по секциям: General, Clash API, Network, Include Auto, DNS, TUN, Connection Resilience. URLTest параметры для авто-подбора прокси. Все изменения автосохраняются.



**Редактор конфига** — для продвинутых

Просмотр и редактирование raw JSON конфига sing-box. Форматированное отображение с кнопкой копирования. Сохранение, вставка, загрузка, шаринг.



**Настройки приложения**

- Тема: Системная / Светлая / Тёмная
- Автозапуск туннеля при загрузке
- Туннель остаётся при закрытии приложения
- Авто-пересборка конфига при изменениях
- **Battery optimization** tile — статус + shortcut в системный whitelist (v1.4.0)
- **App info (OEM power settings)** с hint-диалогом для Autostart / Background activity (v1.4.0)
- **Auto-ping after connect** — пинг активной группы через 5s после подключения VPN (по умолчанию ON, v1.4.0)
- Haptic feedback toggle
- См. [спека 022](docs/spec/features/022%20app%20settings/spec.md)

---

## Поддерживаемые протоколы


| Протокол    | URI-схема                          | Транспорт                                      |
| ----------- | ---------------------------------- | ---------------------------------------------- |
| VLESS       | `vless://`                         | TCP, WebSocket, gRPC, H2, HTTPUpgrade, REALITY |
| VMess       | `vmess://` (v2rayN base64)         | TCP, WebSocket, gRPC, H2, HTTPUpgrade          |
| Trojan      | `trojan://`                        | TCP, WebSocket, gRPC                           |
| Shadowsocks | `ss://` (SIP002 + legacy + SS2022) | TCP, UDP, SIP003-плагины                       |
| Hysteria2   | `hy2://` / `hysteria2://`          | QUIC, Salamander obfs                          |
| **TUIC v5** | `tuic://`                          | QUIC, BBR/CUBIC/NewReno, zero-RTT              |
| **NaïveProxy** | `naive+https://`                | Настоящий Chrome TLS через cronet, `extra-headers` |
| SSH         | `ssh://`                           | TCP, host key / password / private key         |
| SOCKS       | `socks://` / `socks5://`           | TCP, auth                                      |
| WireGuard   | `wireguard://`, INI config         | UDP, multi-peer                                |


**XHTTP transport** автоматически fallback'ится в HTTPUpgrade (sing-box 1.12.x не поддерживает xhttp напрямую) — warning отображается в UI.

Подробная документация: [docs/PROTOCOLS.md](docs/PROTOCOLS.md)

---

## Архитектура

L×Box построен вокруг **3-слойного parser/builder pipeline** (спека 026, v1.3.0+):

```
UI / Controller
  │
  ▼
parseFromSource(source)  ← HTTP fetch + body_decoder + типизированный parser
  │                         returns: List<NodeSpec>, meta, rawBody
  ▼
ServerList (sealed)      ← SubscriptionServers | UserServer
  │ .build(ctx)            применяет tagPrefix, detour policy, allocateTag
  ▼
buildConfig(lists, settings)  ← template + post-steps (resilience, DNS, rules)
  │                              returns: BuildResult{ config, validation, warnings }
  ▼
sing-box JSON
```

- **Sealed `NodeSpec`** — 9 протоколов, полиморфный `emit(vars)` / `toUri()` (round-trip инвариант)
- `**EmitContext**` — пробрасывает шаблонные vars в per-node emit
- `**NodeEntries{main, detours[]}**` — именованный struct для chain-результатов
- `**ValidationResult**` — типизированные issues: dangling refs, empty urltest, invalid selector default

Полная картина: [Архитектура](docs/ARCHITECTURE.md).

---

## Разработка

Spec-driven development — 30 спецификаций фич в [docs/spec/features/](docs/spec/features/).


| Документ                                     | Описание                                                  |
| -------------------------------------------- | --------------------------------------------------------- |
| [Документация протоколов](docs/PROTOCOLS.md) | URI форматы, параметры, маппинг в sing-box                |
| [Архитектура](docs/ARCHITECTURE.md)          | 3-слойный pipeline, потоки данных, нативный bridge        |
| [Сборка](docs/BUILD.md)                      | Инструкции по сборке, CI, подпись APK, local-build marker |
| [Руководство](docs/DEVELOPMENT_GUIDE.md)     | Принципы, тестирование (167 тестов), организация спек     |
| [Список изменений](CHANGELOG.md)             | История релизов                                           |
| [Release notes](docs/releases/)              | Подробные заметки per-версия (EN + RU)                    |


### Локальная сборка

```bash
./scripts/build-local-apk.sh
```

Скрипт оборачивает `flutter build apk --release` с `--dart-define`'ами, которые подмешивают git describe. About screen показывает розовую плашку **🧪 LOCAL BUILD · N commits since vX.Y.Z** — чтобы отличать от CI-билдов.

---

## Безопасность

- **Только TUN inbound** — нет SOCKS5/HTTP прокси на localhost (защита от утечки IP)
- **Clash API** на рандомном порту с обязательным секретом
- **VPN Service** не экспортирован (`android:exported="false"`)
- **Геомаршрутизация**: российские домены → direct (не через прокси)
- Secret генерируется криптографически безопасным ГПСЧ

---

## Лицензия

L×Box распространяется на условиях [GNU General Public License v3.0](LICENSE).

Коммерческая лицензия у Leadaxe — для сценариев, несовместимых с GPLv3. **Условия коммерческой лицензии согласовываются отдельно и не публикуются** в этом репозитории. Связь: [ledaxe@gmail.com](mailto:ledaxe@gmail.com). Подробнее: [LICENSING.md](LICENSING.md).