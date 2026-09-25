# L×Box v2.25.5

**A patch on top of [v2.25.4](https://github.com/Leadaxe/LxBox/releases/tag/v2.25.4).**

The core moves to `v1.14.2-lx.3`: VLESS servers with Vision and VLESS
Encryption connect on any transport, including XHTTP, and XHTTP picks the HTTP
version from `alpn`. hysteria2 links from 3x-ui with gecko keep their packet
sizes, XHTTP with `uplinkDataPlacement` `body`/`auto` keeps the setting.
Servers from sing-box JSON and the latency check now go through the protocol
registry, like links and the working config. Subscription parsing and the
registry guard are about twice as fast. JSON gets syntax highlighting in the
config editor and on the JSON viewing screens.

**Патч поверх [v2.25.4](https://github.com/Leadaxe/LxBox/releases/tag/v2.25.4).**

Ядро обновлено до `v1.14.2-lx.3`: серверы VLESS с Vision и VLESS-шифрованием
подключаются на любом транспорте, включая XHTTP, а XHTTP выбирает версию HTTP
по `alpn`. Ссылки hysteria2 из 3x-ui с gecko больше не теряют размеры пакетов,
XHTTP с `uplinkDataPlacement` `body`/`auto` не теряет настройку. Серверы из
sing-box JSON и проверка задержки теперь проходят через реестр протоколов, как
ссылки и рабочий конфиг. Разбор подписок и гард реестра примерно вдвое быстрее.
JSON подсвечивается в редакторе конфига и на экранах просмотра JSON.

---

<details open>
<summary><h2>🇬🇧 English</h2></summary>

## 🆕 New

| § | Before | Now |
|---|---|---|
| §554 | The config editor and the JSON field of the add-server wizard showed plain monospace text | JSON syntax highlighting: keys, strings, numbers and brackets; light or dark scheme follows the app theme |
| §554 | The JSON tab in node settings, the node view screen and the subscription node inspector showed plain text | The same highlighted read-only JSON viewer on all three screens |

## 🔄 Changed

| § | Before | Now |
|---|---|---|
| §544 | Core `v1.14.2-lx.1`: every VLESS server with both Vision and VLESS Encryption failed with `vision: not a valid supported TLS connection` ([sing-box-lx#29](https://github.com/Leadaxe/sing-box-lx/issues/29)) | Core `v1.14.2-lx.3`: such servers connect on any transport, including XHTTP |
| §544 | XHTTP ignored `tls.alpn` | XHTTP picks HTTP/1.1, HTTP/2 or HTTP/3 from `tls.alpn`, as Xray does; h3-only servers work |
| §549, §553 | Registry guard (config build, latency-check batches): ~63 µs per server | ~31 µs per server: schemas and field relations are parsed once, a base64 key is decoded once |
| §551 | Parsing a link: ~395 µs on a mixed corpus, the scheme route rebuilt on every subscription line | ~147 µs: the route and the declared parameter names are computed once per section set; an Xray outbound is serialized once. Measured on a desktop host, behaviour unchanged |

## 🩹 Fixes

| § | Before | Now |
|---|---|---|
| §543 | hysteria2 links from 3x-ui with gecko: `minPacketSize`/`maxPacketSize` and `security=tls` were reported as unread, the server came up with the core's default sizes | The sizes reach `obfs`, `security=tls` is accepted silently, any other `security` value only adds a warning |
| §544 | VLESS with Vision and VLESS Encryption over XHTTP arrived without `flow`, and a Vision server dropped the connection | `flow` stays when encryption is set; without encryption it is still removed when a transport is set |
| §547 | XHTTP with `uplinkDataPlacement=body`/`auto` got `packet-up` added, or lost the placement with a false "XHTTP parameter reset" warning under `stream-one`/`stream-up` | `body`/`auto` pass as is with any mode, on every input (link, Xray, sing-box JSON); `packet-up` is required only for `header`/`cookie` |
| §546 | One server with an invalid field combination could fail the latency check for a whole batch | The latency check and server diagnostics pass the same registry guard as the working config: such a server is marked invalid with the registry codes, the rest are checked; a server whose detour was dropped is not checked |
| §552, §553 | A server with an empty `server` was dropped, one without the `server` key passed | A server without an address (no key or `""`) is dropped with `field_missing` on parsing, in the build guard and in the latency check |

## 🔧 Under the hood

| § | Before | Now |
|---|---|---|
| — | Contract with the launcher 1.1.53 | 1.1.56 |
| §545 | Servers from sing-box JSON (subscription, JSON editor, Smart-Paste, detour hops) were built from the entry as is | Built from the entry the registry cleaned, like links and Xray configs; the original object is kept verbatim, the core, backups and re-parsing see what the author sent |
| §546 | The sing-box emitters kept their own copies of registry rules (`flow`, hysteria2 `obfs`, XHTTP enums, uTLS/Reality on QUIC) | The registry decides on parsing and in the build guard; behaviour on normal input unchanged |
| §547 | Parsing kept copies of registry rules (Reality `key_share`, hysteria2 `obfs`, VLESS `encryption=none`), the build code kept XHTTP placement↔mode and Shadowsocks `plugin_opts`↔`plugin` | All of them are decided by the registry; the `obfs` warning on a sing-box JSON server uses the registry text, the same as for a link |
| §553 | Named references in the registry schemas were resolved only while judging a value | Resolved on load, as in the launcher |
| — | — | `SECURITY.md`: private vulnerability reporting policy (EN+RU) |

</details>

<details open>
<summary><h2>🇷🇺 Русский</h2></summary>

## 🆕 Новое

| § | Что было | Что стало |
|---|---|---|
| §554 | Редактор конфига и JSON-поле мастера добавления сервера показывали текст без подсветки | Подсветка синтаксиса JSON: ключи, строки, числа, скобки; светлая или тёмная схема по теме приложения |
| §554 | Вкладка JSON в настройках узла, экран просмотра узла и инспектор узлов подписки показывали простой текст | На всех трёх экранах — тот же просмотрщик JSON с подсветкой, только чтение |

## 🔄 Изменено

| § | Что было | Что стало |
|---|---|---|
| §544 | Ядро `v1.14.2-lx.1`: каждый сервер VLESS с Vision и VLESS-шифрованием одновременно падал с `vision: not a valid supported TLS connection` ([sing-box-lx#29](https://github.com/Leadaxe/sing-box-lx/issues/29)) | Ядро `v1.14.2-lx.3`: такие серверы подключаются на любом транспорте, включая XHTTP |
| §544 | XHTTP игнорировал `tls.alpn` | XHTTP выбирает HTTP/1.1, HTTP/2 или HTTP/3 по `tls.alpn`, как Xray; серверы только с h3 работают |
| §549, §553 | Гард реестра (сборка конфига, батчи проверки задержки): ~63 мкс на сервер | ~31 мкс на сервер: схемы и связи полей разбираются один раз, ключ base64 декодируется один раз |
| §551 | Разбор ссылки: ~395 мкс на смешанном корпусе, маршрут схемы пересобирался на каждой строке подписки | ~147 мкс: маршрут и объявленные имена параметров считаются один раз на состав секций, outbound Xray сериализуется один раз. Замер на десктопе, поведение не меняется |

## 🩹 Исправлено

| § | Что было | Что стало |
|---|---|---|
| §543 | Ссылки hysteria2 из 3x-ui с gecko: `minPacketSize`/`maxPacketSize` и `security=tls` шли в «не прочитан», сервер поднимался с размерами по умолчанию из ядра | Размеры доезжают до `obfs`, `security=tls` принимается молча, иное значение `security` только добавляет предупреждение |
| §544 | VLESS с Vision и VLESS-шифрованием поверх XHTTP приезжал без `flow`, и сервер с Vision рвал соединение | С шифрованием `flow` остаётся; без шифрования он по-прежнему снимается, если задан транспорт |
| §547 | XHTTP с `uplinkDataPlacement=body`/`auto`: дописывался `packet-up`, а при `stream-one`/`stream-up` placement снимался с ложным предупреждением «параметр XHTTP сброшен» | `body`/`auto` доезжают как есть при любом режиме, на всех входах (ссылка, Xray, sing-box JSON); `packet-up` обязателен только для `header`/`cookie` |
| §546 | Один сервер с недопустимой комбинацией полей мог уронить проверку задержки целого батча | Проверка задержки и диагностика сервера проходят тот же гард реестра, что и рабочий конфиг: такой сервер помечается невалидным с кодами реестра, остальные проверяются; сервер со снятым detour не проверяется |
| §552, §553 | Сервер с пустым `server` снимался, без ключа `server` — проходил | Сервер без адреса (ключа нет или `""`) снимается с `field_missing` на разборе, в гарде сборки и в проверке задержки |

## 🔧 Под капотом

| § | Что было | Что стало |
|---|---|---|
| — | Контракт с лаунчером 1.1.53 | 1.1.56 |
| §545 | Серверы из sing-box JSON (подписка, редактор JSON, Smart-Paste, звенья detour) строились по записи как есть | Строятся по записи, которую очистил реестр, как ссылки и Xray-конфиги; исходный объект хранится дословно — ядро, бэкап и повторный разбор видят то, что прислал автор |
| §546 | Эмиттеры sing-box держали свои копии правил реестра (`flow`, `obfs` у hysteria2, enum-поля XHTTP, uTLS/Reality на QUIC) | Решает реестр — на разборе и в гарде сборки; на штатных входах поведение не меняется |
| §547 | Разбор держал копии правил реестра (`key_share` у Reality, `obfs` у hysteria2, `encryption=none` у VLESS), код сборки — связи placement↔mode у XHTTP и `plugin_opts`↔`plugin` у Shadowsocks | Всё это судит реестр; предупреждение про `obfs` у сервера из sing-box JSON — с текстом из реестра, тем же, что у ссылки |
| §553 | Именованные ссылки в схемах реестра разворачивались только при судействе значения | Разворачиваются при загрузке, как у лаунчера |
| — | — | `SECURITY.md`: политика приватных сообщений об уязвимостях (EN+RU) |

</details>

---

## Install / Установка

```bash
adb install -r LxBox-v2.25.5-arm64-v8a.apk
```

Без uninstall! Поверх существующей установки. Настройки и подписки сохранятся.

No uninstall needed — install over the existing one. Settings and subscriptions
are preserved.

---

Previous release / Предыдущий релиз: [v2.25.4](docs/releases/v2.25.4.md).
