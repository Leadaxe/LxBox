# L×Box

Android VPN-клиент на базе [sing-box](https://sing-box.sagernet.org/). Мульти-подписки, умная маршрутизация, встроенный тест скорости.

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
<img src="docs/screenshots/vpn_settings.jpg" width="240" alt="Настройки VPN"/>
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

Добавляйте серверы по URL подписки, прямой ссылке, WireGuard конфигу или JSON outbound. Умный диалог вставки определяет формат автоматически. Включение/отключение подписок без удаления. Офлайн-кэширование. Per-subscription настройки detour серверов.

- 8 протоколов: VLESS, VMess, Trojan, Shadowsocks, Hysteria2, SSH, SOCKS, WireGuard
- Форматы: Base64, Xray JSON Array (chained proxy), plain text, raw JSON
- Автообновление при запуске VPN, квота трафика, срок действия
- Быстрый старт с бесплатным VPN пресетом
</details>

<details>
<summary><strong>Главный экран</strong> — подключение и управление нодами</summary>

Запуск/остановка VPN одним нажатием с анимированным статусом. Выбор группы прокси, сортировка нод по пингу/имени, массовый пинг. Панель трафика с реалтайм скоростью, соединениями и аптаймом.

- Группы прокси: auto-proxy, ручной выбор, VPN-1, VPN-2
- Фильтр нод: выбор участников автоподбора
- Переключатель видимости detour серверов (⚙)
- Длинное нажатие на пинг — пресеты URL
</details>

<details>
<summary><strong>Маршрутизация</strong> — контроль трафика</summary>

Гибкое управление маршрутизацией. Блокировка рекламы, прямой доступ к российским доменам, BitTorrent через прокси. Именованные группы приложений с per-app маршрутизацией.

- Предустановленные правила с выбором outbound
- Группы приложений: маршрутизация конкретных приложений через выбранный прокси
- Fallback для нераспознанного трафика (route.final)
- Все изменения сохраняются автоматически
</details>

<details>
<summary><strong>Detour серверы</strong> — цепочки прокси для приватности</summary>

Создавайте multi-hop цепочки: трафик проходит через промежуточный сервер перед финальным прокси. Per-subscription управление: регистрация в списке нод, включение/отключение, переопределение на свой сервер.

- ⚙ префикс для detour серверов
- Register / Use / Override на уровне подписки
- Detour dropdown в настройках ноды
</details>

<details>
<summary><strong>Настройки DNS</strong> — полный контроль резолвинга</summary>

16 пресетов DNS (Cloudflare, Google, Yandex, Quad9, AdGuard) с UDP/DoT/DoH вариантами. Кастомные серверы через JSON. Стратегия, кэш, правила.

- Включение/отключение серверов переключателями
- Стратегия DNS: prefer_ipv4 / prefer_ipv6 / ipv4_only / ipv6_only
- Редактор правил DNS, DNS Final, Default Domain Resolver
</details>

<details>
<summary><strong>Обход DPI</strong> — обход интернет-цензуры</summary>

TLS Fragment разбивает начальный handshake для обхода Deep Packet Inspection. Два режима: TCP-фрагментация и TLS record фрагментация. Применяется только к первому хопу — detour трафик уже в туннеле.

- TLS Fragment / Record Fragment переключатели
- Настройка fallback delay
- Только первый хоп (внутренние — без фрагментации)
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
<summary><strong>Настройки VPN</strong> — настройка ядра</summary>

Организованы по секциям: General, Clash API, Network, Auto Proxy, DNS, TUN, DPI Bypass. URLTest параметры для авто-подбора прокси. Все изменения сохраняются автоматически.
</details>

<details>
<summary><strong>Редактор конфига</strong> — для продвинутых</summary>

Просмотр и редактирование raw JSON конфига sing-box. Форматированное отображение с кнопкой копирования. Сохранение, вставка, загрузка, шаринг.
</details>

<details>
<summary><strong>Настройки приложения</strong></summary>

- Тема: Системная / Светлая / Тёмная
- Автозапуск VPN при загрузке
- VPN остаётся при закрытии приложения
- Авто-пересборка конфига при изменениях
</details>

---

## Поддерживаемые протоколы

| Протокол | URI-схема | Транспорт |
|----------|-----------|-----------|
| VLESS | `vless://` | TCP, WebSocket, gRPC, H2, REALITY |
| VMess | `vmess://` (v2rayN base64) | TCP, WebSocket, gRPC, H2 |
| Trojan | `trojan://` | TCP, WebSocket, gRPC |
| Shadowsocks | `ss://` (SIP002 + legacy) | TCP, UDP |
| Hysteria2 | `hy2://` / `hysteria2://` | QUIC |
| SSH | `ssh://` | TCP |
| SOCKS | `socks://` / `socks5://` | TCP |
| WireGuard | `wireguard://` | UDP |

Подробная документация: [docs/PROTOCOLS.md](docs/PROTOCOLS.md)

---

## Разработка

Проект использует **spec-driven development** — [25 спецификаций фич](docs/spec/features/).

| Документ | Описание |
|----------|----------|
| [Документация протоколов](docs/PROTOCOLS.md) | URI форматы, параметры, маппинг в sing-box |
| [Архитектура](docs/ARCHITECTURE.md) | Потоки данных, конфиг pipeline, нативный код |
| [Сборка](docs/BUILD.md) | Инструкции по сборке, CI, подпись APK |
| [Руководство](docs/DEVELOPMENT_GUIDE.md) | Принципы, риски, AI workflow |
| [Список изменений](CHANGELOG.md) | История релизов |

---

## Безопасность

Подробнее: [спека 020](docs/spec/features/020%20security%20and%20dpi%20bypass/spec.md)

- **Только TUN inbound** — нет SOCKS5/HTTP прокси на localhost (защита от утечки IP)
- **Clash API** на рандомном порту с обязательным секретом
- **VPN Service** не экспортирован (`android:exported="false"`)
- **Геомаршрутизация**: российские домены → direct (не через прокси)
- Secret генерируется криптографически безопасным ГПСЧ

---

## Лицензия

Уточняется.
