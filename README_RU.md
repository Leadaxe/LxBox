# L×Box

Android-клиент [sing-box](https://sing-box.sagernet.org/) для гибкой маршрутизации сетевого трафика. Мульти-подписки, умные правила, встроенный тест скорости.

**[Скачать последний релиз](https://github.com/Leadaxe/LxBox/releases/latest)**

---

## Скриншоты

<p align="center">
<img src="docs/screenshots/home.jpg" width="240" alt="Главный экран"/>
<img src="docs/screenshots/routing.jpg" width="240" alt="Маршрутизация"/>
<img src="docs/screenshots/statistics.jpg" width="240" alt="Статистика"/>
</p>
<p align="center">
<img src="docs/screenshots/speed_test.jpg" width="240" alt="Тест скорости"/>
<img src="docs/screenshots/dns_settings.jpg" width="240" alt="Настройки DNS"/>
<img src="docs/screenshots/vpn_settings.jpg" width="240" alt="Настройки маршрутизации"/>
</p>
<p align="center">
<img src="docs/screenshots/routing_rules.jpg" width="240" alt="Правила маршрутизации и группы приложений"/>
<img src="docs/screenshots/app_picker.jpg" width="240" alt="Выбор приложений"/>
<img src="docs/screenshots/app_settings.jpg" width="240" alt="Настройки приложения"/>
</p>

---

## Возможности

<details>
<summary><strong>Серверы и подписки</strong> — управление источниками прокси</summary>

Добавляйте серверы по URL подписки, прямой ссылке, WireGuard URI/INI или raw sing-box JSON outbound. Умный диалог вставки определяет формат автоматически и показывает превью. Включение/отключение подписок без удаления. Офлайн-rehydrate — ноды восстанавливаются из кеша тела при старте app. Per-subscription настройки detour серверов.

- **9 протоколов**: VLESS, VMess, Trojan, Shadowsocks, Hysteria2, **TUIC v5**, SSH, SOCKS, WireGuard
- Форматы: Base64, Xray JSON Array (chained proxy), plain text, raw sing-box JSON
- Per-subscription picker **Update interval** (1/3/6/12/24/48/72/168h), учитывает заголовок `profile-update-interval`
- Subtitle в строке подписки: `124 nodes · 🔄 24h · 🕐 3h ago · (2 fails)`
- Fallback имени из `Content-Disposition: filename=...` (RFC 5987)
- Быстрый старт с комьюнити-курируемой подборкой тестовых серверов
</details>

<details>
<summary><strong>Автообновление подписок</strong> — 4 триггера, жёсткие гейты против спама</summary>

Подписки обновляются в фоне без спама провайдерам. Каждый запрос зажат в рамки, процессов в свободном полёте нет.

- **Триггеры**: запуск app · через 2 мин после активации туннеля · раз в час · сразу по остановке туннеля · manual ⟳ (force)
- **Gates**: `minRetryInterval=15min` (persisted через `lastUpdateAttempt`), `maxFailsPerSession=5` (in-memory, размораживается на рестарт app), `10s ± 2s` между подписками, `_running`/`_inFlight` dedup-флаги, `inProgress` guard от двойных кликов
- Crash-safe init sweep: зависший `inProgress` на диске сбрасывается в `failed`
- Rebuild config **никогда** не триггерит HTTP — только локальная сборка из загруженных nodes
- См. [спека 027](docs/spec/features/027%20subscription%20auto%20update/spec.md)
</details>

<details>
<summary><strong>Главный экран</strong> — подключение и управление нодами</summary>

Запуск/остановка туннеля одним нажатием с анимированным статусом. Выбор группы прокси, сортировка нод по пингу/имени, массовый пинг. Панель трафика с реалтайм скоростью, соединениями и аптаймом.

- **Разметка строки ноды** (v1.3.1+): `[ACTIVE зелёная] ПРОТОКОЛ · · · 50MS →` — лейбл протокола (VLESS/Hy2/WG/TUIC/SS) из типа outbound'а, ping справа с цветом по latency
- Группы прокси: `auto-proxy-out`, VPN ①/②/③
- Фильтр нод: выбор участников автоподбора
- Переключатель видимости detour серверов (⚙)
- Sticky restart warning под Stop — не пропадает при отмене Stop-диалога
- Long-press: Ping · Use this node · View JSON · **Copy URI** (vless://, wireguard://, …) · Copy server (JSON) · Copy detour · Copy server + detour
</details>

<details>
<summary><strong>Маршрутизация</strong> — контроль трафика</summary>

Гибкое управление маршрутизацией. Блокировка рекламы, прямой доступ к российским доменам, BitTorrent через прокси. Именованные группы приложений с per-app маршрутизацией.

- Предустановленные правила с выбором outbound
- Группы приложений: маршрутизация конкретных приложений через выбранный прокси
- Fallback для нераспознанного трафика (`route.final`)
- Все изменения автосохраняются, restart warning сам всплывает
</details>

<details>
<summary><strong>Detour серверы</strong> — цепочки прокси для приватности</summary>

Multi-hop цепочки: трафик идёт через промежуточный сервер перед финальным прокси. Полезно при работе в сетях с гео-ограничениями на уровне провайдера или локали: поставьте домашний WireGuard как detour → заграничный мобильный интернет превращается в тоннель к дому.

- Добавил свой сервер (paste URI / paste JSON / WG INI) — он становится кандидатом для detour
- **Mark as detour server** switch в Node Settings — добавляет префикс `⚙ `
- **Override detour** per-subscription: маршрутизирует все её ноды через ваш сервер
- Register / Use toggles для detour-серверов из подписок
- Detour dropdown в Node Settings persist'ит через `overrideDetour` (без JSON roundtrip drift'а)
</details>

<details>
<summary><strong>Настройки DNS</strong> — полный контроль резолвинга</summary>

16 пресетов DNS (Cloudflare, Google, Yandex, Quad9, AdGuard) с UDP/DoT/DoH вариантами. Кастомные серверы через JSON. Стратегия, кэш, правила.

- Включение/отключение серверов переключателями
- Стратегия DNS: prefer_ipv4 / prefer_ipv6 / ipv4_only / ipv6_only
- Редактор правил DNS, DNS Final, Default Domain Resolver
- Inline `.ru/.su/.xn--p1ai` правило для Yandex DoH
</details>

<details>
<summary><strong>Устойчивость соединений</strong> — совместимость с packet inspection</summary>

Три ортогональных параметра тюнинга TLS-handshake — комбинируются на одном outbound.

- **TLS Fragment** — разбивает ClientHello по TCP-сегментам
- **TLS Record Fragment** — разбивает handshake на несколько TLS-записей
- **Mixed-case SNI** (v1.3.0+) — рандомизирует регистр `server_name` (`WwW.gOoGle.CoM`). Повышает совместимость с системами инспекции пакетов, использующими exact-match по SNI. По RFC 6066 поле case-insensitive — сервер обрабатывает любой регистр без изменения поведения. Менее эффективно против систем с нормализацией.
- Все параметры применяются только к первому хопу (внутренние хопы идут внутри туннеля и не требуют дополнительной обработки).
</details>

<details>
<summary><strong>Haptic feedback</strong> — вибро на события туннеля</summary>

Короткая вибрация на состояниях туннеля, ошибках и тапах. Респектит системную настройку Android Touch feedback.

- Tap Start/Stop → лёгкий tick
- Туннель активирован → средний impact; user disconnect → лёгкий
- Revoked / heartbeat fail (только **первый**, не на каждый tick) → тяжёлый
- Manual subscription fetch success/fail → лёгкий/средний
- Авто-триггеры не вибрируют; throttle 100 мс защищает от спама
- Toggle в App Settings → Feedback (default **on**)
- См. [спека 029](docs/spec/features/029%20haptic%20feedback/spec.md)
</details>

<details>
<summary><strong>Тест скорости</strong> — измерение соединения</summary>

Встроенный тест скорости с 10 серверами по всему миру. Per-server пинг к конкретному серверу скачивания. Параллельные потоки, upload тест, история за сессию.

- Серверы: Cloudflare, Hostkey (5 городов), Selectel, Tele2, OVH, ThinkBroadband
- Настраиваемые потоки (1/4/10), upload method per server
- История с именем сервера
</details>

<details>
<summary><strong>Статистика и соединения</strong> — что происходит</summary>

Реалтайм трафик по outbound с раскрывающимися карточками. Каждое соединение: хост, протокол, правило, трафик, длительность, цепочка прокси, имя приложения. Закрытие отдельных соединений.
</details>

<details>
<summary><strong>Настройки ядра</strong> — конфигурация маршрутизации</summary>

Организованы по секциям: General, Clash API, Network, Include Auto, DNS, TUN, Connection Resilience. URLTest параметры для авто-подбора прокси. Все изменения автосохраняются.
</details>

<details>
<summary><strong>Редактор конфига</strong> — для продвинутых</summary>

Просмотр и редактирование raw JSON конфига sing-box. Форматированное отображение с кнопкой копирования. Сохранение, вставка, загрузка, шаринг.
</details>

<details>
<summary><strong>Настройки приложения</strong></summary>

- Тема: Системная / Светлая / Тёмная
- Автозапуск туннеля при загрузке
- Туннель остаётся при закрытии приложения
- Авто-пересборка конфига при изменениях
- Haptic feedback toggle
</details>

---

## Поддерживаемые протоколы

| Протокол | URI-схема | Транспорт |
|----------|-----------|-----------|
| VLESS | `vless://` | TCP, WebSocket, gRPC, H2, HTTPUpgrade, REALITY |
| VMess | `vmess://` (v2rayN base64) | TCP, WebSocket, gRPC, H2, HTTPUpgrade |
| Trojan | `trojan://` | TCP, WebSocket, gRPC |
| Shadowsocks | `ss://` (SIP002 + legacy + SS2022) | TCP, UDP, SIP003-плагины |
| Hysteria2 | `hy2://` / `hysteria2://` | QUIC, Salamander obfs |
| **TUIC v5** | `tuic://` | QUIC, BBR/CUBIC/NewReno, zero-RTT |
| SSH | `ssh://` | TCP, host key / password / private key |
| SOCKS | `socks://` / `socks5://` | TCP, auth |
| WireGuard | `wireguard://`, INI config | UDP, multi-peer |

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
- **`EmitContext`** — пробрасывает шаблонные vars в per-node emit
- **`NodeEntries{main, detours[]}`** — именованный struct для chain-результатов
- **`ValidationResult`** — типизированные issues: dangling refs, empty urltest, invalid selector default

Полная картина: [Архитектура](docs/ARCHITECTURE.md).

---

## Разработка

Spec-driven development — 29 спецификаций фич в [docs/spec/features/](docs/spec/features/).

| Документ | Описание |
|----------|----------|
| [Документация протоколов](docs/PROTOCOLS.md) | URI форматы, параметры, маппинг в sing-box |
| [Архитектура](docs/ARCHITECTURE.md) | 3-слойный pipeline, потоки данных, нативный bridge |
| [Сборка](docs/BUILD.md) | Инструкции по сборке, CI, подпись APK, local-build marker |
| [Руководство](docs/DEVELOPMENT_GUIDE.md) | Принципы, тестирование (128 тестов), организация спек |
| [Список изменений](CHANGELOG.md) | История релизов |
| [Release notes](docs/releases/) | Подробные заметки per-версия (EN + RU) |

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

Уточняется.
