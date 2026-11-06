# L×Box v2.25.16

**A patch on top of [v2.25.15](https://github.com/Leadaxe/LxBox/releases/tag/v2.25.15).**

An Android TV can take its settings from a phone: the TV shows a QR code, the
phone scans it and sends a backup over the local network. OpenConnect gateways
(FortiGate and others) can be added from a form in **Add server**; when the
gateway asks for a code or a browser sign-in, the app shows a **Sign-in
required** notification. DNS settings are now a tab of the **Routing** screen.
The new **Tunnel ingress** preset rejects connections that peers open from the
other side of a WireGuard, AmneziaWG, OpenVPN or OpenConnect node, unless the
node allows them. **Send HWID** is now on by default, and TLS fragmentation
reaches REALITY nodes from every level: see "Read before updating". Also here:
the ⋮ menu and line wrap in the JSON editor, one connection card for Conns and
the profiler, the subscription `announce` text, "Auto-restart VPN on settings
change" that applies every change, fixes for Speed Test and for a start stuck
in "stopping". Core `v1.14.3-lx.21`, contract 1.1.132.

**Патч поверх [v2.25.15](https://github.com/Leadaxe/LxBox/releases/tag/v2.25.15).**

Android TV получает настройки с телефона: TV показывает QR-код, телефон
сканирует его и отправляет бэкап по локальной сети. Шлюзы OpenConnect
(FortiGate и другие) добавляются формой в **Add server**; когда шлюз просит
код или вход через браузер, приложение показывает уведомление **Sign-in
required**. Настройки DNS стали вкладкой экрана **Routing**. Новый пресет
**Tunnel ingress** отклоняет соединения, которые пиры открывают с той стороны
узла WireGuard, AmneziaWG, OpenVPN или OpenConnect, если узел их не
разрешает. **Send HWID** теперь включён по умолчанию, а фрагментация TLS
доходит до REALITY-узлов с любого уровня: см. «Прочтите до обновления».
Кроме того: меню ⋮ и перенос строк в редакторе JSON, одна карточка
соединения для Conns и профайлера, текст `announce` подписки,
«Auto-restart VPN on settings change» применяет каждое изменение,
исправлены Speed Test и старт, застревавший в «stopping». Ядро
`v1.14.3-lx.21`, контракт 1.1.132.

---

<details open>
<summary><h2>🇬🇧 English</h2></summary>

## ⚠️ Read before updating

- **DNS settings moved to the Routing screen ([task 655](docs/spec/tasks/655-dns-tab-in-routing.md)).**
  The **DNS Settings** item is gone from the side menu. The same settings are
  on the **DNS** tab of **Routing**, right after **Rules**: Directions ·
  Presets · Rules · DNS · Tunnel apps. The blocks, editors and dialogs are
  unchanged. The Routing menu item now reads "Directions, rules and DNS".
  **DNS settings** in the DNS health sheet and support links to the DNS screen
  open Routing on the DNS tab.
- **Incoming connections from client tunnels are rejected ([task 656](docs/spec/tasks/656-contract-1130-tunnel-ingress.md)).**
  Peers on the other side of a WireGuard, AmneziaWG, OpenVPN or OpenConnect
  node can open connections to the phone: to the phone itself, to the local
  network, or out to the internet through it. The new **Tunnel ingress**
  preset is on by default and closes them. On an existing install it is added
  once on update; a preset you removed does not come back. What a node lets
  in is set in its settings, in the **Incoming connections from this tunnel**
  block:
  - **Allow access to this device**;
  - **Expose local network** — peers reach private networks behind the
    phone;
  - **Allow as gateway** — peers send any traffic through the phone.

  All three are off by default. The preset has three settings: **Incoming
  from tunnels** (what happens to the rest: `reject` by default, `drop`, or an
  outbound), **Device and local network go to** (`direct-out` by default) and
  **Gateway traffic goes to** (`vpn-1` by default). DNS queries from a closed
  tunnel are rejected too. Tailscale nodes are not covered: tailnet peers are
  limited by Tailscale ACLs.
- **Send HWID is on by default ([task 658](docs/spec/tasks/658-send-hwid-on-by-default.md)).**
  Without `x-hwid` a Remnawave panel registers the device itself, without a
  name, and after an app update may count it as a new device against the
  limit. If you never touched **Send HWID**, the app starts sending it with the
  next subscription update; an explicit Off stays Off. A panel with a device
  limit sees the install once more, now with its name (`SM-S918B | Android`).
  Remove the old nameless device in the panel or the provider's bot.
- **TLS fragmentation reaches REALITY nodes from every level ([task 665](docs/spec/tasks/665-tls-fragment-inherits-everywhere-reality-too.md), issue #170).**
  Since 2.25.12 the global, folder and subscription settings skipped REALITY
  nodes. Now REALITY inherits fragmentation like any node, and a node that
  gets it from a level above says so under its TLS section. **If your REALITY
  server does not accept a split ClientHello, set fragmentation to Off on that
  node or its subscription.**

## ✨ New

- **Set up a TV from your phone ([task 622](docs/spec/tasks/622-device-transfer-phone-to-tv.md), issue #163).**
  On the TV: Backup & restore → Receive from phone → **Show code**. On the
  phone: Backup & restore → tick the categories → **Send to TV** → **Scan
  code**. The TV opens the usual **Import backup** window. The settings travel
  encrypted with a one-time key that only the QR code carries; a code lives
  10 minutes, works for one transfer and closes after five sends with a wrong
  key. The phone sends past its own VPN, so the transfer works with the tunnel
  up. Both devices must be on the same network; a guest Wi-Fi often keeps them
  apart. The receive item appears only on a TV, the send item only on a device
  with a camera. Not yet checked on real devices.
- **Source and inbound of connections from other inputs ([task 661](docs/spec/tasks/661-stats-source-inbound.md)).**
  With Tunnel ingress, `allow_lan` / `allow_gateway` on a node, or a local
  proxy (`mixed-in`, `sysproxy-in`), connections come not only from the TUN.
  Conns, Stats → Overview and the profiler feed add `<ip:port> / <inbound>` to
  such a connection, for example `(no owner) · 10.8.0.2:40112 / wg-in`. For
  `tun-in` nothing is added. The connection card has a **Source** group before
  Destination.
- **OpenConnect in Add server ([task 654](docs/spec/tasks/654-openconnect-fortinet-support.md)).**
  A new **OpenConnect** tab adds a corporate VPN gateway. The main block has
  **Tag**, **Gateway** (FortiGate, Cisco AnyConnect, GlobalProtect, F5,
  Pulse, Juniper; FortiGate by default), **Server** (`host:port` or a full URL,
  port 443 if omitted), **Username** and **Password**.
  - **Security**: server certificate check (System CA, Pinned fingerprint, or
    Do not verify), SNI, Group / Realm (hidden for FortiGate), Disable SSO.
  - **Advanced** (collapsed): TCP only (no DTLS), User-Agent, Hostcheck
    (FortiGate only), MTU, DPD interval, Reconnect timeout, Disable IPv6,
    Allow legacy crypto.

  An empty field writes no key. A token, a client certificate and a cookie
  are set in JSON. The node row shows the gateway type, for example
  `openconnect·fortinet`. If UDP to the gateway does not get through, the
  core falls back to TLS after about 8 s; **TCP only (no DTLS)** skips that
  wait.
- **OpenConnect form on the Source tab of a node (task 654).**
  For an OpenConnect node the same form sits above the JSON on **Source**.
  The form and the JSON are one body: a field change rewrites the text, a
  text change updates the form. Keys the form does not show (`token`,
  `cookie`, `detour`, client certificate) are kept. Changes are saved with
  the screen's **Save**. While the text is not a valid JSON object, the form
  is off and says so.
- **Sign-in codes and browser SSO for OpenConnect (task 654).**
  - When the gateway asks for a second factor, a **Sign-in required: <tag>**
    notification appears, and the node row shows **Waiting for sign-in**. The
    dialog shows the gateway's fields and message. **Submit** sends the code,
    **Not now** closes the dialog and leaves the request pending, **Request a
    new code** makes the gateway send a fresh one. After two wrong codes in a
    row the dialog warns that each wrong code starts a new sign-in on the
    gateway.
  - FortiGate SAML: the **Sign in in your browser** dialog opens the link in
    the browser. The app listens on `127.0.0.1` (the port the gateway names,
    otherwise 8020) and hands the redirect back to the core.
  - SSO that needs a cookie from an embedded browser (Cisco AnyConnect and
    others) is not supported: the dialog says so.

  Code entry and SAML have not yet been run against a live gateway with MFA.
- **Line-wrap button in the JSON editor ([task 649](docs/spec/tasks/649-json-view-wrap-toggle.md)).**
  The Config editor and the read-only JSON views with sticky headers
  (subscription **Source**, node **JSON**) have a wrap button next to search.
  Wrapping is off by default, the button is highlighted while it is on, and
  the choice is not saved: the screen opens again without wrapping. While
  wrapping is on there are no sticky headers — the editor draws them only for
  unwrapped text. Laying out a very long line takes time; a thin progress bar
  at the top of the field shows while it runs.
- **Subscription description from the `announce` header ([task 648](docs/spec/tasks/648-subscription-announce.md)).**
  Providers send a short text in `announce` (`base64:…` or plain), for example
  a legend for the emoji in node names. It is shown in the subscription header
  under **Expires**: up to 4 lines, a tap expands the whole text. If the header
  is missing, the same key is read from the comments at the top of the body.
- **Tag prefix from the emoji in the subscription name ([task 647](docs/spec/tasks/647-subscription-emoji-tag-prefix.md)).**
  When a new subscription first gets its name and the prefix is empty, the
  emoji group from the name becomes the prefix: `Liberty VPN 🗽` → `🗽`. A
  prefix already taken gets an index: `🗽2`. Existing subscriptions keep their
  prefixes.
- **Source tab: `base64:` headers decoded ([task 650](docs/spec/tasks/650-source-headers-base64-toggle.md)).**
  Values such as `profile-title` and `announce` are shown as text; the
  `base64` label under the header name switches the line back to the raw
  value. Copy still copies the raw block.

## 🔄 Changed

- **⋮ menu in the JSON editor ([task 660](docs/spec/tasks/660-editor-overflow-menu.md)).**
  Every JSON field and viewer has a ⋮ menu at the right end of its button row.
  **Format** moves there, and read-only viewers (subscription **Source**, node
  **JSON**) get it too: it formats only what is shown, **Show original** brings
  the source text back. **Magnifier** turns the selection magnifier on and
  off; the choice is saved for the whole app. After a wrap toggle or Format the
  wrap button and the menu show a spinner and ignore taps until the lines are
  laid out.
- **Editor gestures follow the direction of the swipe (task 649).**
  - A sideways swipe over a line that does not fit scrolls the text; the tab
    stays. Where nothing scrolls sideways, the swipe switches the tab as
    before.
  - A vertical swipe scrolls the text. Once the text is at its edge, the next
    swipe in the same direction scrolls the page.
  - With a selection the editor keeps the whole touch, so the handles move in
    any direction.
- **"Skip presets" is now "Skip Tailscale presets" (task 656).**
  The switch is shown only on Tailscale nodes and affects only the Tailscale
  preset. The old setting carries over, including from older LX Backup files.
- **One connection card for Conns and the profiler ([task 662](docs/spec/tasks/662-unified-connection-detail-sheet.md)).**
  Both screens open the same card with the same groups in the same order. Each
  keeps its own blocks: One-way traffic and **Close** on Conns, DNS and Issues
  in the profiler. A closed connection shows a `TCP·` / `UDP·` badge; a tap on
  it says `TCP closed` / `UDP closed`.
- **One User-Agent for every request of the app ([task 659](docs/spec/tasks/659-app-user-agent-everywhere.md)).**
  Rule-sets, update checks, Donate and the support feed, Speed Test, community
  servers, node diagnostics and the TV transfer send `LxBox-android/<version>`,
  the same string as the subscription default. **Custom User-Agent** applies to
  subscriptions only. WARP registration keeps the Cloudflare client string;
  ping and auto-select are unchanged.
- **WARP: the eight `8.x` blocks are back in the WireGuard endpoint pool ([task 651](docs/spec/tasks/651-warp-8x-blocks-return.md)).**
  They were removed in June as unreachable; fresh measurements show them
  answering on a par with the other blocks.

## 🩹 Fixed

- **"Auto-restart VPN on settings change" applies every change ([task 667](docs/spec/tasks/667-auto-apply-gate-shared-by-all-rebuild-paths.md)).**
  Enabling a large subscription and going back at once, applying a Direction
  from the home list, two edits within three seconds, or an edit made during a
  rebuild could leave the "restart VPN" banner instead of a reload. One check
  now decides for every path; a change that falls into the three-second pause
  is applied when the pause ends. Editing a chain or adding a source on
  **Servers** no longer reloads the VPN on its own: with the setting off they
  show the banner like any other change.
- **Start after a long idle no longer hangs in "stopping" ([task 663](docs/spec/tasks/663-force-stop-reaches-stuck-stopping.md)).**
  **Start** could stay dead until the app was force-closed. The force stop now
  reaches the service even after its receiver is gone. Checked on the
  emulator only.
- **Speed Test opens with the VPN up ([task 666](docs/spec/tasks/666-speed-test-open-rangeerror-empty-servers.md)).**
  Since 2.25.13 the route label under the title was computed before the server
  list had loaded, and the screen showed an error instead of the test. **Start**
  is now inactive until the list is loaded.
- **Telegram support links with `tg://` ([task 657](docs/spec/tasks/657-telegram-support-url-tg-scheme.md)).**
  A `support-url: tg://resolve?domain=…` header shows the Telegram icon on the
  subscription screen and in the list. Without Telegram installed the link
  opens its `t.me` web form instead of only being copied.
- **A node the core cannot decode is turned off ([task 653](docs/spec/tasks/653-core-decode-error-index-to-tag.md)).**
  An old MASQUE node from sing-box JSON still carrying `network: h2|h3` made
  the core refuse the config at **Start** with
  `outbounds[N].network: json: unknown field`. The VPN did not come up and
  the node stayed on. Now the index is matched to the node in the config that
  was sent, the node is turned off and the start is repeated, as with other
  nodes the core rejects.
- **WebSocket `Host` written as a list (task 654).** A sing-box JSON node with
  `headers.Host` as a list got `[a.com]` as its host. The first element is
  taken now.
- **Selection magnifier (task 649).** In the Config editor after scrolling
  down it was a blank white box; in node JSON after moving the page it showed
  lines from another place. It now draws the editor's own text under the
  finger.
- **The screen no longer freezes after start with large subscriptions ([task 652](docs/spec/tasks/652-lazy-rehydration-isolate.md)).**
  Disabled subscriptions are no longer loaded at start: they are read from the
  cache when turned on, opened, or needed for the config. Parsing the cached
  body and the fresh server response runs off the UI thread: updating a
  subscription with 4025 nodes now holds the UI for 0.24 s instead of 1.85 s.

## 🗑 Removed

- **Tailscale node: the "Allow LAN access while using exit node" switch ([task 646](docs/spec/tasks/646-tailscale-remove-lan-access-switch.md)).**
  The core on Android does not apply `exit_node_allow_lan_access`. The local
  network with an exit node goes direct through the **Private IPs** preset.
  The field is still accepted from JSON.

## 🔧 Under the hood

- Core `v1.14.3-lx.18` → `v1.14.3-lx.21`. Nothing changes on Android: lx.19
  and lx.20 fix the Linux router daemon, lx.21 adds TrustTunnel to desktop and
  router builds only. The Java surface is the same as in lx.18.
- Launcher contract 1.1.119 → 1.1.132: OpenConnect fields and the form model
  in the registry; keys a type does not describe pass through as is
  (`openvpn-client`, `openconnect`); an empty described object
  (`tls.ech: {}`, `transport: {}`) is dropped with a warning; the short `#if`
  form and `#if` on `#do` in the template language; node fields
  `allow_local`, `allow_lan`, `allow_gateway`; `skip_presets` renamed to
  `skip_tailscale_presets` (the old key is still read in storage and
  LX Backup).
- The Debug API returns `announce` in `/subs`.
- New tests: the wrap button and its state, the progress bar, the gesture
  decision table and the recognizer against horizontal and vertical drags,
  `announce` parsing, emoji prefixes with indexes, `base64` header decoding,
  the decode form of a core rejection, the OpenConnect form and its sync with
  Source, sign-in logic, the Tunnel ingress build and node flags in LX Backup,
  the DNS tab staying in sync with the other Routing tabs, the transfer code
  and its encrypted envelope, the TV receive server, Telegram link detection,
  the Send HWID default, the app User-Agent, Speed Test's first frame with the
  tunnel up, the auto-restart check on every rebuild path, fragmentation
  inheritance for REALITY.

</details>

<details open>
<summary><h2>🇷🇺 Русский</h2></summary>

## ⚠️ Прочтите до обновления

- **Настройки DNS переехали на экран Routing ([задача 655](docs/spec/tasks/655-dns-tab-in-routing.md)).**
  Пункта **DNS Settings** в боковом меню больше нет. Те же настройки — на
  вкладке **DNS** экрана **Routing**, сразу после **Rules**: Directions ·
  Presets · Rules · DNS · Tunnel apps. Блоки, редакторы и диалоги прежние.
  Подпись пункта Routing в меню теперь «Directions, rules and DNS».
  **DNS settings** в листе DNS health и support-ссылки на экран DNS
  открывают Routing на вкладке DNS.
- **Входящие соединения из клиентских туннелей отклоняются ([задача 656](docs/spec/tasks/656-contract-1130-tunnel-ingress.md)).**
  Пиры с той стороны узла WireGuard, AmneziaWG, OpenVPN или OpenConnect
  могут открывать соединения к телефону: к самому телефону, в локальную сеть
  или через него в интернет. Новый пресет **Tunnel ingress** включён по
  умолчанию и закрывает их. На существующей установке он добавляется один
  раз при обновлении; удалённый пресет не возвращается. Что пропускает узел,
  задаётся в его настройках, в блоке **Incoming connections from this
  tunnel**:
  - **Allow access to this device** — доступ к самому телефону;
  - **Expose local network** — пиры видят частные сети за телефоном;
  - **Allow as gateway** — пиры пускают через телефон любой трафик.

  По умолчанию все три выключены. У пресета три настройки: **Incoming from
  tunnels** (что делать с остальными: по умолчанию `reject`, можно `drop`
  или исходящий канал), **Device and local network go to** (по умолчанию
  `direct-out`) и **Gateway traffic goes to** (по умолчанию `vpn-1`).
  DNS-запросы из закрытого туннеля тоже отклоняются. Узлы Tailscale пресет
  не трогает: пиров tailnet ограничивают ACL Tailscale.
- **Send HWID включён по умолчанию ([задача 658](docs/spec/tasks/658-send-hwid-on-by-default.md)).**
  Без `x-hwid` панель Remnawave заводит устройство сама, без имени, и после
  обновления приложения может посчитать его новым устройством в лимите. Если
  **Send HWID** не трогали, приложение начнёт слать его со следующего
  обновления подписки; явное Off сохраняется. Панель с лимитом устройств
  увидит установку ещё раз, уже с именем (`SM-S918B | Android`). Старое
  безымянное устройство удаляется в панели или в боте провайдера.
- **Фрагментация TLS доходит до REALITY-узлов с любого уровня ([задача 665](docs/spec/tasks/665-tls-fragment-inherits-everywhere-reality-too.md), issue #170).**
  С 2.25.12 глобальная настройка, папка и подписка пропускали REALITY-узлы.
  Теперь REALITY наследует фрагментацию как любой узел, а узел с
  унаследованной фрагментацией пишет об этом под секцией TLS. **Если ваш
  REALITY-сервер не принимает разрезанный ClientHello, поставьте Off на этом
  узле или его подписке.**

## ✨ Новое

- **Настройка TV с телефона ([задача 622](docs/spec/tasks/622-device-transfer-phone-to-tv.md), issue #163).**
  На TV: Backup & restore → Receive from phone → **Show code**. На телефоне:
  Backup & restore → отметить категории → **Send to TV** → **Scan code**. На
  TV открывается обычное окно **Import backup**. Настройки идут
  зашифрованными одноразовым ключом, который есть только в QR-коде; код
  живёт 10 минут, годен на одну передачу и закрывается после пяти отправок с
  неверным ключом. Телефон отправляет мимо своего VPN, так что передача
  работает при поднятом туннеле. Оба устройства должны быть в одной сети;
  гостевой Wi-Fi часто их разделяет. Пункт приёма есть только на TV, пункт
  отправки — только на устройстве с камерой. На реальных устройствах ещё не
  проверено.
- **Источник и вход у соединений не через TUN ([задача 661](docs/spec/tasks/661-stats-source-inbound.md)).**
  С Tunnel ingress, `allow_lan` / `allow_gateway` у узла или локальным
  прокси (`mixed-in`, `sysproxy-in`) соединения приходят не только из TUN.
  Conns, Stats → Overview и лента профайлера дописывают к такому соединению
  `<ip:port> / <inbound>`, например `(no owner) · 10.8.0.2:40112 / wg-in`.
  Для `tun-in` ничего не дописывается. В карточке соединения перед
  Destination появилась группа **Source**.
- **OpenConnect в Add server ([задача 654](docs/spec/tasks/654-openconnect-fortinet-support.md)).**
  Новая вкладка **OpenConnect** добавляет корпоративный VPN-шлюз. В основном
  блоке — **Tag**, **Gateway** (FortiGate, Cisco AnyConnect, GlobalProtect,
  F5, Pulse, Juniper; по умолчанию FortiGate), **Server** (`host:port` или
  полный URL, без порта — 443), **Username** и **Password**.
  - **Security**: проверка сертификата сервера (System CA, Pinned
    fingerprint или Do not verify), SNI, Group / Realm (у FortiGate скрыто),
    Disable SSO.
  - **Advanced** (свёрнут): TCP only (no DTLS), User-Agent, Hostcheck
    (только FortiGate), MTU, DPD interval, Reconnect timeout, Disable IPv6,
    Allow legacy crypto.

  Пустое поле ключ не пишет. Токен, клиентский сертификат и cookie задаются
  в JSON. В строке узла виден тип шлюза, например `openconnect·fortinet`.
  Если UDP до шлюза не проходит, ядро уходит на TLS примерно через 8 с;
  **TCP only (no DTLS)** убирает это ожидание.
- **Форма OpenConnect на вкладке Source узла (задача 654).**
  У узла OpenConnect та же форма стоит над JSON на вкладке **Source**. Форма
  и JSON — одно тело: правка поля переписывает текст, правка текста
  обновляет форму. Ключи, которых в форме нет (`token`, `cookie`, `detour`,
  клиентский сертификат), сохраняются. Сохраняет общая кнопка **Save**
  экрана. Пока текст не разбирается как JSON-объект, форма выключена и
  об этом написано.
- **Коды входа и SSO через браузер для OpenConnect (задача 654).**
  - Когда шлюз просит второй фактор, появляется уведомление **Sign-in
    required: <тег>**, а в строке узла — **Waiting for sign-in**. Диалог
    показывает поля и сообщение шлюза. **Submit** отправляет код, **Not now**
    закрывает диалог и оставляет запрос висеть, **Request a new code**
    просит шлюз прислать новый. После двух неверных кодов подряд диалог
    предупреждает, что каждый неверный код запускает на шлюзе новый вход.
  - SAML у FortiGate: диалог **Sign in in your browser** открывает ссылку в
    браузере. Приложение слушает `127.0.0.1` (порт, который назвал шлюз,
    иначе 8020) и отдаёт редирект ядру.
  - SSO, которому нужен cookie из встроенного браузера (Cisco AnyConnect и
    другие), не поддержан: диалог так и говорит.

  Ввод кода и SAML на живом шлюзе с MFA ещё не прогонялись.
- **Кнопка переноса строк в редакторе JSON ([задача 649](docs/spec/tasks/649-json-view-wrap-toggle.md)).**
  В редакторе Config и в просмотрщиках JSON с липкими заголовками (**Source**
  подписки, **JSON** узла) рядом с поиском появилась кнопка переноса. По
  умолчанию перенос выключен, включённая кнопка подсвечена, выбор не
  сохраняется: экран открывается снова без переноса. Пока перенос включён,
  липких заголовков нет — редактор рисует их только без переноса. Раскладка
  очень длинной строки считается не сразу; пока она идёт, у верхнего края
  поля видна тонкая полоса прогресса.
- **Описание подписки из заголовка `announce` ([задача 648](docs/spec/tasks/648-subscription-announce.md)).**
  Провайдеры присылают в `announce` короткий текст (`base64:…` или открытый),
  например легенду к эмодзи в именах узлов. Он показывается в шапке подписки
  под **Expires**: до 4 строк, тап раскрывает текст целиком. Если заголовка
  нет, тот же ключ читается из комментариев в начале тела.
- **Префикс тегов из эмодзи в названии подписки ([задача 647](docs/spec/tasks/647-subscription-emoji-tag-prefix.md)).**
  Когда новая подписка впервые получает имя, а префикс пустой, префиксом
  становится группа эмодзи из имени: `Liberty VPN 🗽` → `🗽`. Занятый префикс
  получает индекс: `🗽2`. У существующих подписок префиксы не меняются.
- **Вкладка Source: `base64:`-заголовки расшифрованы ([задача 650](docs/spec/tasks/650-source-headers-base64-toggle.md)).**
  Значения вроде `profile-title` и `announce` показываются текстом; подпись
  `base64` под именем заголовка переключает строку на исходное значение и
  обратно. Копирование блока — как прежде, в исходном виде.

## 🔄 Изменено

- **Меню ⋮ в редакторе JSON ([задача 660](docs/spec/tasks/660-editor-overflow-menu.md)).**
  У каждого поля и просмотрщика JSON справа в ряду кнопок есть меню ⋮.
  **Format** переехал туда и появился в просмотрщиках только для чтения
  (**Source** подписки, **JSON** узла): форматирует только показанное,
  **Show original** возвращает исходный текст. **Magnifier** включает и
  выключает лупу выделения; выбор сохраняется для всего приложения. После
  переключения переноса или Format кнопка переноса и меню показывают
  индикатор и не реагируют на тапы, пока строки не разложены.
- **Жесты редактора идут по направлению свайпа (задача 649).**
  - Свайп вбок по строке, которая не помещается, прокручивает текст; вкладка
    стоит. Где вбок прокручивать нечего, свайп переключает вкладку, как
    раньше.
  - Вертикальный свайп прокручивает текст. Когда текст упёрся в край,
    следующий свайп в ту же сторону листает страницу.
  - При выделении редактор забирает касание целиком, ручки тянутся в любую
    сторону.
- **«Skip presets» теперь «Skip Tailscale presets» (задача 656).**
  Переключатель виден только у узлов Tailscale и действует только на пресет
  Tailscale. Прежнее значение сохраняется, в том числе из старых файлов
  LX Backup.
- **Одна карточка соединения для Conns и профайлера ([задача 662](docs/spec/tasks/662-unified-connection-detail-sheet.md)).**
  Оба экрана открывают одну карточку с одними группами в одном порядке. У
  каждого остаются свои блоки: One-way traffic и **Close** в Conns, DNS и
  Issues в профайлере. У закрытого соединения бейдж `TCP·` / `UDP·`; тап по
  нему показывает `TCP closed` / `UDP closed`.
- **Один User-Agent для всех запросов приложения ([задача 659](docs/spec/tasks/659-app-user-agent-everywhere.md)).**
  Rule-set'ы, проверка обновлений, Donate и support-лента, Speed Test,
  community-серверы, диагностика узла и передача на TV шлют
  `LxBox-android/<версия>` — ту же строку, что подписки по умолчанию.
  **Custom User-Agent** действует только на подписки. Регистрация WARP
  оставляет строку клиента Cloudflare; пинг и автовыбор не менялись.
- **WARP: восемь блоков `8.x` вернулись в пул адресов WireGuard ([задача 651](docs/spec/tasks/651-warp-8x-blocks-return.md)).**
  В июне их убрали как недоступные; свежие замеры показывают, что они
  отвечают наравне с остальными блоками.

## 🩹 Исправлено

- **«Auto-restart VPN on settings change» применяет каждое изменение ([задача 667](docs/spec/tasks/667-auto-apply-gate-shared-by-all-rebuild-paths.md)).**
  Включение большой подписки с мгновенным возвратом назад, Направление с
  главного экрана, две правки за три секунды или правка во время уже идущей
  пересборки могли оставить плашку «restart VPN» вместо перезапуска. Теперь
  решает одна проверка для всех путей; правка, попавшая в трёхсекундную
  паузу, применяется по её окончании. Правка цепочки и добавление источника
  на **Servers** больше не перезапускают VPN сами: при выключенной настройке
  они показывают плашку, как любая правка.
- **Старт после долгого простоя не зависает в «stopping» ([задача 663](docs/spec/tasks/663-force-stop-reaches-stuck-stopping.md)).**
  **Start** мог не работать, пока приложение не закроешь принудительно.
  Принудительная остановка теперь доходит до службы и после того, как её
  приёмник снят. Проверено только на эмуляторе.
- **Speed Test открывается при поднятом VPN ([задача 666](docs/spec/tasks/666-speed-test-open-rangeerror-empty-servers.md)).**
  С 2.25.13 подпись маршрута под заголовком считалась до загрузки списка
  серверов, и вместо теста экран показывал ошибку. **Start** теперь
  неактивна, пока список не загружен.
- **Ссылки поддержки в Telegram вида `tg://` ([задача 657](docs/spec/tasks/657-telegram-support-url-tg-scheme.md)).**
  Заголовок `support-url: tg://resolve?domain=…` показывает значок Telegram
  на экране подписки и в списке. Без установленного Telegram ссылка
  открывается в веб-форме `t.me`, а не только копируется.
- **Узел, который ядро не может разобрать, выключается ([задача 653](docs/spec/tasks/653-core-decode-error-index-to-tag.md)).**
  Старый узел MASQUE из sing-box JSON с ключом `network: h2|h3` заставлял
  ядро отказывать на **Start** с ошибкой
  `outbounds[N].network: json: unknown field`. VPN не поднимался, узел
  оставался включённым. Теперь индекс сопоставляется с узлом по
  отправленному конфигу, узел выключается и старт повторяется — как с
  другими узлами, которые ядро не приняло.
- **`Host` у WebSocket, записанный списком (задача 654).** Узел из sing-box
  JSON с `headers.Host` в виде списка получал хост `[a.com]`. Теперь берётся
  первый элемент.
- **Лупа выделения (задача 649).** В редакторе Config после прокрутки вниз
  она была пустой белой; в JSON узла после сдвига страницы показывала строки
  из другого места. Теперь она рисует текст самого редактора под пальцем.
- **Экран не замирает после старта с большими подписками ([задача 652](docs/spec/tasks/652-lazy-rehydration-isolate.md)).**
  Выключенные подписки на старте больше не загружаются: они читаются из кэша,
  когда их включают, открывают или они нужны для сборки конфига. Разбор
  кэша и свежего ответа сервера идёт вне потока интерфейса: обновление
  подписки на 4025 узлов держит интерфейс 0,24 с вместо 1,85 с.

## 🗑 Удалено

- **Узел Tailscale: переключатель «Allow LAN access while using exit node» ([задача 646](docs/spec/tasks/646-tailscale-remove-lan-access-switch.md)).**
  Ядро на Android поле `exit_node_allow_lan_access` не применяет. Локальная
  сеть при выходном узле идёт напрямую через пресет **Private IPs**. Поле
  по-прежнему принимается из JSON.

## 🔧 Под капотом

- Ядро `v1.14.3-lx.18` → `v1.14.3-lx.21`. На Android ничего не меняется:
  lx.19 и lx.20 правят Linux-демон роутера, lx.21 добавляет TrustTunnel
  только в desktop- и роутерные сборки. Java-поверхность та же, что у lx.18.
- Контракт лаунчера 1.1.119 → 1.1.132: поля OpenConnect и модель формы в
  реестре; ключи, которые тип не описывает, проходят как есть
  (`openvpn-client`, `openconnect`); пустой описанный объект
  (`tls.ech: {}`, `transport: {}`) снимается с предупреждением; короткая
  форма `#if` и `#if` на `#do` в языке шаблона; поля узла `allow_local`,
  `allow_lan`, `allow_gateway`; `skip_presets` переименован в
  `skip_tailscale_presets` (старый ключ по-прежнему читается в хранилище и
  LX Backup).
- Debug API отдаёт `announce` в `/subs`.
- Новые тесты: кнопка переноса и её состояние, полоса прогресса, таблица
  решений жестов и распознаватель против горизонтального и вертикального
  drag, разбор `announce`, эмодзи-префиксы с индексами, расшифровка
  `base64`-заголовков, форма отказа ядра на декодировании, форма OpenConnect
  и её связь с Source, логика входа, сборка Tunnel ingress и флаги узла в
  LX Backup, согласованность вкладки DNS с остальными вкладками Routing, код
  передачи и его шифрованный конверт, сервер приёма на TV, опознание ссылок
  Telegram, дефолт Send HWID, User-Agent приложения, первый кадр Speed Test
  при поднятом туннеле, проверка автоперезапуска на всех путях пересборки,
  наследование фрагментации у REALITY.

</details>

---

## Install / Установка

```bash
adb install -r LxBox-v2.25.16-arm64-v8a.apk
```

Без uninstall! Поверх существующей установки. Настройки и подписки сохранятся.

No uninstall needed — install over the existing one. Settings and subscriptions
are preserved.

---

Previous release / Предыдущий релиз: [v2.25.15](docs/releases/v2.25.15.md).
