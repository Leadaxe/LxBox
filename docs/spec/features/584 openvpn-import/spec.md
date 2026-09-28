# 584 — Импорт профилей OpenVPN (`.ovpn`)

| Поле | Значение |
|------|----------|
| Статус | Отложено, дальний приоритет (решение владельца 28.09.2026) |
| Дата | 2026-09-28 |
| Контракт | Требует запроса: протокол `openvpn`, вид источника `openvpn_profile`, пространство `ovpn`, вид происхождения `ovpn`, коды `ovpn_*`, корпус `body/ovpn/` |
| Решение владельца | 28.09.2026: формат опознаётся по расширению файла; профиль самодостаточен — ключи, сертификаты, логин и пароль лежат внутри файла; ТЗ общее для LxBox и лаунчера |
| Ядро | `openvpn-client` — апстримный endpoint sing-box 1.14 (тег сборки `with_openvpn`), в наших сборках с 2026-08-05. Проверено вживую на `1.14.1-lx.8` |
| Связанные | [019](../019%20wireguard%20endpoint/spec.md) (WG INI — ближайший аналог), [472](../472%20unified-parse-pipeline/spec.md), [480](../480%20registry-driven-mapper/spec.md), [129](../129%20file-subscription/spec.md), [§110](../../tasks/110-amnezia-vpn-link-import.md), [§576](../../tasks/576-node-source-is-bare-body.md), [§577](../../tasks/577-authored-json-registry-reports-only.md), [§578](../../tasks/578-tailscale-preset-template-for-each.md), §585 (узел незнакомого типа, ветка `task-585`); лаунчер: SPEC 103 (контракт), SPEC 075, 076 |

## 1. Зачем

Ядро умеет OpenVPN как клиентский endpoint, но ни LxBox, ни лаунчер не могут
принять профиль: `.ovpn` при импорте уходит в ветку `uri_lines` и даёт ноль
узлов, контейнер `amnezia-openvpn` в `vpn://` пропускается. Парсера `.ovpn` в
ядре нет, перевод текста профиля в JSON лежит на приложениях.

Профили OpenVPN раздают файлами: коммерческие провайдеры, корпоративные
шлюзы, роутеры, свои серверы. Единой ссылки или подписки у формата нет.

## 2. Цели и нецели

**Цели**

1. Файл `.ovpn` превращается в узел-endpoint `openvpn-client` одинаково в
   LxBox и в лаунчере: один реестр, один корпус.
2. Узел живёт как любой другой: тег, включение, detour, группы, бэкап,
   пересборка из сохранённого исходника.
3. Узел работает сразу после импорта, включая профили с раздельным
   туннелированием, которым нужен DNS сервера.

**Нецели**

| Что | Почему |
|---|---|
| Интерактивная авторизация: ввод логина и пароля в приложении, OTP, `static-challenge`, вход через браузер | Решение владельца: всё нужное лежит в файле. Мост к `SubscribeOpenVPNStatus` / `SubmitOpenVPNChallengeResponse` не строим |
| Внешние файлы (`ca ca.crt`, `auth-user-pass pass.txt`) | То же решение. Профиль со ссылкой на файл отклоняется с понятным кодом |
| Опознание по содержимому (вставка текста из буфера, QR) | Решение владельца: только расширение |
| zip-архивы провайдеров | Ни в одном из приложений нет распаковки; отдельная задача |
| Серверный endpoint `openvpn-server` | Импорт клиентский |
| `dev tap`, PKCS#12, зашифрованный приватный ключ, XOR-обфускация (`scramble`) | Ядро этого не умеет (п. 8) |
| Ссылка для передачи узла (share URI) | У OpenVPN её нет; узел передаётся файлом |
| Расширение `.conf` с профилем OpenVPN | Занято WireGuard |

## 3. Порядок работ

Норма контракта (лаунчер, SPEC 103 и `CONSTITUTION` §7.3): сначала изменение в
`contract/` лаунчера, потом код сторон.

| Шаг | Где | Что |
|---|---|---|
| 1 | лаунчер, `contract/` | Запрос в контракт (п. 12): реестр, схемы, коды, корпус, минорный бамп `VERSION`, раздел в `TASKS_LXBOX.md` |
| 2 | лаунчер | Реализация отдельной SPEC лаунчера; раннеры корпуса зелёные |
| 3 | LxBox | `bash app/tool/sync_contract.sh --to <sha>`, реализация, раннеры корпуса зелёные без per-app override |
| 4 | обе стороны | Проверка на живом профиле (п. 13.3) |

Шаги 2 и 3 независимы и идут параллельно после шага 1.

## 4. Опознание

Формат опознаётся по имени источника, содержимое не анализируется.

| Вход | Признак |
|---|---|
| Файл из диалога выбора | расширение `.ovpn`, без учёта регистра |
| Несколько файлов в папку | то же для каждого файла |
| Подписка по URL | путь URL заканчивается на `.ovpn` либо ответ пришёл с `Content-Type: application/x-openvpn-profile` |
| Сохранённая запись | `origin.kind: "ovpn"` — повторного опознания нет |

Вид источника в `source_kinds.json`: `openvpn_profile`, `mapper: "ovpn"`,
`elements: "$self"` (один файл — один узел). Предикат `detect` читает подсказку
имени (`hint`), а не текст; приоритет выше `wireguard_conf`.

Вставка текста без имени файла профилем OpenVPN не считается и идёт прежним
путём.

Подписка по URL обновляется штатно: профиль перечитывается, тег узла не
меняется (п. 9).

## 5. Разбор текста: пространство `ovpn`

Опознание по расширению не отменяет разбора: тексту нужен свой лексер.
INI-разборщик не годится — строку без `=` он отбрасывает, а в `.ovpn` таких
строк большинство. Значение `ovpn` добавляется в `forms[].space` рядом с
`url`, `json`, `ini`.

### 5.1. Лексика

| Правило | Норма |
|---|---|
| Кодировка | UTF-8; BOM в начале снимается; переводы строк `\n` и `\r\n` |
| Строка | одна директива: имя и аргументы через пробелы или табы |
| Имя директивы | регистр значим; ведущие `--` снимаются |
| Комментарий | `#` или `;` в начале слова вне кавычек — до конца строки |
| Кавычки | двойные и одинарные; внутри двойных `\\` и `\"` — экранирование |
| Inline-блок | `<имя>` на отдельной строке … `</имя>` на отдельной строке; содержимое берётся как есть, директивы внутри не ищутся |
| Блок `<connection>` | исключение: внутри директивы, разбираются теми же правилами |
| Повтор директивы | сохраняются все вхождения в порядке появления |
| `setenv opt <директива> …` | читается как сама директива; если она неизвестна, предупреждения нет |
| Незакрытый блок, незакрытая кавычка | узел отклоняется: `ovpn_syntax_invalid` |
| Размер | общий лимит тела импортируемого файла из `limits.json` |

### 5.2. Адреса в пространстве

| Адрес | Значение |
|---|---|
| `ovpn.<директива>` | аргументы последнего вхождения, список строк |
| `ovpn.<директива>.<n>` | n-й аргумент последнего вхождения, с 1 |
| `ovpn.<директива>[]` | все вхождения, список списков |
| `ovpn.$flag.<директива>` | директива встретилась |
| `ovpn.$block.<имя>` | содержимое inline-блока, список строк |
| `ovpn.$connection[]` | блоки `<connection>`, у каждого те же адреса |
| `ovpn.$setenv.<ИМЯ>` | значение `setenv ИМЯ значение` |

Точную запись в грамматике реестра определяет запрос в контракт; таблица
задаёт состав данных, которые маппер должен видеть.

## 6. Перевод директив в поля

Обозначения колонки «Действие»: **поле** — переносится; **молча** —
пропускается без предупреждения; **предупр.** — пропускается с кодом, узел
живёт; **отказ** — узел уходит в `dropped[]`.

### 6.1. Серверы и транспорт

| Директива | Действие | Поле, правило |
|---|---|---|
| `remote host [port] [proto]` — одна | поле | `server`, `server_port`; `proto` из строки → `network` |
| `remote` — несколько | поле | `servers[]` в порядке файла; `server` и `server_port` не пишутся |
| `<connection>` | поле | элемент `servers[]` из `remote`, `port`, `proto` блока; прочие директивы блока — `ovpn_connection_option_ignored` |
| `port`, `rport` | поле | порт для `remote` без порта; нет ни того ни другого — `1194` |
| `proto` | поле | `network`; значение `udp` не пишется (умолчание) |
| `remote-random` | поле | `remote_random: true` |
| `explicit-exit-notify [n]` | поле | `explicit_exit_notify`; без аргумента — `1` |
| `http-proxy`, `socks-proxy` и их параметры | предупр. | `ovpn_proxy_ignored`; замена — detour узла |
| `nobind`, `bind`, `lport`, `local`, `float`, `resolv-retry`, `connect-retry`, `connect-timeout`, `server-poll-timeout`, `sndbuf`, `rcvbuf`, `fast-io`, `mark` | молча | — |

Нормализация `proto`: суффикс `-client` снимается (`tcp-client` → `tcp`,
`tcp4-client` → `tcp4`). Ядро принимает только `udp`, `udp4`, `udp6`, `tcp`,
`tcp4`, `tcp6`, любое другое значение валит весь конфиг. `tcp-server` и
`tcp4-server` — отказ `ovpn_mode_unsupported`.

### 6.2. Режим и устройство

| Директива | Действие | Правило |
|---|---|---|
| `client`, `tls-client`, `pull` | молча | режим `tls`, в тело не пишется |
| `<secret>` | поле | `mode: "static_key"`, `static_key` |
| `dev tun`, `dev tunN`, `dev-type tun` | молча | — |
| `dev tap`, `dev tapN`, `dev-type tap` | отказ | `ovpn_tap_unsupported` |
| `topology` | поле | `topology` |
| `ifconfig local peer` | поле | `address`, `peer_address`; в режиме `static_key` обязательна |
| `ifconfig-ipv6` | поле | `address`, `peer_address_ipv6` |
| `server`, `mode server`, `tls-server` | отказ | `ovpn_mode_unsupported` |
| `scramble`, `xor-mask` и прочие директивы XOR-патча | отказ | `ovpn_obfuscation_unsupported` |

### 6.3. TLS и ключевой материал

| Директива | Действие | Поле, правило |
|---|---|---|
| `<ca>` | поле | `tls.certificate` |
| `<cert>` | поле | `tls.client_certificate` |
| `<key>` | поле | `tls.client_key` |
| `<tls-auth>` | поле | `tls.control_wrap: {type: "tls_auth", key}` |
| `key-direction 0` / `1` | поле | при `tls-auth`: `tls.control_wrap.direction` = `server` / `client`; при `<secret>`: `key_direction` |
| `<tls-crypt>` | поле | `tls.control_wrap: {type: "tls_crypt", key}` |
| `<tls-crypt-v2>` | поле | `tls.control_wrap: {type: "tls_crypt_v2", key}` |
| `verify-x509-name имя [тип]` | поле | `tls.server_name`, `tls.server_name_type`; тип `name` не пишется |
| `remote-cert-tls` | поле | `tls.remote_certificate_tls`; `server` не пишется |
| `remote-cert-ku`, `remote-cert-eku` | поле | `tls.remote_certificate_ku`, `tls.remote_certificate_eku` |
| `ns-cert-type` | поле | `tls.ns_certificate_type` |
| `peer-fingerprint`, `<peer-fingerprint>` | поле | `tls.peer_fingerprint`; двоеточия снимаются, регистр — нижний |
| `tls-version-min`, `tls-version-max` | поле | `tls.version_min` (значение `1.2` не пишется), `tls.version_max` |
| `tls-cipher`, `tls-groups` | поле | `tls.cipher`, `tls.groups` |
| `tls-cert-profile` | поле | `tls.certificate_profile`; `legacy` не пишется |
| `tls-ciphersuites` | предупр. | `ovpn_directive_ignored`: набор TLS 1.3 ядром не управляется |
| `ca файл`, `cert файл`, `key файл`, `tls-auth файл`, `tls-crypt файл`, `tls-crypt-v2 файл`, `secret файл`, `crl-verify файл` | отказ | `ovpn_external_file`, в `params` имя директивы |
| `<pkcs12>`, `pkcs12 файл` | отказ | `ovpn_pkcs12_unsupported` |
| `<key>` с зашифрованным ключом | отказ | `ovpn_key_encrypted` |
| `<crl-verify>`, `<extra-certs>` | предупр. | `ovpn_directive_ignored` |
| `<dh>`, `dh` | молча | серверная директива |

Зашифрованный ключ: заголовок `-----BEGIN ENCRYPTED PRIVATE KEY-----` либо
строка `Proc-Type: 4,ENCRYPTED` внутри блока.

Форма PEM-полей в теле: массив строк, по строке на элемент; пустые строки и
пробелы по краям сняты; несколько сертификатов в `<ca>` идут подряд в порядке
файла.

Одновременно два и более из `tls-auth`, `tls-crypt`, `tls-crypt-v2` — отказ
`ovpn_control_wrap_conflict`: ядро такой конфиг не примет.

### 6.4. Логин и пароль

| Что в файле | Действие |
|---|---|
| нет `auth-user-pass` | полей нет |
| `<auth-user-pass>`: логин первой строкой, пароль второй | `username`, `password` |
| `auth-user-pass` без аргумента и без блока | отказ `ovpn_credentials_missing` |
| `auth-user-pass файл` | отказ `ovpn_external_file` |
| `auth-retry` | поле `auth_retry`; `none` не пишется |
| `static-challenge` | отказ `ovpn_interactive_auth_unsupported` |
| `auth-nocache`, `auth-token*` | молча |

Отказ, а не узел без пароля: ядро без `static_challenge` логин не запрашивает,
пустые значения уходят на сервер и сессия падает с ошибкой авторизации.

Текст причины `ovpn_credentials_missing` объясняет, что сделать: добавить в
файл блок из двух строк.

```
<auth-user-pass>
логин
пароль
</auth-user-pass>
```

### 6.5. Канал данных

| Директива | Действие | Поле, правило |
|---|---|---|
| `data-ciphers`, `ncp-ciphers` | поле | `data_ciphers`, разделитель `:` |
| `data-ciphers-fallback` | поле | `data_ciphers_fallback` |
| `cipher X`, режим `tls` | поле | `data_ciphers_fallback: X`, если в файле нет `data-ciphers-fallback` |
| `cipher X`, режим `static_key` | поле | `cipher` |
| `auth` | поле | `auth`; `SHA1` не пишется |
| `compress [алгоритм]` | поле | `compression`; без аргумента — `stub` |
| `comp-lzo [режим]` | поле | `compression_lzo`; без аргумента — `adaptive` |
| `allow-compression` | поле | `allow_compression`; `no` не пишется |
| `tun-mtu` | поле | `mtu`; `1500` не пишется |
| `mssfix [n]` | поле | `mss_fix`; `mssfix 0` → `mss_fix_disabled: true` |
| `fragment n` | поле | `fragment`; при TCP-сервере в профиле — `ovpn_fragment_with_tcp`, поле снимается |
| `replay-window n [t]` | поле | `replay_window`, `replay_window_time` |
| `ncp-disable`, `keysize`, `tun-mtu-extra`, `link-mtu`, `mtu-disc`, `mtu-test`, `no-replay` | предупр. | `ovpn_directive_ignored` |

Имена шифров и дайджестов приводятся к верхнему регистру и сверяются со
словарями `allowlists.json` (`openvpn_data_ciphers`, `openvpn_auth_digests`).
Имя вне словаря снимается с `ovpn_cipher_unknown`: ядро на неизвестном имени
валит весь конфиг. Словари — список из `validateDataCipherName` и
`tlsCipherKeyBits` библиотеки `sing-openvpn`.

`cipher` верхнего уровня в режиме `tls` в тело не попадает никогда — ядро
такой конфиг отвергает.

### 6.6. Маршруты и DNS

| Директива | Действие | Поле, правило |
|---|---|---|
| `route сеть [маска] [шлюз] [метрика]` | поле | `routes[]`; маска переводится в длину префикса |
| `route-ipv6` | поле | `routes[]` |
| `route-gateway`, `route-metric` | поле | `route_gateway`, `route_metric` |
| `redirect-gateway [флаги]` | поле | `redirect_gateway: true`, `redirect_gateway_flags`; флаг `block-local` снимается с `ovpn_directive_ignored` |
| `redirect-private` | поле | `redirect_private` |
| `route-nopull` | поле | `route_no_pull` |
| `pull-filter действие "текст"` | поле | `pull_filters[]` в порядке файла |
| `block-ipv6` | поле | `block_ipv6` |
| `dhcp-option`, `dns`, `block-outside-dns`, `register-dns` | предупр. | `ovpn_dns_ignored`: локальные настройки DNS не применяются, сервер DNS даёт связка п. 7 |
| `route-method`, `route-delay`, `ip-win32`, `route-noexec` | молча | — |

`routes` и `redirect_gateway` системных маршрутов не ставят: они задают
предпочтение в маршрутизации sing-box.

### 6.7. Тайминги

| Директива | Действие | Поле |
|---|---|---|
| `ping n` | поле | `ping_interval` |
| `ping-restart n` | поле | `ping_restart`; `0` → `ping_restart_disabled: true` |
| `keepalive a b` | поле | `ping_interval: a`, `ping_restart: b` |
| `ping-exit`, `inactive`, `ping-timer-rem` | молча | — |
| `reneg-sec n` | поле | `renegotiate_interval`; `0` → `renegotiate_disabled: true`; `3600` не пишется |
| `reneg-bytes`, `reneg-pkts` | поле | `renegotiate_bytes`, `renegotiate_packets` |
| `tls-timeout` | поле | `tls_timeout`; `2` не пишется |
| `hand-window` | поле | `handshake_window`; `60` не пишется |

Длительности пишутся строкой sing-box с единицей: `10s`, `1h`.

### 6.8. Скрипты и управление

| Директива | Действие | Код |
|---|---|---|
| `up`, `down`, `route-up`, `route-pre-down`, `ipchange`, `tls-verify`, `auth-user-pass-verify`, `client-connect`, `client-disconnect`, `learn-address`, `plugin`, `script-security`, `up-restart`, `down-pre` | предупр. | `ovpn_script_ignored` |
| `management*` | предупр. | `ovpn_directive_ignored` |
| `verb`, `mute`, `mute-replay-warnings`, `log`, `log-append`, `status`, `daemon`, `user`, `group`, `chroot`, `persist-key`, `persist-tun`, `writepid`, `nice`, `machine-readable-output`, `setenv-safe` | молча | — |
| `setenv ИМЯ значение` | молча | `FRIENDLY_NAME` идёт в метку (п. 9) |
| любая другая | предупр. | `ovpn_directive_unknown`, в `path` имя директивы |

Скрипты не исполняются ни при каких условиях.

### 6.9. Поля, которых в файле нет

`system`, `name`, UDP NAT (`udp_mapping`, `udp_filtering`, `udp_nat_max`,
`udp_timeout`) и dial-поля источника в `.ovpn` не имеют. В тело они попадают
только из JSON-входа (п. 9) и из записи узла (detour).

## 7. Связка: DNS и маршруты

Узел без DNS сервера для части профилей бесполезен. Проверка на профиле
сервиса с раздельным туннелированием: с обычным DNS каждое соединение
получает `connection refused`; с DNS-сервером типа `openvpn` заблокированный
домен разрешается во внутренний адрес сервиса, сайт отвечает.

Связку даёт пресет шаблона по механизму §578 (`for_each`, контракт ≥ 1.1.86),
как у Tailscale:

| Часть | Содержимое |
|---|---|
| Перебор | `for_each: {node_type: "openvpn-client", as: "node", filter: {"#not": "@node.skip_presets"}}` |
| DNS-сервер | `{type: "openvpn", tag: "<тег узла>-dns", endpoint: "<тег узла>", accept_default_resolvers: false, accept_search_domain: true}` |
| DNS-правило | `{preferred_by: ["<тег узла>-dns"], action: "route", server: "<тег узла>-dns"}` |
| Правило маршрута | `{preferred_by: ["<тег узла>"], outbound: "<тег узла>"}` |

`accept_default_resolvers: false` — DNS сервера отвечает только за домены,
которые сервер сам назвал своими (`resolve-domains`, `DOMAIN-ROUTE`, домены
поиска). Профилю без таких доменов, у которого сервер присылает один общий
резолвер, этого мало: там DNS сервера нужен для всех запросов, идущих через
узел. Переключатель — переменная пресета (п. 14, вопрос 2).

## 8. Что ядро отвергает

Значение, на котором ядро валит весь конфиг, в тело попадать не имеет права
(`PARSING_PRINCIPLES` §4). Проверено командой `check` на `1.14.1-lx.8`:

| Значение | Ответ ядра | Защита |
|---|---|---|
| `tls.client_certificate` без `tls.client_key` и наоборот | `certificate and key must both be set or both omitted` | `requires` в обе стороны; нарушение — отказ `field_missing` |
| имя шифра вне списка | `must use a canonical OpenVPN cipher name` | словарь, п. 6.5 |
| `cipher` в режиме `tls` | `only supported in static_key mode` | п. 6.5 |
| `network` вне перечня, в том числе `tcp-client` | `unsupported openvpn protocol` | нормализация, п. 6.1 |
| `fragment` с TCP-сервером | `fragment with tcp remote` | п. 6.5 |
| `server` вместе с `servers` | `server is conflict with servers` | п. 6.1 |
| нет ни `server`, ни `servers` | `missing server or servers` | отказ `field_missing` |
| два вида обёртки управляющего канала | `tls_auth+tls_crypt` | п. 6.3 |
| TLS-поля в режиме `static_key`, `static_key` в режиме `tls` | `option is not supported yet` | поля чужого режима снимаются |

Что ядро на проверке пропускает и что всплывает только при подключении:
битое содержимое PEM в сертификате, ключе и ключе обёртки, отсутствие `<ca>`.
Санитайзер проверяет у PEM только рамку (`BEGIN`/`END`, допустимая метка,
base64 внутри). Содержимое сертификата стороны не разбирают — иначе Go и Dart
разойдутся. Узел с рабочей рамкой и негодным сертификатом в конфиг попадёт
и покажет ошибку подключения.

Страховка на случай пропущенного правила — общий механизм `core_rejected`
(`PARSING_PRINCIPLES` §9): ядро называет endpoint в ошибке, приложение
выключает этот узел.

## 9. Узел

| Свойство | Норма |
|---|---|
| Схема реестра | `openvpn` |
| Тип sing-box | `openvpn-client` |
| Род | `endpoint` |
| Входы | `ovpn`, `singbox` |
| Гейт ядра | `build_tag: "with_openvpn"`, `on_core_unsupported: {action: "drop_node", code: "openvpn_core_unsupported"}` |
| Ссылка для передачи | нет, `emit.share_uri: false` |
| Метка | `setenv FRIENDLY_NAME` → имя файла без расширения → адрес первого сервера |
| Тег | по общим правилам `IDENTITY` §1; в файле тега нет, подсказкой служит тег записи, как у `wg_ini` |
| Секретные поля | `password`, `tls.client_key`, `tls.control_wrap.key`, `static_key` — `secret: true` |
| Исходник | текст файла байт в байт в `origin.raw`, вид `origin.kind: "ovpn"` |
| Хранение секретов | открытым текстом, как у остальных протоколов (`BACKUP.md`); предупреждение при экспорте бэкапа уже есть |
| Несколько серверов в профиле | один узел с `servers[]`; перебор серверов делает ядро |
| Порядок полей тела | `body.order` реестра |

Канонизация общая (`PARSING_PRINCIPLES` §2): в теле нет `tag` и `detour`,
поля со значением по умолчанию не пишутся, числа остаются числами.

### 9.1. JSON-вход

Endpoint `openvpn-client` из JSON принимается секцией `mappers.singbox`, как
у Tailscale.

| Источник JSON | Поведение |
|---|---|
| Подписка, конфиг sing-box (§368) | узел идёт через санитайзер; поля `*_path` снимаются с `ovpn_external_file`: путь с чужой машины на этой ничего не значит |
| Авторское тело: вид `singbox_outbound` в своей записи или папке (§577) | реестр только сообщает: те же коды показываются предупреждениями, тело не правится; жёсткие правила п. 8 с `core_rejects` действуют |

До этой фичи тип `openvpn-client` приложению незнаком: задача §585 принимает
такой узел как авторское тело с предупреждением «Unknown node type» и
отдаёт ядру дословно. После появления `openvpn.json` в реестре тип становится
известным, предупреждение исчезает, узел идёт по таблице выше. Записи,
сохранённые по правилу §585, остаются авторскими телами и пересохранения не
требуют.

## 10. Поведение в приложениях

### 10.1. Общее

| Сценарий | Поведение |
|---|---|
| Выбран один файл `.ovpn` | один узел; имя файла — подсказка тега |
| Выбрано несколько файлов | по узлу на файл; в LxBox — в папку (`addMembersToFolder`), в лаунчере — в папку либо отдельными записями по месту вызова |
| Среди выбранных есть отклонённые | остальные импортируются; по отклонённым показывается код и причина |
| URL подписки на `.ovpn` | подписка с одним узлом, штатное обновление |
| Правка исходника | редактор показывает текст `.ovpn`; сохранение проходит тот же разбор |
| Узел в группах `selector` / `urltest` | участвует на общих основаниях (п. 14, вопрос 3) |
| detour | назначается записи узла, как у WireGuard |
| Статус сессии | не показывается; ошибки подключения видны в логе ядра |

### 10.2. LxBox

| Место | Изменение |
|---|---|
| `services/parser/engine/` | лексер пространства `ovpn` рядом с `ini_space.dart`; запуск секции на нём в `interpreter.dart`; вид `ovpn` в списке `section_loader.dart` |
| `services/parser/body_decoder.dart` | форма `OvpnConfig` в закрытом наборе `DecodedBody`; в запасном пути без реестра — тот же признак по имени |
| `services/parser/parse_all.dart`, `mappers/uri_pipeline.dart`, `engine/engine_mapper.dart` | ветка разбора с `nameHint`; тип протокола приходит из вида источника, а не зашит вызывающим |
| `services/contract/body_sanitizer.dart` | значение `ovpn` в `BodySource` |
| `models/node_spec.dart`, `node_spec_emit.dart`, `services/parser/json_parsers.dart` | `OpenVpnSpec` по образцу `TailscaleSpec` (тело как есть), эмит в `Endpoint`, `case 'openvpn-client'` |
| `services/node_identity.dart`, `node_emoji.dart` | ветки в исчерпывающих `switch` |
| `models/codec/source_record.dart` | `originKindOf` → `ovpn`, `sourceKindOf` → `openvpn_profile`, тег записи как подсказка |
| `controllers/subscription_controller.dart`, `services/subscription/input_helpers.dart` | ветка `addFromInput` по имени файла; `memberNameHintFor` |
| `services/file_import.dart`, `screens/subscriptions_screen.dart` | имя файла доходит до опознания; сообщение об отклонённых файлах |
| Подписка по URL | путь URL и `Content-Type` ответа доходят до опознания |

§576, критерий 1: вид источника своей записи — один из четырёх:
`singbox_outbound`, `uri_lines`, `wireguard_conf`, `openvpn_profile`.

`core_chain_capability.dart` не меняется: `with_openvpn` уже в
`kCoreBuildTags`.

Системной регистрации расширения («Открыть с помощью») в LxBox нет ни для
одного формата; в этой фиче она не появляется.

### 10.3. Лаунчер

| Место | Изменение |
|---|---|
| `core/config/linkmap/` (`parse.go`, `detect.go`, `space.go`) | лексер пространства `ovpn`; предикат опознания по имени |
| `core/config/subscription/body_classify.go` | новый `BodyKind`, строка `ovpn` |
| `core/config/subscription/parse_body.go`, `node_parser_engine.go` | ветка разбора, `ParseOvpnByEngineHint` |
| `core/config/migrate_materialize.go`, `core/state/sources_v7.go`, `configtypes/types.go`, `nodeflow/sanitize.go` | вид происхождения `ovpn`, пересборка из `origin.raw`, константа входа |
| `core/config/registry/registry.go` и два списка в тестах | `openvpn.json` в `protocolFiles` |
| `ui/configurator/tabs/source_tab.go`, `folder_add_nodes.go` | `ovpn` в фильтрах диалогов выбора файла |
| `ui/configurator/tabs/source_edit_window.go`, `core/backup/legacy_read_0x.go` | вид происхождения по записи, а не по форме текста |
| `core/config/contract_body_test.go` | ветка нового вида в `parseCorpusBody` |
| `docs/Protocols.md`, `docs/Protocols.ru.md` | раздел OpenVPN |

Клиент демона (`SubscribeOpenVPNStatus` и парные методы в
`internal/daemonpb`) не используется, как и сейчас.

## 11. Риски

| Риск | Что делаем |
|---|---|
| Ядро поднимает сессию каждого узла сразу при старте, а не по первому обращению. Двадцать профилей одного провайдера — двадцать одновременных сессий; у провайдеров обычно лимит на число устройств | п. 14, вопрос 1 |
| Профиль с раздельным туннелированием в группе `urltest` проверку по внешнему URL не пройдёт и будет считаться мёртвым | п. 14, вопрос 3 |
| OpenVPN по UDP через detour без UDP не поднимется | предупреждение в описании поля; поведение то же, что у WireGuard |
| В документации ядра таблицы `preferred_by` OpenVPN не называют, хотя endpoint и его DNS-транспорт методы предпочтения реализуют | проверка связки на стенде входит в п. 13.3 |
| Приватный ключ и пароль в бэкапе и в файле состояния открытым текстом | норма контракта; новых мер не вводим |
| Провайдер кладёт в профиль директивы своего клиента | неизвестная директива узел не валит (`ovpn_directive_unknown`) |
| Endpoint апстримный и молодой (sing-box 1.14) | правила п. 8 сверяются командой `check` на каждом бампе ядра |

## 12. Запрос в контракт

| Что | Норма |
|---|---|
| `registry/protocols/openvpn.json` | паспорт п. 9; `body.fields` — все поля `OpenVPNClientEndpointOptions` с типами, умолчаниями, `desc_ru`/`desc_en`, `secret`, `conflicts`, `requires`, `on_invalid`; `mappers.ovpn` — таблицы п. 6; `mappers.singbox` — по образцу `tailscale.json` |
| `registry/source_kinds.json` | вид `openvpn_profile`, п. 4 |
| Предикат `detect` по имени источника | новый: расширение файла, окончание пути URL, `Content-Type` |
| `schema/registry_mapper.schema.json` | `space: "ovpn"`; `body_source: "ovpn"`; описание адресов п. 5.2 |
| `schema/registry.schema.json`, `registry_body.schema.json` | `ovpn` в `sources` и `except_sources` |
| `schema/backup.schema.json`, `docs/BACKUP.md` | `origin.kind: "ovpn"` |
| `registry/allowlists.json` | `openvpn_data_ciphers`, `openvpn_auth_digests` |
| `registry/presets.json` и тело пресета | `openvpn`, п. 7, `in: "both"` |
| `registry/warnings.json` | коды из таблицы ниже, тексты ru/en |
| `docs/MAPPER_ENGINE.md` | раздел о пространстве `ovpn` |
| `corpus/body/ovpn/` | кейсы п. 13.1 |
| `diagrams/body_classify.mmd`, `docs/generated/**`, `VERSION`, `TASKS_LXBOX.md` | по регламенту контракта |

Коды:

| Код | Важность | Исход |
|---|---|---|
| `openvpn_core_unsupported` | warning | узел снят гейтом ядра |
| `ovpn_syntax_invalid` | error | отказ |
| `ovpn_external_file` | error | отказ; в JSON-входе — снятие поля, в авторском теле — только сообщение |
| `ovpn_credentials_missing` | error | отказ |
| `ovpn_interactive_auth_unsupported` | error | отказ |
| `ovpn_key_encrypted` | error | отказ |
| `ovpn_pkcs12_unsupported` | error | отказ |
| `ovpn_tap_unsupported` | error | отказ |
| `ovpn_obfuscation_unsupported` | error | отказ |
| `ovpn_mode_unsupported` | error | отказ |
| `ovpn_control_wrap_conflict` | error | отказ |
| `ovpn_cipher_unknown` | warning | значение снято |
| `ovpn_fragment_with_tcp` | warning | поле снято |
| `ovpn_proxy_ignored` | warning | директива пропущена |
| `ovpn_script_ignored` | warning | директива пропущена |
| `ovpn_dns_ignored` | info | директива пропущена |
| `ovpn_connection_option_ignored` | info | директива пропущена |
| `ovpn_directive_ignored` | info | директива пропущена |
| `ovpn_directive_unknown` | info | директива пропущена |

## 13. Верификация

### 13.1. Корпус

Данные синтетические (`corpus/README.md`): `example-N.com`, `192.0.2.x`,
сертификаты и ключи, сгенерированные для корпуса.

| Кейс | Что проверяет |
|---|---|
| `tls_basic` | `remote` с портом, три inline-блока, минимальное тело |
| `remote_no_port` | порт `1194`; то же с директивой `port` |
| `proto_tcp_client` | нормализация `tcp-client` |
| `multi_remote` | `servers[]`, порядок, `remote-random`, разный `proto` в строках |
| `connection_blocks` | `<connection>` и предупреждение о прочих директивах блока |
| `tls_auth_direction` | `<tls-auth>` с `key-direction 1` |
| `tls_crypt`, `tls_crypt_v2` | обёртка управляющего канала |
| `userpass_inline` | `<auth-user-pass>` |
| `userpass_missing` | отказ `ovpn_credentials_missing` |
| `external_file` | `ca ca.crt` → отказ |
| `cipher_legacy_tls` | `cipher` → `data_ciphers_fallback` |
| `setenv_opt` | `setenv opt data-ciphers`, неизвестная директива под `setenv opt` без предупреждения |
| `friendly_name` | метка из `setenv FRIENDLY_NAME`; второй кейс — метка из имени файла |
| `comments_and_quotes` | `#`, `;`, комментарий после аргументов, кавычки, `\r\n`, BOM, ведущие `--` |
| `scripts_commented_and_live` | закомментированные `up`/`down` не дают ничего; живые — `ovpn_script_ignored` |
| `static_key` | `<secret>`, `ifconfig`, `cipher`, `key-direction` |
| `routes_and_pull` | `route` с маской, `redirect-gateway def1`, `pull-filter`, `route-nopull` |
| `timings` | `keepalive`, `reneg-sec 0`, `ping-restart 0` |
| `compression` | `compress`, `comp-lzo` без аргументов |
| `fragment_tcp` | снятие `fragment` |
| `cipher_unknown` | снятие имени вне словаря |
| `tap`, `pkcs12`, `key_encrypted`, `scramble`, `static_challenge`, `control_wrap_conflict` | отказы |
| `unclosed_block` | `ovpn_syntax_invalid` |
| `unknown_directive` | `ovpn_directive_unknown`, узел живёт |
| `singbox_endpoint` (каталог `body/singbox/`) | JSON-вход; снятие `*_path` |
| `authored_endpoint` (каталог `authored/`) | авторское тело: `*_path` на месте, код сообщён |

Кейс `friendly_name` повторяет строение публичного профиля AntiZapret:
комментарии с закомментированными скриптами, `remote` без порта, `proto tcp`,
`cipher` в режиме `tls`, `setenv opt data-ciphers`, `setenv FRIENDLY_NAME`.
Адрес и ключевой материал заменены синтетическими.

### 13.2. Тесты сторон

| Сторона | Что |
|---|---|
| LxBox | раннеры корпуса `test/contract/body_contract_test.dart`; `registry_sync_test.dart`; `document_registry_test.dart`; страж `engine_no_scheme_names_test.dart`; круговой тест хранения `toJson` / `fromJson` с пересборкой узла из `origin.raw`; срез бэкапа |
| Лаунчер | `TestContractCorpusBody`, `TestRegistryWarningCodesHaveAProducer`, тесты `linkmap` на пространство `ovpn`, материализация и пересборка |
| Обе | тело каждого кейса корпуса с узлом проходит `sing-box check` на ядре пина |

### 13.3. Живая проверка

Профиль: `https://antizapret.prostovpn.org/antizapret-tcp.ovpn` (публичный,
владелец разрешил использовать в тестах). В CI не входит: нужна сеть.

| Шаг | Ожидание |
|---|---|
| Импорт файла | один узел, метка `AntiZapret VPN TCP`, предупреждений уровня warning нет |
| Импорт по URL подпиской | тот же узел |
| Запуск | в логе `tunnel established to v.31337.lol:1194 over tcp` |
| Связка включена, запрос к заблокированному домену | домен разрешается в адрес `10.224.0.x`, сайт отвечает |
| Связка выключена | соединения через узел отклоняются — подтверждение, что связка нужна |
| Бэкап и восстановление | узел на месте, подключается |

Проверка 28.09.2026 на ядре `1.14.1-lx.8` (macOS, отдельный конфиг с
`mixed`-входом, тело собрано вручную по таблицам п. 6): туннель поднялся за
1–2 с, вариант без `data_ciphers` согласовал шифр так же, как вариант со
списком; `rutracker.org` через DNS сервера ответил `301`.

### 13.4. Критерии приёмки

1. Файл `.ovpn`, выбранный в диалоге, даёт узел в LxBox и в лаунчере; тела
   узлов совпадают.
2. Корпус `body/ovpn/` зелёный на обеих сторонах без per-app override.
3. Ни одно тело из корпуса не отвергается командой `sing-box check`.
4. Отклонённый профиль показывает код и причину; остальные файлы той же
   выборки импортированы.
5. Узел переживает перезапуск приложения, бэкап и восстановление.
6. Живая проверка п. 13.3 пройдена на Android (LxBox) и на десктопе
   (лаунчер).
7. В коде движка нет имени схемы `openvpn` и сниффера по содержимому.

## 14. Открытые вопросы

| № | Вопрос | Варианты |
|---|---|---|
| 1 | Много включённых узлов OpenVPN — много одновременных сессий | а) ничего не делать, пользователь выключает лишние; б) предупреждение при импорте, когда включённых узлов больше порога из `limits.json`; в) задача на ядро: подключение по первому обращению (правка апстримного кода) |
| 2 | DNS сервера для всех запросов через узел (`accept_default_resolvers`) | а) переменная пресета, по умолчанию выключено; б) по умолчанию включено; в) поле записи узла |
| 3 | Узел с раздельным туннелированием в группах `urltest` | а) участвует на общих основаниях; б) узел без `redirect-gateway` в файле выходом не считается (`exit_capable_when`), в группы не идёт, целью правил остаётся |
| 4 | Контейнер `amnezia-openvpn` в ссылке `vpn://` | сейчас пропускается; после этой фичи его текст можно отдать тому же разбору — отдельной задачей |
| 5 | Вид источника `openvpn_profile` для подписки, у которой URL не оканчивается на `.ovpn` и `Content-Type` другой | а) не поддерживаем; б) пользователь указывает формат при добавлении подписки |

## Docs to update

| Файл | Что |
|---|---|
| `docs/PROTOCOLS.md` | раздел OpenVPN: вход, таблица директив, отказы |
| `docs/ARCHITECTURE.md` | пространство `ovpn` в описании движка разбора |
| `docs/STORAGE.md` | `origin.kind: "ovpn"` |
| `docs/KERNEL.md` | OpenVPN переходит из «без поля в приложении» в поддерживаемые типы |
| `docs/contract/**` | зеркало сгенерированных страниц после синка |
| `docs/spec/features/README.md` | строка индекса (добавлена вместе с ТЗ) |
| `docs/spec/tasks/576-node-source-is-bare-body.md` | критерий 1: четвёртый вид источника |
| `CHANGELOG.md` | запись в `Unreleased` |
| `README.md`, `README.ru.md`, описания магазинов | OpenVPN в списке протоколов — на выпуске |
| `docs/api/debug-api-reference.md` | none: новых маршрутов нет |
