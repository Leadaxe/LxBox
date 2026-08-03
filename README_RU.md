# L×Box

[![GitHub](https://img.shields.io/badge/GitHub-Leadaxe%2FLxBox-blue)](https://github.com/Leadaxe/LxBox)
[![License](https://img.shields.io/badge/License-GPLv3-blue.svg)](LICENSE)
[![Version](https://img.shields.io/github/v/release/Leadaxe/LxBox?label=version)](https://github.com/Leadaxe/LxBox/releases)
[![Dart](https://img.shields.io/badge/Dart-3.11%2B-blue)](https://dart.dev/)

Android-клиент на ядре [sing-box-lx](https://github.com/Leadaxe/sing-box-lx) — форке [sing-box](https://sing-box.sagernet.org/) с AmneziaWG 2.0 и нативным XHTTP — для гибкой маршрутизации сетевого трафика. Мульти-подписки, умные правила, встроенный тест скорости. Интерфейс на русском и английском.

**[Скачать последний релиз](https://github.com/Leadaxe/LxBox/releases/latest)** | **[English README](README.md)** | **[Руководство пользователя](docs/USER_GUIDE_RU.md)** | **[Поддержать проект](docs/DONATE_RU.md)**

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
<img src="docs/screenshots/routing_rules.jpg" width="240" alt="Правила маршрутизации"/>
<img src="docs/screenshots/app_picker.jpg" width="240" alt="Выбор приложений"/>
<img src="docs/screenshots/app_settings.jpg" width="240" alt="Настройки приложения"/>
</p>

---

## Возможности

<details>
<summary><strong>Серверы и подписки</strong> — все источники прокси в одном месте</summary>

Добавляйте серверы по URL подписки, прямой ссылке, WireGuard URI/INI, Amnezia `vpn://`-ссылке, raw sing-box JSON — отдельным outbound'ом или **конфигом целиком**, из которого приезжают узлы, группы автовыбора и цепочки detour (§368) — или через **Import from file…** (локальный `.txt`/`.json`; файл более чем с одной нодой становится файловой подпиской, §129). Умный диалог вставки определяет формат автоматически и показывает превью. Включение/отключение подписок без удаления. Офлайн-rehydrate — ноды восстанавливаются из кеша тела при старте приложения.

- **12 протоколов**: VLESS (вкл. постквантовое шифрование ML-KEM-768, §335), VMess, Trojan, Shadowsocks, Hysteria2, **TUIC v5**, **NaïveProxy**, **AnyTLS** (§269), SSH, SOCKS, WireGuard (вкл. **AmneziaWG / AWG 2.0** — `awg://` URI, AmneziaWG `.conf`, **Amnezia `vpn://`-ссылки**, JSON), **MASQUE** (Cloudflare WARP — `masque://`, QUIC/HTTP-3)
- Форматы: Base64, Xray JSON Array (вкл. цепочки dialerProxy и все протоколы массива, §321), plain text, sing-box JSON — outbound, массив, конфиг целиком или массив конфигов, с группами и цепочками `detour` (§368)
- **Дедупликация узлов** (§321) — один сервер, перечисленный в подписке несколько раз, становится одним узлом
- **Авто-узлы** (§322) — провайдерский пункт «Авто | Лучший сервер» приезжает одним узлом с пулом внутри: в строке виден режим и состав (`🔀 [15/7]` — балансировка, `🎯 [3]` — один быстрейший). Свой авто-узел можно собрать в папке: «Add auto node…» — членство по regex-правилу, списку галочками или «все серверы папки»
- **Отключение отдельных узлов** (§283) — переключатель у каждого узла подписки; выбор привязан к устойчивому хешу узла и переживает обновления, перезапуски и переименования у провайдера
- **Filters — правила обработки подписки** (§302) — применяются при импорте и каждом обновлении: условия `путь оператор значение` (contains/equals/regex, Not, AND/OR), действия **Disable** / **Enable** (§332; последнее сработавшее правило побеждает — связка «выключить всё → включить NL» работает как белый список) / **Replace** (замена значения по пути, с карманами `$1`,`$2`… из regex-групп). Вкладка **Matches** показывает эффект правила до сохранения
- **Inspect node** (§302) — тап по узлу подписки: вкладка JSON (как узел уходит в конфиг) и Source (исходный фрагмент подписки); у Source галка **Decode base64** для закодированных тел
- **Fetch identity** (§289) — User-Agent / HWID / device-заголовки настраиваются per-подписка (Default = глобальные, Custom = свой набор); панели с HWID-гейтом вместо заглушки «App not supported» отдают реальные узлы (§310)
- **«При обновлении»** (§323/§331) — реакция на новый состав узлов: только пересобрать конфиг (по умолчанию), пересобрать и перезагрузить ядро, или ничего не делать; срабатывает лишь когда состав действительно изменился
- **Test servers** (§339) — пинг узлов подписки или папки без запуска VPN; при работающем VPN — явный гейт «Stop VPN / Cancel» вместо вранья поверх туннеля (§236)
- **Файловая подписка** (§129) — многоузловой локальный файл живёт как подписка с бейджем `file`; **Edit source…** меняет URL или переключает online↔file без пересоздания
- Per-subscription интервал обновления (1–168 ч), заголовок `profile-update-interval` уважается; опция «обновлять и выключенные подписки» (§337)
- Subtitle строки подписки: `124 nodes · 🔄 24h · 🕐 3h ago · (2 fails)`; имя из `Content-Disposition` (RFC 5987)
- **Get WARP** — Cloudflare WARP в один тап (WireGuard или MASQUE), см. ниже
</details>

<details>
<summary><strong>Get WARP</strong> — Cloudflare WARP в один тап, ключи генерятся на устройстве</summary>

Пункт **Get WARP** на экране серверов → регистрируется туннель к Cloudflare и добавляется как узел. Без копипасты конфигов с чужих сайтов-генераторов.

- **Транспорт**: **WireGuard** (по умолчанию) или **MASQUE** (CONNECT-IP поверх QUIC/HTTP-3, fallback HTTP/2 — часто выходит с заграничного IP и выглядит для DPI как обычный HTTPS). Для MASQUE выбираются h3/h2, SNI, idle/keep-alive.
- **Регистрация на устройстве**: приватный ключ генерится на телефоне и не покидает его — в Cloudflare (`api.cloudflareclient.com`) уходит только публичный (WireGuard — X25519, MASQUE — ECDSA P-256). Чужие воркеры-генераторы не используются: они отдают приватник, сгенерированный на их сервере.
- **Add Amnezia obfuscation** (транспорт WireGuard): маскирует WARP-handshake от DPI junk-трафиком, имитирующим QUIC-Initial (по умолчанию) или SIP; SNI, level и Jc/Jmin/Jmax — под *Advanced*. Включайте, когда чистый WARP режут или троттлят.
- **Persistent keepalive** (§304) — поле в *Advanced* (по умолчанию 25 с): без него оператор закрывает UDP-маппинг NAT при простое, и узел молча отваливается.
- **Свой endpoint** — ручной `IP:port` под *Advanced*; у MASQUE — выбор порта из проверенных рабочих (§305).
- **SCAN WARP** (§284) — кнопка **Make experiment** в визарде создаёт папку-эксперимент: генерирует пул WARP-вариантов (WireGuard / AWG / MASQUE h2/h3) по диапазонам адресов Cloudflare и прогоняет пингом; мёртвые узлы выключаются сами. Поиск рабочего эндпоинта на конкретной сети без ручного перебора.
- **WARP+** (опционально): license key под *Advanced* привязывает WARP+ (Argo Smart Routing). Пусто = бесплатный WARP.
- **Идемпотентность**: повторный тап переиспользует закешированный аккаунт; *Re-register* создаёт новый.
- См. [спека 025](docs/spec/features/025%20warp%20integration/spec.md)
</details>

<details>
<summary><strong>Автообновление подписок</strong> — 6 триггеров, жёсткие гейты против спама</summary>

Подписки обновляются в фоне без спама провайдерам. Каждый запрос зажат в рамки, процессов в свободном полёте нет.

- **Триггеры**: запуск приложения · возврат из фона (§291) · через 2 мин после активации туннеля · раз в час · сразу по остановке туннеля · ручной ⟳ (force)
- **Гейты**: `minRetryInterval=15min` (переживает рестарт через `lastUpdateAttempt`), `maxFailsPerSession=5`, `10s ± 2s` между подписками, dedup-флаги от параллельных прогонов и двойных кликов
- Crash-safe init sweep: зависший `inProgress` на диске сбрасывается в `failed`
- Пересборка конфига **никогда** не ходит в сеть — только локальная сборка из загруженных узлов
- См. [спека 027](docs/spec/features/027%20subscription%20auto%20update/spec.md)
</details>

<details>
<summary><strong>Главный экран</strong> — подключение и управление узлами</summary>

Запуск/остановка туннеля одним нажатием с анимированным статусом. Выбор канала, сортировка узлов по пингу/имени/вручную, массовый пинг. Панель трафика с реалтайм-скоростью, числом соединений и аптаймом.

- **Строка узла**: `[ACTIVE] ПРОТОКОЛ · · · 50MS` — лейбл протокола из типа outbound, пинг справа с цветом по задержке; подзаголовок `ПРОТОКОЛ · транспорт · security` (`VLESS·xhttp·TLS`, `WG·awg2`) — видно, что внутри узла, не открывая JSON
- **Авто-узлы в списке** (§322/§344) — строка показывает режим и живой состав пула (`🔀 [15/7]` с флагами стран); экран деталей узла знает про режимы urltest
- **⚠-граф зависимостей** (§355) — если узел с пингом ERR является detour'ом для других узлов или DNS-серверов, у имени появляется ⚠; тап открывает список пострадавших с путём зависимости, для DNS-ветки — баннер
- **Пинг per-канал** (§325) — у каждого канала свои замеры (адрес/таймаут проверки настраиваются per-канал); непроверенный в этом канале узел показывает замер из другого — приглушённо и со значком `~`
- **Filter workspace**: фильтр-панель **Regex · Protocol · Subscribes · Settings** + сводка чипами; у каждой категории своя `!`-инверсия; чипы по транспорту/безопасности (`tcp`/`ws`/`grpc`/`quic`/`xhttp` + `TLS`/`Reality`/`awg`…); фильтры запоминаются per-канал; regex регистронезависим во всех точках (§301)
- **Detour-фильтр tri-state**: показать всё / скрыть detour / только detour
- **Настраиваемые каналы** (§125) — до 10 каналов-групп (add/rename/delete; `vpn-1` неудаляем), у каждого regex-фильтр узлов, опциональный auto-двойник (`<tag>-auto`, Fastest или Load balance) и Include block
- **Пустое состояние** (§328) — при нуле серверов главный экран показывает полноэкранный гайд со ссылкой в Servers и восстановлением из бэкапа вместо мёртвой кнопки Start
- Сортировка Custom с ручным порядком переживает рестарт; long-press: Ping · Use this node · View JSON · Copy URI; «Поделиться URL» без промежуточного диалога (§347)
</details>

<details>
<summary><strong>Quick Connect</strong> — VPN без открытия приложения</summary>

- **Плитка в шторке** — тап = вкл/выкл, живой статус (`Connected` / `Connecting…` / …). Добавление через App Settings → General → Quick connect (на Android 13+ системный промпт).
- **Long-press по иконке** на рабочем столе → **Toggle VPN**.
- **Кнопки в уведомлении** (§182) — **Stop** / **Reconnect** прямо в постоянном уведомлении; работают даже при убитом UI-процессе.
- Первый запуск коротко показывает приложение ради системного VPN-диалога (требование Android); дальше — без вспышек UI. Плитка переживает OOM-kill сервиса и не врёт «Connected».
</details>

<details>
<summary><strong>Маршрутизация</strong> — единая модель правил</summary>

Блокировка рекламы, прямая маршрутизация .ru-доменов, BitTorrent через выбранный канал, per-app, приватные подсети. Каждое пользовательское правило — единая модель со всеми match-полями параллельно (ИЛИ внутри категории, И между — формула sing-box).

- **4 вкладки**: Channels (каналы) · Presets (read-only каталог → Copy to Rules) · Rules (ваш реестр) · Tunnel apps (split-tunneling уровня ОС)
- **Match-поля**: domain / domain_suffix / domain_keyword, ip_cidr, порты и диапазоны, packages (per-app), протоколы приложений (tls/quic/bittorrent/…), **тип трафика tcp/udp/icmp** (§240 — например, UDP напрямую, TCP через туннель), ip_is_private и source_ip_is_private, **inbound** (пакет пришёл через TUN или через локальный прокси, §119), **wifi_ssid / wifi_bssid**, remote .srs rule-set
- **Traffic Processing** (§264) — закреплённый пресет предобработки первым в списке: sniff, Hijack DNS, резолв адресатов и их настройки в одном месте; выключить/удалить/подвинуть нельзя — на нём держится остальная маршрутизация
- **Action & Resolve** — шестерёнка у Action, три режима: обычный маршрут в канал; **Resolve first** — резолв домена перед роутингом с принудительным семейством адресов и полным набором resolve-опций sing-box (strategy, свой DNS-сервер, кэш, TTL, client subnet, таймаут); **Resolve only** — правило только резолвит, маршрут выбирают следующие правила. **Force IPv4 (drop AAAA)** (§256) отвечает на AAAA-запросы локально — спасение для сетей с полумёртвым IPv6
- **DNS-блок правила** (§257) — тумблер **Send DNS to dedicated server** заводит к правилу парное DNS-правило: домены правила резолвятся выделенным сервером (авто — по каналу маршрута); одно правило решает и маршрут, и резолв
- **Raw-JSON правило** (§225) — правило можно написать сырым фрагментом `route.rules` для полей, которых нет в форме; синтаксис проверяется при вводе
- **SRS только локально** — без авто-обновлений, ручное скачивание через ☁, правило заблокировано, пока нет кэша
- Drag-reorder, long-press → Delete с подтверждением, dirty-aware save («Discard changes?»), вкладка View с готовым sing-box-фрагментом
- Fallback для несматченного трафика (`route.final`)
- См. [спека 030](docs/spec/features/030%20custom%20routing%20rules/spec.md), [спека 011](docs/spec/features/011%20local%20ruleset%20cache/spec.md)
</details>

<details>
<summary><strong>Балансировка нагрузки</strong> — трафик по пулу серверов</summary>

Auto-группа канала умеет не только выбирать один быстрейший узел, но и **раскидывать соединения по пулу** из N серверов (round-robin), сохраняя липкость сессий — TLS/авторизация не прыгают между IP.

- **Два режима** в редакторе канала → *Include auto*: **Fastest** (`least_test`) — один лучший узел по задержке; **Load balance** (`round_robin`) — соединения ротируются по пулу живых узлов
- **Pool size** — размер пула; **Pool tolerance** — `0` держать пул полным (скорость неважна), `>0` вытеснять медленные в пользу быстрых
- **Sticky session by** — чипы `process` / `domain` / `source ip` / `dest ip` / `dest port`; ключ `process + domain` сажает все соединения одного приложения к одному сайту на тот же сервер пула. Без чипов — чистая ротация
- **View pool** — long-press по auto-узлу → живой пул: `слот · узел · delay`
- На базе sing-box-lx SPEC 019 (фиксированные слоты, ленивый health-check, slot-hash-липкость)
- См. [§208 spec](docs/spec/tasks/208-urltest-balancer-round-robin.md)
</details>

<details>
<summary><strong>Wi-Fi-зависимая маршрутизация</strong> — разные правила в разных сетях</summary>

Правила вида «в этой Wi-Fi-сети → напрямую» задаются постоянно, без временных хаков. Поля `wifi_ssid` / `wifi_bssid` объединяются по И с остальными условиями правила:

- `wifi_ssid: [HomeWiFi] → direct` — дома мимо VPN
- `wifi_ssid: [OfficeWiFi] AND domain: [*.bank.com] → direct` — банкинг напрямую только в офисной сети
- `rule_set: [geosite-ru] AND wifi_ssid: [HomeWiFi] → ru-direct` — гео-маршрутизация per-Wi-Fi

В редакторе — чипы **Add current** (текущая сеть), **Pick saved** (история посещённых), **Manual**; гейты разрешений Android учтены. История сетей пишется только при явном opt-in (App Settings → Diagnostics), сеть попадает в неё после ≥5 минут на ней, максимум 50 записей.

- См. [спека 051](docs/spec/tasks/051-custom-rule-wifi-conditions.md), [обзор фичи](docs/features/wifi-aware-routing.md)
</details>

<details>
<summary><strong>Detour</strong> — цепочки серверов («ходить через»)</summary>

Один сервер выходит в интернет через другой: `вы → A → B → интернет`. Зачем: выйти с IP нужной страны через быстрый ближний сервер, пробить блокировку самого сервера или сделать двойной прыжок ради приватности.

- **Единый пикер целей** — detour назначается одному серверу (Node Settings), всей подписке или папке (вкладка Settings), отдельному члену папки; цель — другой сервер, член той же папки или **канал**
- **Detour-каналы** (§248/§274) — галка «Use as detour» делает канал переключаемой прослойкой: какой именно сервер внутри канала будет использоваться, решает ядро; канал при этом остаётся доступен правилам и route final (⚙ в имени)
- **Цепочки** — A через B, B через C; внутри папки цепочки строятся прямо между членами; превью цепочки показывается в настройках подписок и папок (§252)
- **Детектор циклов** (§254/§255) — замкнутое кольцо останавливает сборку конфига с перечислением виновников; тап по виновнику ведёт к владельцу узла
- **⚠-граф зависимостей** (§355) — мёртвый узел, через который ходят другие, помечается на главном экране (см. Главный экран)
- **AmneziaWG поверх WireGuard-детура** работает (§130; ядровый guard снят после end-to-end проверки)
- Вся цепочка живёт внутри одного туннеля L×Box — это не VPN-поверх-VPN на уровне ОС и дешевле по ресурсам
</details>

<details>
<summary><strong>DNS</strong> — группы серверов, отказоустойчивый резолв</summary>

Каталог DNS-серверов (Cloudflare, Google, Yandex, Quad9, AdGuard, OpenDNS — UDP/DoT/DoH) плюс кастомные через JSON. У каждого сервера выбирается канал (**Outbound/detour**): DNS может ходить и напрямую, и через туннель.

- **DNS-группы** (§312) — несколько серверов под одним тегом со стратегией выбора: **Stable** (держится за рабочий), **Fastest** (гонка, липнет к победителю), **Parallel** (каждый запрос гонкой). Своя группа создаётся в редакторе DNS-сервера: тип **Group** рядом с UDP/TLS/HTTPS, участники — галочками из ваших серверов, стратегия и **Error TTL / Win TTL**. Ошибки участников помнятся с TTL — оживший путь сам возвращается в строй; выключенный участник не ломает конфиг (пропускается при сборке с предупреждением, при включении встаёт на место). В списке — бейдж `GROUP · режим · N`, при поднятом туннеле видно текущую цель и состояние участников (ошибки, RTT). Группа ставится всюду, где ставится сервер: дефолтный резолвер, цель DNS-правила
- **Shield DNS** (§314) — дефолт свежей установки: группа `dns_shield` из пяти провайдеров, трёх транспортов (UDP/DoT/DoH) и двух путей (напрямую и через VPN) — ни один единичный отказ не выносит резолв целиком
- **ru-DNS тремя путями** (§354) — пресет «Russian domains & IPs» резолвит ru-домены группой `dns_ru` (UDP через канал пресета, DoT через `vpn-1`, DoH напрямую): мёртвая нода в канале не подвешивает ru-сайты
- **Трасса групп в профайлере** (§315) — у DNS-события видно, через какую группу шёл запрос, кто из участников ответил и с каким RTT
- **DNS Rules** — отдельный реордер-список: свои правила (**Add user rule**, JSON-фрагмент `dns.rules`), правила включённых пресетов и шаблона, и зеркала DNS-блоков правил маршрутизации (§257) — сгруппированы и редактируются на стороне правила-родителя
- DNS Final и Default Domain Resolver — резолвер приложений и внутренний резолвер ядра задаются отдельно
</details>

<details>
<summary><strong>Обход DPI</strong> — приёмы против блокировок</summary>

Три ортогональных приёма — комбинируются на одном outbound.

- **TLS Fragment** — разбивает ClientHello по TCP-сегментам
- **TLS Record Fragment** — разбивает handshake на несколько TLS-записей
- **Mixed-case SNI** — рандомизирует регистр `server_name` (`WwW.gOoGle.CoM`); обходит наивный exact-match DPI региональных провайдеров (по RFC 6066 поле case-insensitive, поведение сервера не меняется). Против фильтрации класса GFW неэффективен
- Все приёмы применяются только к первому хопу (внутренние хопы идут внутри туннеля, локальный DPI их не видит)
- См. [спека 020](docs/spec/features/020%20security%20and%20dpi%20bypass/spec.md), [спека 028](docs/spec/features/028%20antidpi%20sni%20obfuscation/spec.md)
</details>

<details>
<summary><strong>Haptic feedback</strong> — вибро на события туннеля</summary>

Короткая вибрация на переходах VPN, ошибках и тапах. Уважает системную настройку Android Touch feedback.

- Tap Start/Stop → лёгкий tick; подключение → средний impact; отключение пользователем → лёгкий
- Revoke / heartbeat-fail (только первый, не на каждый тик) → тяжёлый
- Авто-триггеры не вибрируют; throttle 100 мс защищает от спама
- Тумблер в App Settings → Feedback (по умолчанию on)
</details>

<details>
<summary><strong>Тест скорости</strong> — измерение соединения</summary>

Встроенный тест скорости с 10 серверами по миру. Per-server пинг меряет задержку до конкретного сервера скачивания. Параллельные потоки загрузки, upload-тест, история за сессию.

- Серверы: Cloudflare, Hostkey (5 городов), Selectel, Tele2, OVH, ThinkBroadband
- Настраиваемые потоки (1/4/10), метод upload per-server
- История с именем сервера
</details>

<details>
<summary><strong>Статистика и соединения</strong> — что происходит в туннеле</summary>

Три вкладки: **Stats** (реалтайм-трафик по каналам с раскрывающимися карточками) · **Conns** (живые соединения) · **Profiler** (запись всех соединений и DNS-резолвов).

- Каждое соединение: хост, протокол, правило, трафик, длительность, цепочка прокси, приложение-владелец с launcher-иконкой (§154); закрытие отдельных соединений
- **Detail sheet** (§152) — тап по соединению → все метаданные + Copy JSON для баг-репортов
- **Однобокие соединения** (§153) — TCP с трафиком только в одну сторону (↑>0, ↓0) подсвечены с бейджем One-way — признак блокировки
- **Profiler** — system-wide запись: каждый TCP/UDP-open и DNS-резолв на устройстве в реальном времени; фильтры по типу события / приложению / домену-IP; агрегация по домену или IP с CNAME-цепочками, outbound'ами и байтами; детектор проблем (`dnsTimeout`, `tcpReset`); длительность коротких соединений — по меткам ядра (§353)
- **Детектор здоровья DNS** (§262) — постоянный монитор долей ошибок резолва с баннером решений
- Трасса DNS-групп в деталях DNS-события (§315)
</details>

<details>
<summary><strong>Диагностика</strong> — экран Debug, краш-репорты, pprof</summary>

Боковое меню → **Debug**: четыре вкладки.

- **Log** — журнал приложения и ядра; live-тумблер verbose снимает фильтр TRACE/DEBUG без перезапуска (§345)
- **Crashes** (§316) — отчёты о падениях ядра: Go-трейс сохраняется файлом (в logcat он не попадает — stderr на Android уходит в `/dev/null`), после падения на главном экране появляется плашка; архив уезжает в «Share dump»
- **OOM** (§318) — снимки сторожа памяти ядра: memstats, лог и конфиг на момент срабатывания; просмотр, отправка, очистка
- **Profiling** (§207) — Go-pprof с живого ядра прямо на устройстве: CPU (10 с), Heap inuse, Allocations, Goroutines; `.pb`-файлы открываются `go tool pprof`
- **Самовосстановление** (§334) — если прошлый запуск кончился падением ядра, приложение сбрасывает служебные кэши ядра до старта (битый `cache.db` — частая причина «падает сразу»); конфиги и настройки не трогаются
- Причина неудачного старта — в `last_start_error` (§250, Debug API)
- Для скриптовой диагностики — [Debug API](docs/api/debug-api-reference.md): HTTP-поверхность управления (CRUD подписок и правил, start/stop, конфиг, логи, профайлер)
</details>

<details>
<summary><strong>Настройки VPN</strong> — тюнинг движка</summary>

Две вкладки:

- **Режим работы** (§119) — **VPN** (системный туннель, по умолчанию) / **Local proxy** (без туннеля: локальный HTTP+SOCKS-прокси, приложения направляются на него вручную; VPN-слот Android свободен — уживается с другим VPN) / **VPN + Proxy** (одновременно). Прокси-порт настраивается; доступ только с устройства или из локальной сети — LAN-вариант строго с авторизацией по паролю. Трафик туннеля и прокси разводится inbound-матчером правил
- **System** — тумблеры Android-стороны: `Allow VPN bypass` (приложения, явно просящие систему о физической сети, могут обойти tun), `Keep VPN on exit`, `Tunnel sleep mode` (`never` / `lazy` только в Doze / `always` при выключенном экране — компромисс батарея↔надёжность)
- **WireGuard connections** (§272) — усыпление простаивающих туннелей: Suspend idle tunnels (30 с) / Suspend active-route tunnels (5 мин); спящие WG/AWG-эндпоинты освобождают память и просыпаются на первом дозвоне (A/B на устройстве — крупное снижение RAM)
- **Passive health check** (§272) — пробы urltest молчат, пока живой трафик подтверждает сервер
- **Memory limit** (§271) — лимит памяти ядра: Auto (по RAM устройства: 200/384/512 MB) / Off / вручную 200–768 MB; применяется к работающему ядру мгновенно. Лечит GC-шторм и перегрев CPU на конфигах с большими пулами WireGuard
- **Core** — переменные движка sing-box (`mtu`, `log_level` и т.д.); routing- и DNS-переменные живут на своих экранах

Все изменения автосохраняются. Параметры URLTest для авто-выбора узла. Блок разрешений (Battery / Notifications / Location / Wi-Fi) — в App Settings → Diagnostics.
</details>

<details>
<summary><strong>Редактор конфига</strong> — для продвинутых</summary>

Просмотр и правка raw sing-box JSON. Построчный редактор (§333): подсветка только видимых строк, номера строк, конфиги на сотни килобайт не вешают UI и клавиатуру; ошибки JSON5 при сохранении показываются с координатами. Конфиги свыше 1 МБ открываются read-only с подсказкой (Share → внешний редактор → Load from file). Сохранение, вставка из буфера, загрузка из файла, шаринг.
</details>

<details>
<summary><strong>Настройки приложения</strong></summary>

- **Язык** (§279) — System default / English / Русский; переключается на лету, переведены и нативные поверхности (шторка, плитка, ярлыки). Технические поверхности (логи, Debug API, automation-события) намеренно английские
- Тема: системная / светлая / тёмная
- Автозапуск туннеля при загрузке; туннель переживает закрытие приложения
- **Автоперезапуск VPN при смене настроек** (§338) — не жать «Restart» руками; плашка «перезапустите VPN» сверяется с работающим ядром и не появляется, если применять нечего (§324)
- **First-run wizard** (§126) — онбординг: уведомления → battery optimization → плитка Quick Settings
- **Battery optimization** и **App info (OEM power settings)** — статус + шорткаты в системные вайтлисты
- **Auto-ping after connect** — пинг активного канала через 5 с после подключения
- **Interrupt connections on switch** (§143) — при смене узла рвать соединения группы, чтобы трафик сразу перешёл (по умолчанию off); повторный выбор уже активного узла — no-op (§290)
- Haptic feedback, Quick connect, Backup & restore (снапшот подписок, каналов, правил и настроек с предпросмотром перед восстановлением)
</details>

---

## Поддерживаемые протоколы

| Протокол    | URI-схема                          | Транспорт                                      |
| ----------- | ---------------------------------- | ---------------------------------------------- |
| VLESS       | `vless://`                         | TCP, WebSocket, gRPC, H2, HTTPUpgrade, **XHTTP**, REALITY; постквантовое шифрование **ML-KEM-768** (`mlkem768x25519plus`, §335) |
| VMess       | `vmess://` (v2rayN base64)         | TCP, WebSocket, gRPC, H2, HTTPUpgrade, **XHTTP** |
| Trojan      | `trojan://`                        | TCP, WebSocket, gRPC                           |
| Shadowsocks | `ss://` (SIP002 + legacy + SS2022) | TCP, UDP, SIP003-плагины                       |
| Hysteria2   | `hy2://` / `hysteria2://`          | QUIC, Salamander obfs                          |
| **TUIC v5** | `tuic://`                          | QUIC, BBR/CUBIC/NewReno, zero-RTT              |
| **NaïveProxy** | `naive+https://`                | Настоящий Chrome TLS через cronet, `extra-headers` |
| **AnyTLS**  | `anytls://` (§269)                 | TLS (вкл. REALITY, uTLS, ALPN), idle-сессии    |
| SSH         | `ssh://`                           | TCP, host key / password / private key         |
| SOCKS       | `socks://` / `socks5://`           | TCP, auth                                      |
| WireGuard / **AmneziaWG** | `wireguard://`, `awg://`, INI / `.conf`, **Amnezia `vpn://`** | UDP, multi-peer, **обфускация AWG 1.x/2.0** (jc/jmin/jmax, s1–s4, h1–h4 вкл. **диапазоны `N-M`**, i1–i5), авто-MTU 1280 |
| **MASQUE** (Cloudflare WARP) | `masque://` | QUIC / HTTP-3 (RFC 9484 CONNECT-IP), fallback HTTP/2, pinning ECDSA P-256 |

**XHTTP** — нативный транспорт (Xray splithttp: `mode` auto/packet-up/stream-up/stream-one) с полным клиентским набором полей: placement'ы session/seq/uplink (path/query/header/cookie), ключи, метод upload, X-Padding obfs-режим (`repeat-x`/`tokenish`) и packet-up-tuning — читаются из плоских query-параметров и из `extra` (URL-encoded JSON). Работает с TLS и Reality, несовместим с XTLS-Vision (ограничение протокола).

Подробная документация: [docs/PROTOCOLS.md](docs/PROTOCOLS.md)

---

## Архитектура

L×Box построен вокруг **3-слойного parser/builder pipeline** (спека 026):

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
buildConfig(lists, settings)  ← template + post-steps (DPI, DNS, rules)
  │                              returns: BuildResult{ config, validation, warnings }
  ▼
sing-box JSON
```

- **Bundled-ядро** — [sing-box-lx](https://github.com/Leadaxe/sing-box-lx), форк sing-box ветки 1.14 с собственными расширениями: AmneziaWG 2.0, нативный XHTTP, round-robin-балансировщик, idle-suspend простаивающих туннелей, MASQUE / CONNECT-IP outbound, DNS-группы, доступ к конфигу работающего ядра, краш- и OOM-репорты. Управляющий канал — libbox `CommandClient` (без Clash API, без открытого порта). Точная версия пинится в [`app/android/libbox.version`](app/android/libbox.version); AAR скачивается из GitHub Releases форка скриптом `scripts/fetch-libbox.sh` с проверкой SHA256
- **Sealed `NodeSpec`** — 12 протоколов, полиморфный `emit(vars)` / `toUri()` (round-trip-инвариант)
- **`EmitContext`** — пробрасывает шаблонные vars в per-node emit
- **`ValidationResult`** — типизированные проблемы: dangling refs, пустой urltest, невалидный selector default

Полная картина: [Архитектура](docs/ARCHITECTURE.md).

---

## Разработка

Spec-driven development — спецификации документируют каждую возможность.
Полная карта документации: **[docs/README.md](docs/README.md)**.

| Документ                                     | Описание                                                  |
| -------------------------------------------- | --------------------------------------------------------- |
| [Индекс документации](docs/README.md)        | Карта всех доков — начинать отсюда                        |
| [Поддержать проект](docs/DONATE_RU.md)      | Способы поддержки: криптовалюта, Boosty, и как помочь не деньгами |
| [Руководство пользователя](docs/USER_GUIDE_RU.md) | Как это работает: ступени трафика, каналы, detour, DNS — не про код, про логику. Плюс рецепты: раздача VPN по Wi-Fi через прокси, связка с ByeDPI |
| [Автоматизация](docs/AUTOMATION.md)          | Управление L×Box из Tasker / MacroDroid через Public Intent API (команды + события, Wi-Fi-триггеры) |
| [Debug API](docs/api/debug-api-reference.md) | HTTP-поверхность управления и диагностики (CRUD подписок и правил, start/stop, конфиг, логи, профайлер) |
| [Безопасность](docs/SECURITY.md)             | Модель угроз — защита от утечек, локальная поверхность атаки, секреты на устройстве |
| [Документация протоколов](docs/PROTOCOLS.md) | URI-форматы, параметры, маппинг в sing-box                |
| [Архитектура](docs/ARCHITECTURE.md)          | 3-слойный pipeline, потоки данных, нативный bridge        |
| [Сборка](docs/BUILD.md)                      | Инструкции по сборке, CI, подпись APK, local-build marker |
| [Руководство разработчика](docs/DEVELOPMENT_GUIDE.md) | Принципы, тестирование, организация спек        |
| [Список изменений](CHANGELOG.md)             | История релизов                                           |
| [Release notes](docs/releases/)              | Подробные заметки per-версия (EN + RU)                    |

### Локальная сборка

```bash
./scripts/build-local-apk.sh
```

Скрипт оборачивает `flutter build apk --release` с `--dart-define`'ами, которые подмешивают git describe. About-экран показывает розовую плашку **🧪 LOCAL BUILD · N commits since vX.Y.Z** — чтобы отличать от CI-билдов.

---

## Безопасность

- **Только TUN inbound по умолчанию** — прокси-порты на localhost не открываются, пока прокси-режим не включён явно; LAN-доступ к прокси — только с авторизацией
- **Управляющий канал** — libbox `CommandClient` внутри процесса (без сетевого Clash API, без открытого порта/секрета)
- **VPN Service** не экспортирован (`android:exported="false"`)
- Подробнее — [SECURITY.md](docs/SECURITY.md)

---

## Лицензия

L×Box распространяется на условиях [GNU General Public License v3.0](LICENSE).

Коммерческая лицензия от Leadaxe возможна **только на собственный код Leadaxe в L×Box**. L×Box линкуется с [`libbox`](https://github.com/SagerNet/sing-box) (sing-box, GPLv3), поэтому собранный L×Box в любом случае остаётся под GPLv3 — коммерческая лицензия только от Leadaxe не делает L×Box пригодным для проприетарного продукта. Область применения и ограничения: [LICENSING.md](LICENSING.md). Запросы: [ledaxe@gmail.com](mailto:ledaxe@gmail.com).
