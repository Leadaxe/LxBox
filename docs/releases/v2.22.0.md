# L×Box v2.22.0

**A node's identity is now its tag.** A server rotated under the same name —
new IP, new SNI, new credentials — stays the same node, and “disabled” stays
where you put it. The desktop transfer file was rebuilt: no more extension
pocket, plain fields instead, import merges rather than replaces, and whatever
cannot travel is named out loud. Plus Xray relay records that no longer collapse
into one, DoQ / DoH3 in the DNS form, and a core update that revives DNS behind
an XHTTP detour.

**Идентичность узла — его тег.** Сервер, прокрученный провайдером под тем же
именем — новый IP, новый SNI, новые креды, — остаётся тем же узлом, и отметка
«выключен» никуда не девается. Файл переноса на десктоп пересобран: карман
расширений упразднён, вместо него обычные поля, импорт сливает, а не замещает,
и всё, что переехать не может, названо вслух. Плюс Xray-релеи, которые больше
не схлопываются в одну запись, DoQ / DoH3 в форме DNS и обновление ядра,
воскрешающее DNS за XHTTP-detour'ом.

---

<details open>
<summary><h2>🇬🇧 English</h2></summary>

## ⚠️ Breaking

### The desktop transfer file has no `extensions` section any more

The LX Backup used to carry an `extensions` pocket: anything the other side did
not understand rode along untouched. It aged badly — the other side would edit
the canonical part, and the pocket kept a stale copy of the same thing.

The pocket is gone. Everything that lived in it and means something on both
sides is now an ordinary field of the file: a subscription's identity
(user-agent, HWID and the rest), a server's folder, the names of Directions and
chains, a Direction's node-test budget, and the flat `sni` / `idle_timeout` /
`keep_alive` / `endpoint` / `awg` fields of WARP entries.

The rest honestly stays on the device — and is **named**, not silently dropped:
subscription import rules, the refresh action, the detour policy, per-app and
Wi-Fi matchers, the body of a `kind=json` rule, folder ping settings. On export
the app lists what did not make it into the file; on import, what was dropped.

The “Transfer to desktop” card no longer promises a lossless round trip,
because it no longer is one.

### A node's identity is its tag ([docs/spec/tasks/400](docs/spec/tasks/400-identity-tag-mirror.md))

The “node disabled” mark used to hang on a hash of the node's contents. A
provider rotating a server under the same name — a new IP, a different group, an
edited SNI or fresh credentials — counted as a brand-new node: the mark came off
without a word, and a node you had switched off came back into the config.

The key is now the node's **tag**, uniquified inside its source (namesakes get
`-2`, `-3` suffixes), and the mark follows the node through any edit of its
body. Changing the storage form (`uri` ↔ `config_json`) and changing the
subscription's tag prefix no longer move identity either.

| Provider does this | Before | Now |
|---|---|---|
| same name, new address / SNI / credentials | mark lost | mark kept |
| renames the node | mark kept | **mark lost** |
| ships one server twice under two names | one node | two nodes, disabled separately |

The trade is deliberate: the name *is* the identity, so a rename is a new node.

Old marks migrate on their own the first time a source is parsed — a network
refresh or bodies coming up from the cache at startup; unrecognised ones are
dropped (no node with those contents exists in the source anyway). A node with
no name gets a synthesised tag `<scheme>-<host>-<port>`, so the list never holds
a nameless row.

## 💾 Transfer to desktop, rebuilt

### Import merges — it does not replace

Local things absent from the file survive an import. Matching is done on a key
you can reason about:

| Entity | Matched by |
|---|---|
| subscription | its URL |
| folder | its name |
| server | the canonical body — a link drops the `#…` fragment, JSON drops `tag` and `detour`, keys are sorted |
| Directions, chains, rule targets | the tag, **case-sensitively** |

Bodies used to be compared character by character, so one and the same server —
re-serialised by another tool or carrying a different remark — was appended as a
second node on every repeat import.

Tags are compared case-sensitively, the way the core does and the way the
Direction form does. An incoming `VPN-DE` next to a live `vpn-de` used to be
declared a namesake and silently lost, while a rule pointing at `VPN-DE` was
considered to have a known target and arrived **enabled** — which is exactly the
core-config failure that gate exists to prevent.

Subscription settings from a file with the same URL are applied; the disabled-node
marks are merged rather than overwritten. The rules section is still the one
section replaced whole.

A rule whose target does not exist on the receiving side is still imported
**disabled** rather than lost or enabled: an enabled rule with a dead target
takes the whole core config down.

The merge rule is now one rule for both sides — written into the shared contract
and checked by a corpus with a pre-state
([docs/spec/tasks/407](docs/spec/tasks/407-backup-corpus-pre-state-merge.md));
importing into an empty state could not tell a merge from a replace.

### A Direction's node-test budget travels ([docs/spec/tasks/409](docs/spec/tasks/409-direction-ping-options-backup.md))

A Direction's own URL and timeout (`ping_url`, `ping_timeout_ms`) were not
carried by the LX Backup at all: on the new machine the Direction quietly fell
back to the global default, and the export did not know it had lost anything.
The internal backup had been carrying them all along — exactly two formats
disagreed.

### Replacing on import no longer kills the device's Debug API ([docs/spec/tasks/413](docs/spec/tasks/413-backup-replace-keeps-debug-api.md))

An export does not include the Debug API token and port by default, but an
import with replace wrote the incoming `vars` over the current ones whole — so
after the restart the debug server came up on the default port with a new token,
and whatever was knocking on the old one stopped working. Debug API keys absent
from the file now stay with the device; keys present in the file still win.

## 🔀 Xray relays: distinct records stay distinct ([docs/spec/tasks/404](docs/spec/tasks/404-dialer-proxy-signature.md))

Subscription dedup compared records by a coarse key — protocol + address + port
+ credentials — and saw neither the transport, nor TLS, nor the dial path. One
server shipped by the provider under two SNIs or two transports arrived as a
single node. So did the pair “direct record + BYPASS record of the same server”,
even though BYPASS is a different route and not a spare — and where the direct
path is cut, the user was left with nothing that works.

A record is now recognised by its canonical body together with its full dial
path.

Along with it, `sockopt.dialerProxy`: a relay that itself dials through the next
relay is parsed as a multi-hop. An unreachable or looping relay now **rejects
its owner** with a warning instead of quietly substituting a node with a direct
path — the provider wrapped the dial in a relay precisely because going out
directly is not wanted. A hop's tag is the relay's own tag from the provider's
config; the `⚙` marker stayed in the node list and no longer travels into the
core config.

## 🌐 DNS: DoQ and DoH3 in the editor ([docs/spec/tasks/411](docs/spec/tasks/411-dns-doq-doh3-form.md))

The core has understood `quic` and `h3` for a long time, but the form offered
only UDP / DoT / DoH and sent everything else off to the JSON tab.

| Mode | `type` | Default port | Path | TLS SNI |
|---|---|---|---|---|
| UDP | `udp` | 53 | — | — |
| DoT | `tls` | 853 | — | yes |
| DoH | `https` | 443 | yes | yes |
| **DoQ** | `quic` | 853 | — | yes |
| **DoH3** | `h3` | 443 | yes | yes |
| Group | `group` | — | — | — |

The type selector on a phone is now always a dropdown — six segments do not fit
on one row.

## ⚙️ WARP: `vhttp: auto` survives a round trip ([docs/spec/tasks/402](docs/spec/tasks/402-direction-chain-label-removed.md))

The core has understood `auto` (h3 falling back to h2) since lx.27 and the WARP
wizard already offered it, but both parsers knew only the pair `{h3, h2}` and
silently forced `h3`. A node built by the wizard worked; the same node exported
to a link and imported back lost `auto`.

## 🛡 Guards: one bad node can no longer stop the VPN

### `header` uplink placement without a mode ([docs/spec/tasks/416](docs/spec/tasks/416-xhttp-packet-up-guard.md))

A node carrying `uplink_data_placement: header` but no explicit mode was
rejected by the core **together with the entire config** — the core accepts that
placement only in `packet-up` mode. The service did not start at all, over a
node the user may never have selected.

| Source node | What happens now | Warning |
|---|---|---|
| `header`, mode empty | the mode is written as `packet-up`, placement kept | yes |
| `header`, mode `packet-up` | nothing changes | no |
| `header`, some other mode | the placement is dropped, the mode is left alone | yes |
| any other placement | passthrough as before | no |

Where the source states no mode, there is no intent to respect and the node is
assembled the way the server expects it. Where a mode is stated and conflicts,
the conflict is not resolved on the user's behalf: the placement comes off, the
mode stays. Either way the node carries a warning.

### `extra` no longer clobbers a flat parameter ([docs/spec/tasks/410](docs/spec/tasks/410-xhttp-extra-empty-not-clobber.md))

A v2.21.0 regression: `Failed to start service … uplink_data_placement can be
header only in packet-up mode` whenever a subscription held an XHTTP node whose
Xray link carried `mode=packet-up` as a flat parameter and `"mode": ""` inside
`extra`. The empty string from `extra` overwrote the flat value, the core took
mode `auto` and rejected the whole config. An empty value in `extra` no longer
overrides a flat parameter (matching the launcher's Go reference); a non-empty
one still wins.

Along with it, `host`, `path` and `mode` are now read only from the link's flat
parameters, the way Xray merges `extra`: the same node carried `path: "/"` in
`extra` while the working path was the flat one, and the server answered 404.

**The whole registry of these guards is now written down** —
[docs/GUARDS.md](docs/GUARDS.md) lists every place where L×Box drops,
normalises, defaults or degrades a value so the core does not fail, with
`file:line` for each row.

## 🧰 Fixes

- **A false “Stop timed out” on a successful stop**
  ([docs/spec/tasks/415](docs/spec/tasks/415-stop-timeout-budget.md)) — stopping
  a heavy tunnel (WARP/AWG with dozens of live connections) takes about five
  seconds, and the internal wait budget was five: it expired an instant before
  the stop completed. The tunnel went down properly, but the user saw a red
  error and an emergency force-stop landed on top of a stop already in
  progress. The budgets now ascend: core wait (9 s) < the call from the UI
  (10 s) < the emergency kill (12 s), each level letting the one below finish
  its sentence. A genuinely stuck core still shows the error and still gets
  force-stopped.

- **The config was rebuilt on every launch**
  ([docs/spec/tasks/414](docs/spec/tasks/414-config-dirty-check-files-dir.md)) —
  the “settings newer than config” check looked for `singbox_config.json` in the
  Flutter directory (`app_flutter/`) while native writes it into `files/`. The
  file was never found, so every cold start counted the config as stale and
  rebuilt it. The path now comes from native, the file-time comparison works as
  designed, and a rebuild happens only when the settings actually changed.

- **A removed Direction's ping settings stayed in storage**
  ([docs/spec/tasks/408](docs/spec/tasks/408-ping-options-groups-heal.md)) — a
  Direction's own URL and timeout outlived its deletion: the key hung around as
  an orphan, got into the backup, and the next Direction created with the same
  tag (`vpn-3` is freed and handed out again) silently inherited someone else's
  check address. The key is now removed in the same transaction as every other
  reference — together with the `<tag>-auto` twin's key — and orphans already
  accumulated are cleaned up when the Direction list loads (including after a
  backup restore). Disabling a Direction still leaves its override alone: that
  is reversible.

- **The app picker toggles only on a tap on the checkbox**
  ([docs/spec/tasks/412](docs/spec/tasks/412-app-picker-checkbox-only-tap.md)) —
  selection used to toggle on a tap anywhere in the row, so scrolling a long
  list brushed a row and dropped an app out of the selection unnoticed. Only the
  checkbox, with its standard touch target, reacts now.

## 🧬 Core: `1.14.0-lx.30`

Up from `v1.14.0-lx.28-rc.1`.

- **DNS through a `detour` to an XHTTP node is fixed.** `udp`/`tcp`/`tls`
  servers behind such a detour died on the very first query with
  `write request: context canceled`. It looked like red URL tests on `masque`
  and `wireguard` nodes when probing them by domain name (the same node was
  green by IP), and like a dead system DNS over TUN while the tunnel was up.
- **XHTTP no longer pins the CPU at 100%** when the path resets upload streams —
  a circuit breaker in the xmux pool retires a connection after repeated stream
  failures instead of retrying in a tight loop.
- A `packet-up` upload survives a graceful `GOAWAY`, and a pool leak in
  `stream-up` is closed.

The core's Java surface changed by additions only (chain RPC, which the client
does not bind), so no glue changes were needed.

## 🧪 Tests

`flutter analyze`, the full test suite and all six checkers. The shared
contract corpus is green on both sides at 0.12.8.

</details>

<details open>
<summary><h2>🇷🇺 Русский</h2></summary>

## ⚠️ Ломающие изменения

### В файле переноса на десктоп больше нет раздела `extensions`

В LX Backup был карман расширений: всё, чего не понимала другая сторона,
провозилось в нём нетронутым. Он протухал — каноническую часть правили на той
стороне, а в кармане лежала её устаревшая копия того же самого.

Карман упразднён. Всё, что в нём жило и имеет смысл на обеих сторонах, стало
обычными полями файла: identity подписки (user-agent, HWID и остальное), папка
сервера, имена Направлений и цепочек, бюджет теста узлов Направления, плоские
`sni` / `idle_timeout` / `keep_alive` / `endpoint` / `awg` у записей WARP.

Остальное честно остаётся на устройстве и **называется вслух**, а не теряется
молча: правила импорта подписки, действие по обновлению, политика detour,
матчеры по приложениям и Wi-Fi, тело правила `kind=json`, настройки пинга папки.
При экспорте приложение перечисляет, что не попало в файл, при импорте — что
было отброшено.

Карточка «Перенос на десктоп» больше не обещает круг без потерь — потому что
его и не было.

### Идентичность узла — его тег ([docs/spec/tasks/400](docs/spec/tasks/400-identity-tag-mirror.md))

Отметка «узел выключен» держалась на хеше содержимого узла. Ротация сервера
провайдером под тем же именем — смена IP, смена группы, правка SNI или
кредов — считалась появлением нового узла: отметка молча снималась, а
выключенный узел возвращался в конфиг.

Теперь ключ отметки — **тег** узла, уникализированный внутри источника (тёзки
получают суффиксы `-2`, `-3`), и отметка следует за узлом через любую правку
тела. Смена формы хранения (`uri` ↔ `config_json`) и смена префикса тегов
подписки идентичность тоже больше не двигают.

| Провайдер делает так | Было | Стало |
|---|---|---|
| то же имя, новый адрес / SNI / креды | отметка терялась | отметка держится |
| переименовывает узел | отметка держалась | **отметка теряется** |
| присылает один сервер дважды под разными именами | один узел | два узла, гасятся раздельно |

Обмен сознательный: имя и есть идентичность, поэтому переименование — это новый
узел.

Старые отметки переезжают сами при первом разборе источника — сетевом
обновлении или подъёме тел из кэша на старте; неопознанные снимаются (узла с
таким содержимым в источнике всё равно нет). Узел без имени получает
синтезированный тег `<схема>-<хост>-<порт>` — безымянных строк в списке не
бывает.

## 💾 Перенос на десктоп, пересобранный

### Импорт сливает, а не замещает

Локальное, чего в файле нет, импорт переживает. Опознание идёт по ключу,
который можно объяснить:

| Сущность | Опознаётся по |
|---|---|
| подписка | URL |
| папка | имени |
| сервер | каноническому телу — у ссылки отбрасывается фрагмент после `#`, у JSON — `tag` и `detour`, ключи сортируются |
| Направления, цепочки, цели правил | тегу, **с учётом регистра** |

Раньше тела сравнивались посимвольно, и один и тот же сервер — пересобранный
другим сериализатором или подписанный другой ремаркой — доливался в список
вторым узлом при каждом повторном импорте.

Теги сравниваются с учётом регистра — как это делает ядро и как это делает
форма создания Направления. Раньше приехавшее `VPN-DE` при живом `vpn-de`
объявлялось тёзкой и терялось молча, а правило на `VPN-DE` считалось имеющим
известную цель и приезжало **включённым** — ровно в тот отказ конфига ядра,
ради предотвращения которого гейт и стоит.

Настройки подписки с тем же URL применяются из файла; отметки выключенных узлов
объединяются, а не замещаются. Раздел правил по-прежнему единственный, который
замещается целиком.

Правило, ссылающееся на цель, которой на принимающей стороне нет, по-прежнему
импортируется **выключенным**, а не теряется и не включается: включённое
правило с мёртвой целью роняет конфиг ядра целиком.

Норма слияния теперь одна на обе стороны — записана в общем контракте и
проверяется корпусом с предсостоянием
([docs/spec/tasks/407](docs/spec/tasks/407-backup-corpus-pre-state-merge.md)):
импорт в пустое состояние не отличал слияние от замены.

### Бюджет теста узлов Направления переносится ([docs/spec/tasks/409](docs/spec/tasks/409-direction-ping-options-backup.md))

Персональные URL и таймаут замера Направления (`ping_url`, `ping_timeout_ms`)
LX-бэкап не переносил вовсе: на новой машине Направление оказывалось на
глобальном умолчании молча, и экспорт о потере не знал. Внутренний бэкап
переносил их всё это время — расходились ровно два формата.

### Импорт с заменой больше не гасит Debug API устройства ([docs/spec/tasks/413](docs/spec/tasks/413-backup-replace-keeps-debug-api.md))

Экспорт по умолчанию не включает токен и порт Debug API, а импорт с заменой
писал входящий `vars` поверх целиком — и после рестарта сервер отладки
поднимался на дефолтном порту с новым токеном, а тот, кто стучался на старый,
переставал попадать. Теперь ключи Debug API, которых нет в файле, остаются
устройству; ключи из файла по-прежнему побеждают.

## 🔀 Xray-релеи: разные записи остаются разными ([docs/spec/tasks/404](docs/spec/tasks/404-dialer-proxy-signature.md))

Дедуп подписки сравнивал записи по грубому ключу «протокол + адрес + порт +
креды» и не видел ни транспорта, ни TLS, ни пути дозвона. Один сервер,
присланный провайдером под двумя SNI или двумя транспортами, приезжал одним
узлом. Пара «прямая запись + BYPASS-запись того же сервера» — тоже, хотя BYPASS
это другой маршрут, а не резерв, и там, где прямой путь зарезан, пользователь
оставался без рабочего варианта.

Теперь запись опознаётся по каноническому телу вместе с полным путём дозвона.

Заодно `sockopt.dialerProxy`: релей, который сам звонит через следующий релей,
разбирается многохопом. Недостижимый или зацикленный релей теперь
**отбраковывает владельца** с предупреждением, а не подменяет его узлом с
прямым путём — провайдер завернул дозвон в релей именно потому, что прямой
выход нежелателен. Тег звена — собственный тег релея из конфига провайдера;
маркер `⚙` остался только в списке узлов и в конфиг ядра больше не уезжает.

## 🌐 DNS: DoQ и DoH3 в редакторе ([docs/spec/tasks/411](docs/spec/tasks/411-dns-doq-doh3-form.md))

Типы `quic` и `h3` ядро понимало давно, но форма предлагала только UDP / DoT /
DoH и отправляла всё остальное на вкладку JSON.

| Режим | `type` | Порт по умолчанию | Path | TLS SNI |
|---|---|---|---|---|
| UDP | `udp` | 53 | — | — |
| DoT | `tls` | 853 | — | да |
| DoH | `https` | 443 | да | да |
| **DoQ** | `quic` | 853 | — | да |
| **DoH3** | `h3` | 443 | да | да |
| Group | `group` | — | — | — |

Селектор типов на телефоне теперь всегда выпадающий список: шесть сегментов в
строку не помещаются.

## ⚙️ WARP: `vhttp: auto` переживает круг ([docs/spec/tasks/402](docs/spec/tasks/402-direction-chain-label-removed.md))

Ядро понимает `auto` (h3 с откатом на h2) с lx.27, мастер WARP его уже
предлагал, но оба парсера знали только пару `{h3, h2}` и молча форсили `h3`.
Узел, созданный мастером, работал, а тот же узел, экспортированный в ссылку и
заимпортированный обратно, `auto` терял.

## 🛡 Защиты: один негодный узел больше не останавливает VPN

### `header`-размещение uplink без режима ([docs/spec/tasks/416](docs/spec/tasks/416-xhttp-packet-up-guard.md))

Узел с `uplink_data_placement: header`, но без указанного режима, ядро отвергало
**вместе со всем конфигом**: такое размещение оно принимает только в режиме
`packet-up`. Сервис не стартовал вовсе, причём из-за узла, который пользователь
мог и не выбирать.

| Узел в источнике | Что происходит теперь | Предупреждение |
|---|---|---|
| `header`, режим пуст | режим дописывается как `packet-up`, размещение сохраняется | да |
| `header`, режим `packet-up` | ничего не меняется | нет |
| `header`, режим иной | размещение снимается, режим не трогается | да |
| любое другое размещение | passthrough как раньше | нет |

Там, где режима в источнике нет, нет и намерения, которое надо уважать, — узел
собирается так, как его ждёт сервер. Там, где режим задан явно и конфликтует,
разбирать конфликт за пользователя нельзя: снимается размещение, режим остаётся
нетронутым. В обоих случаях на узле появляется предупреждение.

### Пустое значение в `extra` не перекрывает плоский параметр ([docs/spec/tasks/410](docs/spec/tasks/410-xhttp-extra-empty-not-clobber.md))

Регрессия v2.21.0: `Failed to start service … uplink_data_placement can be
header only in packet-up mode`, если в подписке есть хоть один XHTTP-узел, у
которого Xray-ссылка несёт `mode=packet-up` плоским параметром и `"mode": ""`
внутри `extra`. Пустая строка из `extra` затирала плоское значение, ядро брало
режим `auto` и отвергало весь конфиг. Теперь пустое значение в `extra` плоский
параметр не перекрывает (как в Go-эталоне лаунчера); непустое по-прежнему в
приоритете.

Заодно `host`, `path` и `mode` теперь читаются только из плоских параметров
ссылки, как делает Xray при слиянии `extra`: у того же узла в `extra` лежал
`path: "/"`, и сервер отвечал 404, а рабочий путь был плоским.

**Полный реестр таких защит теперь записан** — [docs/GUARDS.md](docs/GUARDS.md)
перечисляет каждое место, где L×Box отбрасывает, нормализует, подставляет
умолчание или деградирует значение, чтобы ядро не упало, со ссылкой
`файл:строка` на каждую строку.

## 🧰 Починено

- **Ложная ошибка «Stop timed out» при успешной остановке**
  ([docs/spec/tasks/415](docs/spec/tasks/415-stop-timeout-budget.md)) —
  остановка тяжёлого туннеля (WARP/AWG с десятками живых соединений) занимает
  около пяти секунд, а внутренний бюджет ожидания был пять: истекал за мгновение
  до того, как остановка успешно завершалась. Туннель гасился штатно, но
  пользователь видел красную ошибку, и поверх уже идущей остановки прилетал
  аварийный force-stop. Бюджеты выстроены по возрастанию: ожидание ядра (9 с) <
  вызов из UI (10 с) < аварийное добивание (12 с) — каждый следующий уровень
  даёт предыдущему договорить. При настоящем зависании ядра ошибка по-прежнему
  показывается, а сервис по-прежнему добивается принудительно.

- **Конфиг пересобирался на каждом запуске**
  ([docs/spec/tasks/414](docs/spec/tasks/414-config-dirty-check-files-dir.md)) —
  проверка «настройки новее конфига» искала `singbox_config.json` в каталоге
  Flutter (`app_flutter/`), а native пишет его в `files/`. Файл не находился
  никогда, поэтому на каждом холодном старте конфиг считался устаревшим и
  собирался заново. Теперь путь к конфигу берётся у native, сравнение времени
  файлов работает как задумано, а пересборка идёт только когда настройки
  действительно менялись.

- **Настройки пинга удалённого Направления оставались в хранилище**
  ([docs/spec/tasks/408](docs/spec/tasks/408-ping-options-groups-heal.md)) —
  персональные URL и timeout Направления переживали его удаление: ключ висел
  сиротой, попадал в бэкап, а созданное следом Направление с тем же тегом
  (`vpn-3` освобождается и выдаётся снова) молча наследовало чужой адрес
  проверки. Теперь ключ снимается в той же транзакции, что и остальные ссылки —
  вместе с ключом авто-двойника `<tag>-auto`, — а уже накопленные сироты
  вычищаются при загрузке состава Направлений (в том числе после восстановления
  бэкапа). Выключение Направления override по-прежнему не трогает: оно
  обратимо.

- **Пикер приложений: галочка переключается только тапом по ней**
  ([docs/spec/tasks/412](docs/spec/tasks/412-app-picker-checkbox-only-tap.md)) —
  раньше выбор переключал тап по всей строке, и при прокрутке длинного списка
  палец задевал строку, а приложение выпадало из выбора незаметно. Теперь
  реагирует только сам чекбокс со штатной областью касания.

## 🧬 Ядро: `1.14.0-lx.30`

Было `v1.14.0-lx.28-rc.1`.

- **Починен DNS через `detour` на XHTTP-узел.** Серверы типа `udp`/`tcp`/`tls`
  за таким detour'ом падали на первом же запросе с `write request: context
  canceled`. Это выглядело как красные URL-тесты `masque`- и
  `wireguard`-узлов, если проверять их по доменному адресу (по IP тот же узел
  зелёный), и как мёртвый системный DNS через TUN при живом туннеле.
- **XHTTP больше не держит процессор на 100%**, когда путь рубит
  upload-стримы, — circuit breaker в xmux-пуле выводит соединение из оборота
  после серии сорванных стримов вместо повторов в плотном цикле.
- Выгрузка `packet-up` переживает graceful `GOAWAY`, закрыта утечка пула в
  `stream-up`.

Java-поверхность ядра изменилась только дополнениями (RPC цепочек, клиент их не
биндит) — правок обвязки не потребовалось.

## 🧪 Тесты

`flutter analyze`, полный набор тестов и все шесть чекеров. Общий контрактный
корпус зелёный с обеих сторон на 0.12.8.

</details>

---

## Install / Установка

```bash
adb install -r LxBox-v2.22.0-arm64-v8a.apk
```

Без uninstall! Поверх существующей установки. Настройки и подписки сохранятся.

No uninstall needed — install over the existing one. Settings and
subscriptions are preserved.

---

Previous release / Предыдущий релиз: [v2.21.0](docs/releases/v2.21.0.md).
