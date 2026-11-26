# L×Box v2.26.0

**A stable release on top of [v2.25.22](https://github.com/Leadaxe/LxBox/releases/tag/v2.25.22).** It includes everything from the v2.25.23 release candidates, which never became stable.

**Load balancing repairs itself**: when a connection fails, a `round_robin`
pool retries through another slot and replaces a dead node at once instead of
waiting for the next check, and View pool shows what the pool did. **Hop chains follow the new core**: a node past
the first position goes through the chain by its own `detour`, without
copies; a chain where a node or Direction would need two paths is not built,
and the chain editor and a banner on the home screen say which copy to make.
**The JSON tab of a node shows it as the core runs it**, with the core's
changes. Core `v1.14.4-lx.37`, contract 1.1.184. Also in this release: rules
built from conditions, the app split into two processes, AI assistant
functions, Block HTTPS/SVCB records and TrustTunnel subscriptions.

**Стабильный релиз поверх [v2.25.22](https://github.com/Leadaxe/LxBox/releases/tag/v2.25.22).** В него вошло всё из релиз-кандидатов v2.25.23, которые стабильными не стали.

**Балансировка чинит себя сама**: при сбое соединения пул `round_robin`
повторяет попытку через другой слот и сразу меняет мёртвый узел, не дожидаясь
следующей проверки, а View pool показывает, что пул сделал. **Цепочки под новое ядро**: узел после первой позиции идёт через
цепочку по собственному `detour`, без копий; цепочка, где узлу или
Направлению нужны два пути, не собирается, а редактор цепочки и плашка на
главном подсказывают, какую копию сделать. **Вкладка JSON узла показывает
его таким, каким его держит ядро**, с изменениями ядра. Ядро
`v1.14.4-lx.37`, контракт 1.1.184. Ещё в релизе: правила из условий,
приложение в двух процессах, функции ИИ-ассистента, Block HTTPS/SVCB records
и подписки TrustTunnel.

---

<details open>
<summary><h2>🇬🇧 English</h2></summary>

## ⚠️ Changed

- **Hop chains: one path per node.**
  The core no longer makes copies of chain nodes: a node past the first
  position gets a `detour` to the position before it and goes that way
  everywhere. A node or Direction can therefore have one path only. A chain
  is not built when it has a ring — a node at the entry that is also inside a
  Direction further down the chain, or a detour that leads back into the
  chain — or a conflict — a node or Direction past the first position that is
  used again at another such position or in another chain. A shared entry of
  two chains is not a conflict. A typical old chain `[node, Direction with all
  nodes]` is such a ring. The build drops a chain like this, and the home
  screen shows a «Hop chain "…" is not built» banner with the hint of which
  copy to make and an **Open chain** button; **Dismiss** hides it until the
  config changes. The chain editor does not save such a chain and names the
  copy too; both chains of a conflict are named by tag. A node past the first
  position with a fixed local port (WireGuard/AmneziaWG `listen_port`,
  Tailscale `listen_port`/`relay_server_port`, OpenConnect `dtls_local_port`)
  also drops the chain; the port is not removed. The chain keys
  `idle_timeout`, `strip` and `strip_evasion` are no longer supported: a saved
  chain or a backup is read without them, and the editor has no Advanced
  block. The core's internal `chain-hop` outbounds are hidden from lists
  ([details](docs/spec/tasks/761-core-rc2-chain-detour.md)).
- **A route rule is built from conditions; the backup format changes.**
  A custom rule is a stack of conditions joined by AND; values inside one
  condition are «any of». **+ Condition** opens a menu of conditions; its
  **Rule group** item adds a group with «all of / any of» and **Not**, whose
  nested rules open in the same editor at any depth. Rule sets by URL are the
  **Destination / Rule sets** field of a condition stack: the Inline / Remote
  switch is gone, the mode is **Conditions / Raw JSON**. The rule screen has
  the tabs **Params | DNS | View**; the DNS & Resolve block moved to the DNS
  tab unchanged. The network type segment became the **Network type**
  condition. A rule without conditions is not saved. OR, NOT and a rule set
  next to the rule's own domains, which used to need hand-written JSON and lost
  the DNS options, are now built in the form.
  Rule-set tags in the config follow the norm shared with the launcher;
  downloaded rule-set files are renamed, not downloaded again. A backup is now
  written as format 3: L×Box before 2.26.0 refuses such a file as a whole
  ([details](docs/spec/tasks/757-rule-conditions-tree.md)).
- **DNS options of a rule work with port and protocol filters.**
  Dedicated server, Fixed IP, Force IPv4 and Block HTTPS were greyed out once
  a rule had a port, protocol or network filter. They now apply to the rule's
  domains on any port and protocol; a custom rule's ports moved from its
  rule-set to the routing rule, the match is the same. A Force IPv4 box or a
  DNS option that was set on such a rule and silently did nothing now takes
  effect ([details](docs/spec/tasks/755-block-https-svcb-records.md)).

## ✨ New

- **Load balancing repairs itself, and View pool shows it.**
  A `round_robin` pool reacts to a failed connection instead of waiting for
  the next check: a retry through another slot, a dead node replaced from a
  reserve of live nodes, a site that one node cannot open moved to another, a
  node that fails more than the rest set aside until the next check. View pool
  and the pool section of the group screen show it: `quarantine` on a node
  taken out of rotation, the slot's connections and confirmed failures, and
  above the slots — the number of sticky keys moved to another slot, the
  number of addresses marked as the problem, and a freeze with the seconds
  left. A healthy pool looks as before. The traffic profiler records the node
  a connection actually went through
  ([details](docs/spec/tasks/759-pool-self-heal-state.md)).
- **The JSON tab of a node shows the node from the core.**
  The tab shows the node as the running core holds it (Effective), with an
  Effective / Original switch when the core changed it, and the list of
  changes as `field: from → to` with the reason: a chain and its position, the
  node type or a mode. With the tunnel down, or a tag the core does not know,
  the tab says «No data from the core» and does not substitute the app's
  config. The Copy buttons still copy the node from the app's config.
- **Block HTTPS/SVCB records: domain rules see sites behind ECH ([#227](https://github.com/Leadaxe/LxBox/issues/227)).**
  Without FakeIP, Chrome took the ECH key from the site's HTTPS DNS record and
  hid the real name behind a shared one such as `cloudflare-ech.com`; a rule
  like `rutracker.org → vpn-1` then never matched, and the traffic left by the
  default route. The DNS tab of a rule has **Block HTTPS/SVCB records**: HTTPS
  and SVCB queries for the rule's domains get an empty answer, the browser
  sends the name in the clear, and the rule matches. The box ticks itself when
  domains are filled in; it is unavailable without a domain condition; saved
  rules are not changed. A preset of the same name (Routing → Rules → +) does
  it for every site and is off by default. Apps with their own
  DNS-over-HTTPS (a fixed Secure DNS provider in Chrome, DoH in Firefox) are
  not affected.
- **An AI assistant can diagnose and manage the network.**
  On Android 16+ the functions for system assistants grow from three to ten:
  an address check by stages, the external IP and country of a Direction's
  exit, the list of a Direction's exits and switching between them, an app
  search, and a gateway to a part of the Debug API — rules, Directions,
  sources and connections. Reading and checks sit behind «AI assistant
  control»; changing settings needs the separate «Let assistants change
  settings» switch (App Settings → Automation → AI assistants), off by
  default. Config, keys, subscription links, backups and logs stay closed.
  The Debug API gets `/assistant/*` routes for an agent on a computer. Guide:
  [AI assistants and your network](docs/AI_ASSISTANT.md).
- **TrustTunnel subscriptions and Copy link.**
  The address a TrustTunnel server gives out as a subscription
  (`https://user:password@host/path`) is added as any subscription URL; the
  server's answer becomes a `trusttunnel` node. The login and password from
  the address go to the server as HTTP Basic — for any subscription URL with
  credentials in it; a password with special characters arrives intact and no
  longer appears in a download error. A `tt://` link that carries only a
  subscription address is added as that subscription when pasted, scanned or
  typed in. A `trusttunnel` node from an `endpoints[]` entry of a sing-box
  config gives a `tt://` link on Copy link instead of the JSON text
  ([details](docs/spec/tasks/717-trusttunnel-deeplink-uri.md)).
- **Three new WireGuard / AmneziaWG settings.**
  VPN Settings → Core → WireGuard gets **Datagrams per read** (8 by default,
  about 1 MiB per tunnel; the core's own default of 128 costs about 16 MiB,
  and 1–2 suit dozens of nodes), **MTU-sized send buffers** (a diagnostic
  switch, on) and **Connected tunnel socket** (more upload for a tunnel with
  one server, off: not tested on a phone that switches between Wi-Fi and
  mobile data). They apply to tunnels without a detour.

## 🔄 Other changes

- **Core `v1.14.4-lx.37`.**
  Besides the pool repair above: WireGuard and AmneziaWG tunnels without a
  detour are faster, and a queued packet holds about 2 KiB instead of 64 KiB.
  DNS over a proxied stream no longer loses queries in bursts; an HTTP proxy
  that never answers no longer piles up connections; a `tls.fragment` hang is
  fixed; `least_test` and `failover` leave a node whose server refuses
  connections; SOCKS and ShadowTLS handshakes are limited to 15 s; a manual
  group test clears the latency of nodes that did not answer. The core moved
  the tunnel sleep keys into `lx.wg.idle` and the MTU alignment setting into
  `lx.detour.mtu_align`; the app writes the new names, and a mixin with an old
  name is rewritten when it is read.
- **Two processes: the tunnel and the window.**
  The VPN service with the core runs in its own process, the window with the
  interface in another. Closing the window (swiping the app away) ends its
  process: with the VPN on, memory drops from about 240 MB to about 110 MB on
  the emulator; with the VPN off and the window closed the app leaves nothing
  in memory. With the VPN off and the window open the core is unloaded too.
  While the VPN is on and the window is only minimised, subscription updates,
  automation and the Debug API work as before. Opening the app after the
  window was closed is a cold start, about 1.5 s on the emulator. The tile,
  auto-start, automation and the assistant bring the tunnel process up by
  themselves. Checked on Android 14 and 16 emulators, not on phones. One
  unexplained case in about a hundred attempts: a start issued a few seconds
  after a stop under heavy load did not bring the tunnel up; it was not
  reproduced, and the start path now writes a trace into the log
  ([details](docs/spec/tasks/747-two-processes-ui-bg.md)).
- **TrustTunnel `tt://` links are read by the registry ([#194](https://github.com/Leadaxe/LxBox/issues/194)).**
  The certificate name (`tls.server_name`) is always the host name of the
  link: a custom SNI is reported and not applied, because the core has one
  name for both and the certificate is issued for the host name. A
  certificate chain arrives as one PEM block per certificate. The TLS profile
  of the link turns on uTLS (Chrome, Safari, Firefox, Android), except with
  HTTP/3. A link with a subscription address that is not `https://` is
  rejected.
- **WARP: the generator no longer writes `reserved`.**
  The WARP node generator put the registration's `client_id` into the peer as
  `reserved`; from Russian networks DPI recognises WARP by it and cuts an
  AmneziaWG tunnel after about 20 packets. The node is now built without
  `reserved`, the **Bind to this device (reserved)** option is removed from
  the WARP wizard, and the Debug API `POST /warp` no longer takes
  `includeReserved`. A node you already have keeps its `reserved` until it is
  recreated; imported links with `reserved` are read as before.
- **Comments in a server's JSON are kept ([#171](https://github.com/Leadaxe/LxBox/issues/171)).**
  A server pasted or edited as JSON keeps its `//`, `/* */` and `#` comments:
  the Source tab shows the text as typed after pasting, saving and restoring a
  backup, and the «Comments were removed.» message is gone. The same server
  with and without comments is still one server in a backup. Comments are
  still lost where the app rewrites the text itself: a pasted whole config
  (only its nodes are kept), the Format button, Edit JSON and the masquerade
  section.
- **A folder's server with an unavailable detour is marked in the list.**
  Inside a folder, the server whose detour was removed at build shows the
  ⚠ «Hop … unavailable: hop removed» line on its own row, not only on the
  folder and the server's card. A tap shows what happened; the line goes away
  after the next build once the target is back.

## 🩹 Fixed

- **The VPN notification comes back after it is swiped away.**
  On Android 14 and later the notification of a running VPN can be swiped
  away or cleared with the rest of the shade (HyperOS does it on «clear
  all»). The tunnel kept working, but the notification stayed gone until the
  next connect or node change. It now returns at once while the VPN is on;
  after Stop it does not come back.
- **The server test of a subscription no longer stalls with TLS Fragment on.**
  With fragmentation the core did not apply the test timeout to a server that
  accepts the connection and then stays silent. Ten such servers took all
  test slots, and the counter stopped. The app now stops waiting 3 s after
  the test timeout and marks the server as failed.
- **An imported backup shows up at once and is no longer lost.**
  After Settings → Backup → Transfer to desktop → Import, the imported
  servers did not appear until the app was restarted, and any change in the
  server list before a restart wrote the old list back. The same happened
  after a regular restore without «Restart now» and after `POST
  /backup/import` in the Debug API. The app now reloads its state right after
  the import and returns to the main screen. The running VPN is not stopped;
  the config is rebuilt like after any settings change.
- **The Detour server window offers replace groups.**
  A subscription or folder replaced with a group could not be picked as a
  detour for another server; the window now has a Replace groups section with
  such groups in every mode.
- **The path preview no longer shows a detour that was removed.**
  Under **Detour server**, the «Phone → … → Internet» line kept drawing the
  path through the chosen detour even when the last build had removed it.
  The path is now struck through, and a ⚠ line under it says the server goes
  directly; the same for the detour of a subscription or folder. The chosen
  detour is kept, and the line returns to normal after the next build once
  the target is back.
- **The «Errors (N)» row no longer hides under the navigation bar.**
  With three-button navigation the red row on the main screen was drawn under
  the system buttons, and a tap hit the system button. The row now sits above
  the bar.
- **Assistant address and exit checks while the core is not up.**
  They answer «The VPN core is not reachable yet» instead of a raw RPC error.
- **Format and highlighting for a server JSON that starts with a comment.**
  A JSON server whose first line is a comment had no syntax highlighting and
  no Format item in the ⋮ menu. Leading comments are now skipped when the
  editor detects the language; WireGuard `.conf` files with `#` comments are
  still shown as INI.
- **The TV remote leaves text fields.**
  On Android TV the remote got stuck in any text field of a form: up and down
  only moved the cursor. Now up and down leave a one-line field; in a
  multi-line field they leave from its first or last line. Left and right
  move the cursor and leave the field at the start or end of the text. While
  the on-screen keyboard is open it keeps the arrows for itself.
- **The TV remote no longer gets stuck in option lists ([#222](https://github.com/Leadaxe/LxBox/issues/222)).**
  In lists of round options — theme and language in App Settings →
  Appearance, background mode, detour mode, rule type and others — the arrow
  keys picked the next option at once and looped inside the list. Arrows now
  only move the focus and leave the list at its first and last option; OK,
  Enter, Space or a tap picks an option. Switching a tab with the mouse or by
  touch takes the focus off the hidden tab.
- **Dependent settings no longer look enabled when they are not in effect ([#171](https://github.com/Leadaxe/LxBox/issues/171)).**
  In VPN Settings → Core → WireGuard, with «Suspend idle tunnels» off, the
  greyed «Lazy tunnel build» and «Built tunnels limit» rows kept showing «on»
  and «12». A greyed row now shows a switch as off and a list as «Not in
  effect»; the saved value returns when the row becomes active again.

## 🔧 Under the hood

- **Debug API controls the core's `impair` test outbound.**
  `GET /impair/{tag}`, `POST /impair/{tag}/set` and `POST
  /impair/{tag}/schedule` read and change the line of an `impair` outbound in
  the running core, for scripted balancing and failure tests. The app has no
  UI for `impair`. An `impair` node keeps its tag as written and shows
  `☠ impair` as its protocol. `POST /subs` returns the final config tags;
  `PATCH /nodes/{tag}` sets or clears a node's detour
  ([details](docs/spec/tasks/762-debug-api-impair.md)).
- **The boundary between the VPN service and the UI is drawn in the code.**
  One owner of the tunnel state, separate core command clients for the
  service and for the UI; CI checks the architecture boundaries on every
  push.
- **Shared contract 1.1.184** (was 1.1.171): chains without the dropped keys,
  rule conditions as a tree, TrustTunnel links and subscriptions, Block
  HTTPS/SVCB records, comments in a JSON node source.
- **Core `v1.14.4-lx.37`** (was `v1.14.4-lx.35`).

</details>

<details open>
<summary><h2>🇷🇺 Русский</h2></summary>

## ⚠️ Изменено

- **Цепочки: у узла один путь.**
  Ядро больше не копирует узлы цепочки: узел после первой позиции получает
  `detour` на предыдущую позицию и везде ходит этим путём. Поэтому у узла или
  Направления может быть только один путь. Цепочка не собирается, если в ней
  кольцо — узел на входе стоит и внутри Направления дальше в цепочке, или
  detour ведёт обратно в цепочку, — или конфликт — узел или Направление после
  первой позиции встречается ещё на такой же позиции или в другой цепочке.
  Общий вход двух цепочек конфликтом не считается. Старая цепочка вида
  `[узел, Направление со всеми узлами]` — как раз такое кольцо. Сборка такую
  цепочку снимает, а на главном появляется плашка «Hop chain "…" is not
  built» с подсказкой, какую копию сделать, и кнопкой **Open chain**;
  **Dismiss** скрывает её до следующего изменения конфига. Редактор цепочки
  такую цепочку не сохраняет и тоже называет копию; обе цепочки конфликта
  названы по тегу. Узел после первой позиции с фиксированным локальным портом
  (`listen_port` WireGuard/AmneziaWG, `listen_port`/`relay_server_port`
  Tailscale, `dtls_local_port` OpenConnect) тоже снимает цепочку; порт не
  убирается. Ключи цепочки `idle_timeout`, `strip` и `strip_evasion` больше
  не поддерживаются: сохранённая цепочка и бэкап читаются без них, блока
  Advanced в редакторе нет. Служебные outbound `chain-hop` ядра в списках
  скрыты ([подробнее](docs/spec/tasks/761-core-rc2-chain-detour.md)).
- **Правило маршрута собирается из условий; меняется формат бэкапа.**
  Своё правило — стопка условий через И; значения внутри одного условия —
  «any of». **+ Condition** открывает меню условий; пункт **Rule group**
  добавляет группу с «all of / any of» и **Not**, вложенные правила группы
  открываются тем же редактором на любую глубину. Наборы по ссылке — поле **Destination / Rule
  sets** у стопки условий: переключателя Inline / Remote больше нет, режим —
  **Conditions / Raw JSON**. У экрана правила вкладки **Params | DNS |
  View**; блок DNS & Resolve переехал на вкладку DNS без изменений. Сегмент
  типа сети стал условием **Network type**. Правило без условий не
  сохраняется. ИЛИ, НЕ и набор рядом со своими доменами правила, которые
  раньше требовали ручного JSON и теряли DNS-опции, теперь собираются в форме. Теги наборов в конфиге — по общей с лаунчером норме;
  скачанные файлы наборов переименовываются, а не качаются заново. Бэкап
  теперь пишется в формате 3: L×Box до 2.26.0 такой файл отвергает целиком
  ([подробнее](docs/spec/tasks/757-rule-conditions-tree.md)).
- **DNS-опции правила работают с фильтрами по портам и протоколам.**
  Dedicated server, Fixed IP, Force IPv4 и Block HTTPS были серыми, как
  только у правила появлялся фильтр по порту, протоколу или сети. Теперь они
  действуют на домены правила на любом порту и протоколе; порты своего
  правила переехали из его набора в маршрутное правило, совпадение то же.
  Отмеченная у такого правила Force IPv4 или другая DNS-опция, которая
  раньше молча не действовала, теперь действует
  ([подробнее](docs/spec/tasks/755-block-https-svcb-records.md)).

## ✨ Новое

- **Балансировка чинит себя сама, View pool это показывает.**
  Пул `round_robin` отвечает на сбой соединения, не дожидаясь следующей
  проверки: повтор через другой слот, замена мёртвого узла из резерва живых,
  сайт, который не открывается через один узел, уходит на другой, узел,
  который сбоит чаще остальных, отложен до следующей проверки. View pool и
  секция пула на экране группы это показывают: `quarantine` у узла,
  выведенного из ротации, соединения и подтверждённые сбои слота, а над
  слотами — число sticky-ключей, переехавших в другой слот, число адресов,
  признанных проблемой, и заморозку с остатком секунд. Здоровый пул выглядит
  как раньше. Профайлер трафика записывает узел, через который соединение
  действительно пошло
  ([подробнее](docs/spec/tasks/759-pool-self-heal-state.md)).
- **Вкладка JSON узла показывает узел от ядра.**
  Вкладка показывает узел таким, каким его держит работающее ядро
  (Effective); если ядро его изменило — переключатель Effective / Original и
  список изменений `поле: было → стало` с причиной: цепочка и позиция, тип
  узла или режим. Туннель не поднят или тег ядру неизвестен — вкладка пишет
  «No data from the core» и свой конфиг не подставляет. Кнопки Copy
  по-прежнему копируют узел из конфига приложения.
- **Block HTTPS/SVCB records: правила по домену видят сайты за ECH ([#227](https://github.com/Leadaxe/LxBox/issues/227)).**
  Без FakeIP Chrome брал ключ ECH из HTTPS-записи DNS сайта и прятал
  настоящее имя за общим, например `cloudflare-ech.com`; правило вида
  `rutracker.org → vpn-1` не срабатывало, и трафик уходил по маршруту по
  умолчанию. На вкладке DNS правила есть **Block HTTPS/SVCB records**:
  HTTPS- и SVCB-запросы доменов правила получают пустой ответ, браузер шлёт
  имя открыто, и правило срабатывает. Галочка ставится сама при заполнении
  доменов, без условия по домену недоступна, сохранённые правила не
  меняются. Одноимённый пресет (Routing → Rules → +) делает то же для всех
  сайтов и по умолчанию выключен. Приложения со своим DNS-over-HTTPS
  (фиксированный провайдер Secure DNS в Chrome, DoH в Firefox) это не
  затрагивает.
- **ИИ-ассистент может диагностировать сеть и управлять ей.**
  На Android 16+ функций для системных ассистентов десять вместо трёх:
  проверка адреса по стадиям, внешний IP и страна выхода Направления, список
  выходов Направления и их смена, поиск приложения и шлюз к части Debug API —
  правила, Направления, источники, подключения. Чтение и проверки — под
  «AI assistant control»; изменение настроек — под отдельным тумблером «Let
  assistants change settings» (App Settings → Automation → AI assistants),
  по умолчанию выключенным. Конфиг, ключи, ссылки подписок, бэкапы и логи
  закрыты. В Debug API — маршруты `/assistant/*` для агента на компьютере.
  Гайд: [ИИ-ассистент и ваша сеть](docs/AI_ASSISTANT.ru.md).
- **Подписки TrustTunnel и Copy link.**
  Адрес, который сервер TrustTunnel выдаёт как подписку
  (`https://user:password@host/path`), добавляется как любой URL подписки;
  ответ сервера становится узлом `trusttunnel`. Логин и пароль из адреса
  уходят серверу как HTTP Basic — у любого URL подписки с учётными данными;
  пароль со спецсимволами доходит без искажений и больше не попадает в текст
  ошибки загрузки. Ссылка `tt://`, несущая только адрес подписки, при
  вставке, сканировании или вводе добавляет эту подписку. Узел `trusttunnel`
  из записи `endpoints[]` конфига sing-box на Copy link отдаёт ссылку `tt://`
  вместо текста JSON
  ([подробнее](docs/spec/tasks/717-trusttunnel-deeplink-uri.md)).
- **Три новые настройки WireGuard / AmneziaWG.**
  В VPN Settings → Core → WireGuard: **Datagrams per read** (по умолчанию 8 —
  около 1 МБ на туннель; умолчание самого ядра 128 стоит около 16 МБ, 1–2 —
  для десятков узлов), **MTU-sized send buffers** (диагностический, включён)
  и **Connected tunnel socket** (быстрее отдача у туннеля с одним сервером;
  выключен — на телефоне со сменой Wi-Fi и мобильной сети не проверен).
  Действуют на туннели без detour.

## 🔄 Другие изменения

- **Ядро `v1.14.4-lx.37`.**
  Помимо самовосстановления пула: туннели WireGuard и AmneziaWG без detour
  быстрее, пакет в очереди держит около 2 КБ вместо 64 КБ. DNS через
  проксированный поток не теряет запросы пачками; молчащий HTTP-прокси не
  копит соединения; зависание `tls.fragment` исправлено; `least_test` и
  `failover` уходят с узла, сервер которого отказывает в соединении;
  рукопожатия SOCKS и ShadowTLS ограничены 15 с; ручной тест группы
  сбрасывает задержку не ответивших узлов. Ключи сна туннелей ядро перенесло
  в `lx.wg.idle`, выравнивание MTU — в `lx.detour.mtu_align`; приложение
  пишет новые имена, миксин со старым именем переписывается при чтении.
- **Два процесса: туннель и окно.**
  Сервис VPN с ядром работает в своём процессе, окно с интерфейсом — в
  другом. Закрытие окна (смахнуть приложение) завершает его процесс: при
  включённом VPN память падает примерно с 240 до 110 МБ на эмуляторе; при
  выключенном VPN и закрытом окне приложение ничего не оставляет в памяти.
  При выключенном VPN и открытом окне ядро тоже выгружено. Пока VPN включён,
  а окно только свёрнуто, обновление подписок, автоматизация и Debug API
  работают как раньше. Открытие приложения после закрытия окна — холодный
  старт, около 1,5 с на эмуляторе. Плитка, автозапуск, автоматизация и
  ассистент поднимают процесс туннеля сами. Проверено на эмуляторах Android
  14 и 16, на телефонах нет. Один необъяснённый случай примерно на сто
  попыток: старт через несколько секунд после остановки под большой нагрузкой
  не поднял туннель; воспроизвести не удалось, путь старта теперь пишет след
  в лог ([подробнее](docs/spec/tasks/747-two-processes-ui-bg.md)).
- **Ссылки `tt://` TrustTunnel читаются по реестру ([#194](https://github.com/Leadaxe/LxBox/issues/194)).**
  Имя сертификата (`tls.server_name`) — всегда имя хоста из ссылки: свой SNI
  называется в предупреждении и не применяется, потому что у ядра имя одно на
  оба смысла, а сертификат выписан на имя хоста. Цепочка сертификатов
  приезжает блоком PEM на каждый сертификат. TLS-профиль ссылки включает uTLS
  (Chrome, Safari, Firefox, Android), кроме HTTP/3. Ссылка с адресом
  подписки не `https://` отвергается.
- **WARP: генератор больше не пишет `reserved`.**
  Генератор узла WARP клал `client_id` регистрации в peer как `reserved`; из
  российских сетей DPI узнаёт по нему WARP и рвёт туннель AmneziaWG примерно
  после 20 пакетов. Узел теперь строится без `reserved`, опция **Bind to
  this device (reserved)** убрана из мастера WARP, Debug API `POST /warp`
  больше не принимает `includeReserved`. Уже созданный узел сохраняет
  `reserved` до пересоздания; импортируемые ссылки с `reserved` читаются как
  раньше.
- **Комментарии в JSON сервера сохраняются ([#171](https://github.com/Leadaxe/LxBox/issues/171)).**
  Сервер, вставленный или отредактированный как JSON, сохраняет комментарии
  `//`, `/* */` и `#`: вкладка Source показывает текст как набран — после
  вставки, сохранения и восстановления из бэкапа; сообщение «Comments were
  removed.» убрано. Один и тот же сервер с комментариями и без — по-прежнему
  один сервер в бэкапе. Комментарии всё ещё теряются там, где приложение само
  переписывает текст: вставленный целый конфиг (из него берутся только узлы),
  кнопка Format, Edit JSON и секция маскировки.
- **В папке сервер с недоступным detour отмечен в списке.**
  В списке серверов папки строка ⚠ «Hop … unavailable: hop removed» стоит у
  того сервера, у которого detour снят при сборке, а не только у папки и на
  карточке сервера. По нажатию — что случилось; строка пропадает после
  следующей сборки, когда цель снова доступна.

## 🩹 Исправлено

- **Уведомление VPN возвращается, если его смахнуть.**
  На Android 14 и новее уведомление работающего VPN можно смахнуть или
  убрать очисткой шторки (HyperOS убирает его кнопкой «очистить всё»).
  Туннель продолжал работать, а уведомление не появлялось до переподключения
  или смены узла. Теперь оно сразу возвращается, пока VPN включён; после Stop
  не появляется.
- **Тест серверов подписки больше не встаёт при включённом TLS Fragment.**
  С фрагментацией ядро не применяло таймаут замера к серверу, который принял
  соединение и молчит. Десять таких серверов занимали все слоты теста, и
  счётчик вставал. Теперь приложение перестаёт ждать через 3 с после таймаута
  замера и отмечает сервер недоступным.
- **Импортированный бэкап виден сразу и больше не теряется.**
  После Settings → Backup → Transfer to desktop → Import импортированные
  серверы не появлялись до перезапуска, а любая правка списка серверов до
  перезапуска записывала старый список. То же случалось после обычного
  восстановления без «Restart now» и после `POST /backup/import` в Debug API.
  Теперь приложение сразу перечитывает состояние после импорта и
  возвращается на главный экран. Работающий VPN не останавливается; конфиг
  пересобирается, как после любой смены настроек.
- **Окно Detour server предлагает группы свёртки.**
  Подписку или папку, свёрнутую в группу, нельзя было выбрать как detour для
  другого сервера; в окне появился раздел Replace groups с такими группами во
  всех режимах.
- **Превью пути больше не показывает снятый detour.**
  Под **Detour server** строка «Phone → … → Internet» рисовала путь через
  выбранный detour, даже когда последняя сборка его сняла. Теперь путь
  перечёркнут, а строка с ⚠ под ним говорит, что сервер идёт напрямую; так же
  — detour подписки и папки. Выбранный detour сохраняется, после следующей
  сборки с доступной целью строка возвращается к обычному виду.
- **Строка «Errors (N)» больше не уходит под панель навигации.**
  При трёхкнопочной навигации красная строка на главном рисовалась под
  системными кнопками, и нажатие попадало в системную кнопку. Теперь строка
  над панелью.
- **Проверки адреса и выхода у ассистента, пока ядро не поднято.**
  Отвечают «The VPN core is not reachable yet», а не сырой ошибкой RPC.
- **Format и подсветка у JSON сервера, начинающегося с комментария.**
  У JSON-сервера с комментарием в первой строке не было подсветки и пункта
  Format в меню ⋮. Теперь редактор пропускает ведущие комментарии, когда
  определяет язык; WireGuard `.conf` с `#`-комментариями по-прежнему
  показывается как INI.
- **Пульт TV выходит из текстовых полей.**
  На Android TV пульт застревал в любом текстовом поле формы: вверх и вниз
  двигали только курсор. Теперь вверх и вниз выводят из однострочного поля;
  из многострочного — с первой или последней строки. Влево и вправо двигают
  курсор и выводят из поля в начале или в конце текста. Пока открыта
  экранная клавиатура, стрелки принадлежат ей.
- **Пульт TV не застревает в списках-переключателях ([#222](https://github.com/Leadaxe/LxBox/issues/222)).**
  В списках-переключателях — тема и язык в App Settings → Appearance,
  фоновый режим, режим detour, тип правила и другие — стрелки сразу выбирали
  соседний пункт и крутились по кругу. Теперь стрелки только двигают фокус и
  выводят из списка на первом и последнем пункте; выбор — OK, Enter, Space
  или касание. При переключении вкладки мышью или касанием фокус уходит со
  скрытой вкладки.
- **Зависимые настройки больше не выглядят включёнными, когда не действуют ([#171](https://github.com/Leadaxe/LxBox/issues/171)).**
  В VPN Settings → Core → WireGuard при выключенном «Suspend idle tunnels»
  серые строки «Lazy tunnel build» и «Built tunnels limit» показывали
  «включено» и «12». Теперь в серой строке переключатель рисуется
  выключенным, список — «Не действует»; сохранённое значение возвращается,
  когда строка снова активна.

## 🔧 Под капотом

- **Debug API управляет тестовым outbound ядра `impair`.**
  `GET /impair/{tag}`, `POST /impair/{tag}/set` и `POST
  /impair/{tag}/schedule` читают и меняют линию outbound `impair` в
  работающем ядре — для скриптовых тестов балансировки и сбоев. В интерфейсе
  `impair` нет. Узел `impair` сохраняет тег как передан, протокол в строке
  узла — `☠ impair`. `POST /subs` отдаёт итоговые теги конфига,
  `PATCH /nodes/{tag}` ставит и снимает detour узла
  ([подробнее](docs/spec/tasks/762-debug-api-impair.md)).
- **Граница между сервисом VPN и интерфейсом проведена в коде.**
  Один владелец состояния туннеля, отдельные командные клиенты ядра у
  сервиса и у интерфейса; CI проверяет архитектурные границы на каждом push.
- **Общий контракт 1.1.184** (был 1.1.171): цепочки без снятых ключей,
  условия правила деревом, ссылки и подписки TrustTunnel, Block HTTPS/SVCB
  records, комментарии в JSON-исходнике узла.
- **Ядро `v1.14.4-lx.37`** (было `v1.14.4-lx.35`).

</details>

---

## Install / Установка

```bash
adb install -r LxBox-v2.26.0-arm64-v8a.apk
```

Без uninstall! Поверх существующей установки. Настройки и подписки сохранятся.

No uninstall needed — install over the existing one. Settings and subscriptions
are preserved.

---

Previous release / Предыдущий релиз: [v2.25.22](docs/releases/v2.25.22.md).
