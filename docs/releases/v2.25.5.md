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

## ✨ Added

- **JSON syntax highlighting.** The config editor and the JSON field of the
  add-server wizard highlight keys, strings, numbers and brackets; the light or
  dark scheme follows the app theme. The JSON tab in node settings, the node
  view screen and the subscription node inspector show JSON in the same
  highlighted read-only viewer.

## 🔄 Changed

- **Core v1.14.2-lx.3.** VLESS servers with both Vision and VLESS Encryption
  connect on any transport, including XHTTP; previously every such server
  failed with `vision: not a valid supported TLS connection`
  ([sing-box-lx#29](https://github.com/Leadaxe/sing-box-lx/issues/29)). XHTTP
  picks HTTP/1.1, HTTP/2 or HTTP/3 from `tls.alpn`, as Xray does: h3-only
  servers work, and an `alpn` that XHTTP servers used to ignore silently now
  changes the HTTP version.
- **Faster registry guard.** The guard that checks servers when the config and
  latency-check batches are built takes ~31 µs per server instead of ~63:
  schemas and field relations are parsed once, a base64 key is decoded once.
- **Faster link parsing.** A link takes ~147 µs instead of ~395 on a mixed
  corpus: the scheme route and the declared parameter names are computed once
  per section set instead of on every subscription line, and an Xray outbound
  is serialized once. Measured on a desktop host; behaviour does not change.

## 🩹 Fixes

- **hysteria2 links from 3x-ui with gecko keep their packet sizes.** 3x-ui
  writes the gecko obfuscation range as `minPacketSize`/`maxPacketSize` and adds
  `security=tls` to every link. All three used to be reported as unread, and the
  server came up with gecko but with the core's default sizes. Now the sizes
  reach `obfs`, `security=tls` is accepted silently, and any other `security`
  value only adds a warning.
- **VLESS with Vision and VLESS Encryption over XHTTP keeps `flow`.** Such a
  server arrived without `flow`, and a Vision server dropped the connection.
  With encryption, Vision runs on top of the encryption layer and the transport
  does not get in its way, so `flow` now stays. Without encryption it is still
  removed when a transport is set.
- **XHTTP keeps `uplinkDataPlacement=body`/`auto`.** A server with `body` or
  `auto` got `packet-up` added, and with an explicit `stream-one`/`stream-up`
  lost the placement with a false "XHTTP parameter reset" warning. Now
  `body`/`auto` pass as is with any mode, on every input (link, Xray, sing-box
  JSON); `packet-up` is required only for `header`/`cookie`.
- **Latency checks no longer fail a whole batch because of one bad server.**
  The latency check and server diagnostics now pass the same registry guard as
  the working config. A server the guard would drop is marked invalid with the
  registry codes, the rest are checked as usual; a server whose detour was
  dropped is not checked.
- **A server without an address is dropped on every input.** A server with an
  empty `server` was dropped, one without the `server` key passed. Now both are
  dropped with `field_missing` on parsing, in the build guard and in the
  latency check.

## 🔧 Under the hood

- Contract with the launcher: 1.1.56.
- Servers from sing-box JSON (subscription, JSON editor, Smart-Paste, detour
  hops) are built from the entry the registry cleaned, like links and Xray
  configs. The original object is kept verbatim: what the author sent still
  goes to the core, and backups and re-parsing see the original.
- The sing-box emitters and parsing no longer keep their own copies of registry
  rules (`flow`, hysteria2 `obfs`, XHTTP enums and placement↔mode, uTLS/Reality
  on QUIC, Reality `key_share`, VLESS `encryption=none`, Shadowsocks
  `plugin_opts`↔`plugin`): the registry decides on parsing and in the build
  guard. Behaviour on normal input does not change; the `obfs` warning on a
  sing-box JSON server now uses the registry text, the same as for a link.
- Named references in the registry schemas are resolved on load, as in the
  launcher.
- `SECURITY.md`: private vulnerability reporting policy (EN+RU).

</details>

<details open>
<summary><h2>🇷🇺 Русский</h2></summary>

## ✨ Добавлено

- **Подсветка синтаксиса JSON.** Редактор конфига и JSON-поле мастера
  добавления сервера подсвечивают ключи, строки, числа и скобки; светлая или
  тёмная схема — по теме приложения. Вкладка JSON в настройках узла, экран
  просмотра узла и инспектор узлов подписки показывают JSON в том же
  просмотрщике с подсветкой, только чтение.

## 🔄 Изменено

- **Ядро v1.14.2-lx.3.** Серверы VLESS с Vision и VLESS-шифрованием
  одновременно подключаются на любом транспорте, включая XHTTP; раньше каждый
  такой сервер падал с `vision: not a valid supported TLS connection`
  ([sing-box-lx#29](https://github.com/Leadaxe/sing-box-lx/issues/29)). XHTTP
  выбирает HTTP/1.1, HTTP/2 или HTTP/3 по `tls.alpn`, как Xray: серверы только
  с h3 работают, а `alpn`, который XHTTP-сервер раньше молча игнорировал,
  теперь меняет версию HTTP.
- **Гард реестра быстрее.** Проверка серверов при сборке конфига и батчей
  проверки задержки занимает ~31 мкс на сервер вместо ~63: схемы и связи полей
  разбираются один раз, ключ base64 декодируется один раз.
- **Разбор ссылок быстрее.** Ссылка разбирается за ~147 мкс вместо ~395 на
  смешанном корпусе: маршрут схемы и объявленные имена параметров считаются
  один раз на состав секций, а не на каждой строке подписки, outbound Xray
  сериализуется один раз. Замер на десктопе; поведение не меняется.

## 🩹 Исправления

- **Ссылки hysteria2 из 3x-ui с gecko не теряют размеры пакетов.** 3x-ui
  пишет диапазон gecko-обфускации парой `minPacketSize`/`maxPacketSize` и
  добавляет `security=tls` в каждую ссылку. Раньше все три параметра шли в «не
  прочитан», и сервер поднимался с gecko, но с размерами по умолчанию из ядра.
  Теперь размеры доезжают до `obfs`, `security=tls` принимается молча, а иное
  значение `security` только добавляет предупреждение.
- **VLESS с Vision и VLESS-шифрованием поверх XHTTP сохраняет `flow`.** Такой
  сервер приезжал без `flow`, и сервер с Vision рвал соединение. С шифрованием
  Vision работает поверх его слоя, и транспорт ему не мешает, поэтому `flow`
  теперь остаётся. Без шифрования он по-прежнему снимается, если задан
  транспорт.
- **XHTTP сохраняет `uplinkDataPlacement=body`/`auto`.** Серверу с `body` или
  `auto` дописывался `packet-up`, а при явном `stream-one`/`stream-up`
  placement снимался с ложным предупреждением «параметр XHTTP сброшен».
  Теперь `body`/`auto` доезжают как есть при любом режиме, на всех входах
  (ссылка, Xray, sing-box JSON); `packet-up` обязателен только для
  `header`/`cookie`.
- **Проверка задержки больше не падает целым батчем из-за одного плохого
  сервера.** Проверка задержки и диагностика сервера теперь проходят тот же
  гард реестра, что и рабочий конфиг. Сервер, который гард снял бы, помечается
  невалидным с кодами реестра, остальные проверяются как обычно; сервер со
  снятым detour не проверяется.
- **Сервер без адреса снимается на всех входах.** Сервер с пустым `server`
  снимался, без ключа `server` — проходил. Теперь оба снимаются с
  `field_missing` на разборе, в гарде сборки и в проверке задержки.

## 🔧 Под капотом

- Контракт с лаунчером: 1.1.56.
- Серверы из sing-box JSON (подписка, редактор JSON, Smart-Paste, звенья
  detour) строятся по записи, которую очистил реестр, как ссылки и
  Xray-конфиги. Исходный объект хранится дословно: в ядро по-прежнему идёт то,
  что прислал автор, бэкап и повторный разбор видят оригинал.
- Эмиттеры sing-box и разбор больше не держат своих копий правил реестра
  (`flow`, `obfs` у hysteria2, enum-поля и связь placement↔mode у XHTTP,
  uTLS/Reality на QUIC, `key_share` у Reality, `encryption=none` у VLESS,
  `plugin_opts`↔`plugin` у Shadowsocks): решает реестр — на разборе и в гарде
  сборки. На штатных входах поведение не меняется; предупреждение про `obfs` у
  сервера из sing-box JSON теперь с текстом из реестра, тем же, что у ссылки.
- Именованные ссылки в схемах реестра разворачиваются при загрузке, как у
  лаунчера.
- `SECURITY.md`: политика приватных сообщений об уязвимостях (EN+RU).

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
