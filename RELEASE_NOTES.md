# L×Box v2.25.19

**A patch on top of [v2.25.18](https://github.com/Leadaxe/LxBox/releases/tag/v2.25.18).**
It closes the v2.25.19-rc.1 … rc.3 line and adds the changes made after rc.3.

**TrustTunnel**: `tt://` links become nodes, and the Android core now
includes the protocol. **Taildrop**: send and receive files over a Tailscale
node, and «📋 Send» from the VPN notification puts text and links on your
other devices. **Mixins** keep your own additions to the final core config
across rebuilds. DNS gets **Hosts** servers and Hosts in groups; template DNS
servers are editable and can be reordered. Rules match the network type,
metered networks and package or domain regexes. A node budget caps the total
number of nodes, and the number of parallel checks is configurable. VPN
Settings → Core and App Settings are laid out as cards. Core
`v1.14.4-lx.31`, contract 1.1.160.

**Патч поверх [v2.25.18](https://github.com/Leadaxe/LxBox/releases/tag/v2.25.18).**
Закрывает линию v2.25.19-rc.1 … rc.3 и добавляет изменения, сделанные после
rc.3.

**TrustTunnel**: ссылки `tt://` становятся узлами, а Android-ядро теперь
включает этот протокол. **Taildrop** — отправка и приём файлов через узел
Tailscale, а «📋 Send» из уведомления VPN кладёт текст и ссылки на другие
ваши устройства. **Mixins** хранят свои вставки в итоговый конфиг ядра и
переживают пересборки. В DNS появились серверы **Hosts** и Hosts у групп;
шаблонные DNS-серверы редактируются и переставляются. Правила различают тип
сети, лимитные сети и регулярки по пакету и домену. Бюджет узлов ограничивает
их общее число, число параллельных проверок настраивается. VPN Settings →
Core и App Settings оформлены карточками. Ядро `v1.14.4-lx.31`, контракт
1.1.160.

---

<details open>
<summary><h2>🇬🇧 English</h2></summary>

## ⚠️ Read before updating

- **Node budget: 1000 nodes in total by default ([task 714](docs/spec/tasks/714-node-budget-subscription-cut.md), issue #190).**
  Manual servers and enabled folder members are never cut; enabled
  subscriptions share the rest. A subscription above its share keeps its
  first nodes, and its card reads «N of M nodes» with ⚠. If you use
  subscriptions with more nodes, raise the limit in App Settings → General →
  Node budget.
- **Taildrop is off on every Tailscale node, existing ones included
  ([task 707](docs/spec/tasks/707-taildrop-send-receive-files.md)).** A node
  receives and sends files only after «Allow Taildrop» is turned on in its
  settings; it takes effect after the VPN restarts.
- **WireGuard sleep settings moved to VPN Settings → Core and start from the
  defaults ([task 709](docs/spec/tasks/709-quic-sniff-decoy-toggle.md)).**
  Suspend idle tunnels 30 seconds, Suspend active-route tunnels 5 minutes,
  Lazy tunnel build on, Built tunnels limit 5. Values chosen earlier on the
  System tab are not carried over: set them again if they differed.
- **Memory limit: Auto sets no cap, Off is folded into Auto ([task 705](docs/spec/tasks/705-memory-limit-auto-off.md)).**
  The limit is now compared with the core's own memory (its Go runtime), not
  with the whole app process it shares with the interface and libraries: a
  200 MB cap used to trip right at start and only made the garbage collector
  heat the phone. The core keeps watching the phone's free memory as before.
  The 200–768 MB presets stay for an explicit choice, and a value chosen
  earlier is kept.
- **«Interrupt connections on switch» is removed ([task 143](docs/spec/tasks/143-interrupt-connections-on-node-switch.md)).**
  The switch in VPN Settings → System only duplicated each Direction's own
  checkbox of the same name and could override it: the core has dropped a
  Direction's connections on any node switch since 2.20.9. If it was on, the
  update turns the checkbox on in every Direction where it was off. The Debug
  API route `/settings/interrupt_on_switch` is gone; an old backup with this
  setting still restores.
- **Default TUN MTU is 9000 instead of 1492 ([task 700](docs/spec/tasks/700-tun-mtu-default-9000.md)).**
  9000 is the sing-box default. The tunnel interface is virtual and the core
  re-sends TCP at the real network MTU, so a small value only added packets
  and CPU work. Installs where MTU was never changed get 9000 with the next
  config build; a value set by hand stays.
- **DNS servers that something refers to are switched on.** A setup from
  older versions where a referenced DNS server is off (a group member, a
  domain resolver, DNS Final, Default Domain Resolver) is fixed on start: the
  server is switched on, and the app log says why.
- **AmneziaWG masquerade through a detour.** With core lx.31 an AWG node
  with a masquerade burst (`ip=quic`, `i1`…) sends the burst only when it
  connects on the device's own socket; through a `detour` it sends a plain
  handshake. This lets such a node come up through a relay that sniffs QUIC.
  If an AWG node behind a detour behaves differently after the update,
  report it.

## ✨ New

- **TrustTunnel nodes and `tt://` links ([task 717](docs/spec/tasks/717-trusttunnel-deeplink-uri.md), issue #194).**
  A `tt://` link (the deep link of the AdGuard TrustTunnel client) is
  recognized when pasted from the clipboard, in a list of links and in a
  subscription, and becomes a `trusttunnel` node: the first address as
  server and port, user name and password, HTTP/2 or HTTP/3 (QUIC), the SNI,
  a pinned certificate, skip verification. The Android core now includes
  TrustTunnel; before, the core rejected such a node and the app switched it
  off. Link fields the node has no place for (more addresses, DNS upstreams,
  `anti_dpi`, client random) are dropped with a warning, and the node stays.
  Not yet supported: a link that carries only a subscription address
  (`subscription_url`) is dropped, and exporting a node as a `tt://` link
  comes later.
- **Taildrop: send and receive files over a Tailscale node
  ([task 707](docs/spec/tasks/707-taildrop-send-receive-files.md)).** L×Box
  is a Share target for files: they go to one of your online devices in the
  tailnet, with progress and Cancel in a notification. A tap on a device on
  the Network tab opens its page: Ping, Send file…, addresses (a tap
  copies); a long tap on the row copies its first address. Received files
  land in the node's Inbox on the Network tab with Save (to Downloads) and
  Delete; receive notifications have Cancel, Save and Delete. With «Allow
  Taildrop» on, two switches of the node are on by default: «Save received
  files to Downloads» (Android 10+) moves every received file there by
  itself, and «Accept clipboard and links from my devices» runs what your
  own devices send. The Debug API has `/taildrop/*`.
- **📋 Send: text and links to your devices
  ([task 707](docs/spec/tasks/707-taildrop-send-receive-files.md#итерация-7--окно-send-clipboard-буфер-и-ссылки-с-телефона)).**
  «📋 Send» in the VPN notification opens a chat-like window over the
  current app with the clipboard text in the field: ➤ puts it into the
  device's clipboard, «Open on <device>» opens a single link there. Shared
  text and «Send to device» in the text selection menu open the same window.
  The window keeps the exchange with each device while the VPN runs. The
  other side is the desktop launcher or another L×Box. The button, Share and
  «Send to device» appear only while the VPN runs a Tailscale node with Allow
  Taildrop.
- **Tailscale node on/off and restart on the fly
  ([task 706](docs/spec/tasks/706-tailscale-network-tab-logged-out.md)).**
  The Network tab has Node enabled and Restart node; Turn off / Turn on in the
  node list works for Tailscale nodes too. Replace key signs the node in with
  the new key without restarting the VPN.
- **Mixins ([task 704](docs/spec/tasks/704-config-mixins.md)).**
  Config → Mixins keeps operations applied at the end of every config build:
  a target path (`route.rules[action=hijack-dns]`, `inbounds[tag=dns-in]`), a
  verb (append, prepend, before, after, set, merge, remove) and a JSON value.
  The form shows whether the target matches and a preview of the result.
  Unlike a manual edit with Lock config, a mixin survives rebuilds; it travels
  in LX Backup and is available through the Debug API (`/mixins`). A mixin
  that does not apply or adds a duplicate tag stops the build with its name in
  the message. Example: a `direct` inbound on `127.0.0.1:5354` with a
  `hijack-dns` rule hands the core's DNS to another app.
- **Hosts DNS server and Hosts in a DNS group ([task 699](docs/spec/tasks/699-dns-hosts-server-and-group-overlay.md), issue #185).**
  The DNS server editor gets a Hosts type: names with fixed IPv4/IPv6
  addresses, one row per name, edited in a dialog. A DNS group gets a Hosts
  block under Members: the names these servers know are answered first, all
  other names go to the members as before. Put such a group into Default
  Domain Resolver and a node address like `wg.home` resolves to your own
  addresses, with `strategy` choosing the family. A hosts server referenced
  by a group cannot be turned off or deleted. Renaming a DNS server now
  updates group members and Hosts too; a renamed member used to drop out of
  its group.
- **Node budget ([task 714](docs/spec/tasks/714-node-budget-subscription-cut.md), issue #190).**
  App Settings → General → Node budget: one limit on nodes for the whole app
  (default 1000, from 1, no upper limit). Manual servers and enabled folder
  members come first and are never cut; the rest is shared between enabled
  subscriptions equally, and what a small subscription does not need goes to
  the others. Nodes a rule, a chain or a Direction's default filter points to
  stay first. Enabling a subscription, editing servers or folders and
  changing the budget re-cut subscriptions from the cache, without network.
  The setting travels in the backup and is in the Debug API
  (`/settings/node_budget`).
- **Parallel checks ([task 713](docs/spec/tasks/713-ping-concurrency-setting.md), issue #192).**
  App Settings → General → Parallel checks sets how many servers the mass
  ping and a folder's Test servers measure at once (1–100, default 10, with
  a reset button). It travels in the backup and is in the Debug API.
- **Regex conditions in routing rules ([task 712](docs/spec/tasks/712-package-name-regex-domain-regex-rules.md), issue #193).**
  A rule takes a package name regex (under the app picker) and a domain
  regex (under Domain keyword), one Go RE2 pattern per line. One pattern
  such as `^com\.oplus\.` replaces picking every system package of a vendor.
  Remote `.srs` rules take the package regex too.
- **Rules by network type and metered networks ([task 694](docs/spec/tasks/694-rule-network-type-metered.md), issue #178).**
  The rule editor's Wi-Fi section is now «NETWORK»: Any / Wi-Fi / Cellular /
  Ethernet and a «Metered networks only» checkbox (mobile data and Wi-Fi
  marked as metered in Android). Neither needs the location permission that
  SSID matching requires; the SSID list is shown only for Wi-Fi. Rules are
  checked when a connection opens: on a switch between Wi-Fi and mobile data
  the app resets connections, so new ones follow the new network; when
  Android only flips the metered flag, open connections keep their earlier
  decision.
- **VPN Settings → Core as cards
  ([task 709](docs/spec/tasks/709-quic-sniff-decoy-toggle.md)).** General,
  Network, TUN, TLS Fragmentation, WireGuard and QUIC are separate cards. The
  core's own settings have an (i) with a short hint.
  - **WireGuard** — the four sleep and build settings, moved from System.
    Rows that depend on sleeping are greyed out while it is off.
  - **Network → Align MTU to the path** — Clamp (default), Fill or Off: how a
    node that runs over a tunnel (detour, chain) gets a packet size that fits.
  - **QUIC → Anti-sniff decoy** — Off, Through detour (default), Direct or
    All: one junk byte before the QUIC handshake of MASQUE (HTTP/3),
    Hysteria2 and TUIC, so a relay that sniffs UDP does not redirect the
    connection by its SNI. Servers drop the byte. By default only connections
    carried by another node get it: a DPI on your own uplink may react to it.
  - **QUIC → MASQUE idle timeout** — Off by default; closes an idle MASQUE
    tunnel, a node's own idle timeout wins.
- **UID in the app picker ([task 693](docs/spec/tasks/693-app-picker-shared-uid-hint.md), issue #180).**
  Android lets several packages share one UID (on Samsung dozens of system
  apps live under UID 1000), and the core and the system's per-app VPN tell
  apps apart by UID, so a rule or a Tunnel apps entry for one package covers
  the whole group. Rows in the app picker and in Tunnel apps read «package ·
  UID n»; for a shared UID, «Shared with N other apps — they are routed
  together» opens the list. Rules and Tunnel apps work as before.
- **Ru internet segment: each Yandex DNS server can be turned off ([task 697](docs/spec/tasks/697-ru-direct-dns-servers-off.md), issue #183).**
  Next to «UDP server IP» there are «DoT server IP» and «DoH server IP»,
  and each of the three lists has «Off»: that server is not used and leaves
  the group. The address chooses the Yandex profile (Base, Safe or Family)
  for DoT and DoH as for UDP; before, both were fixed to Safe. With all
  three Off the preset's DNS works as with its DNS switch off. Defaults are
  unchanged.
- **Full-screen node filter picker in the Direction editor ([task 702](docs/spec/tasks/702-direction-node-filter-picker.md)).**
  A button to the right of Node filter opens a full screen: the regex field
  with `!`, the emoji found in node names with a count for each (a tap adds
  the emoji to the pattern, a second tap removes it), and the whole node list
  with matched nodes on top marked ✓ and the rest marked ✗. ✓ in the top bar
  puts the pattern back into the editor.
- **Reorder DNS servers ([task 710](docs/spec/tasks/710-dns-servers-reorder.md)).**
  Servers on the DNS tab move by dragging the strip on the left of a row, as
  DNS rules do; the order is saved in the template's server list.
- **The core's URL test in the node list ([task 715](docs/spec/tasks/715-auto-twin-pool-label-core-delays.md), issue #191).**
  While the tunnel is up, the core's own URL test results show in the node
  list as a foreign measurement: dimmed, with the `~` prefix, like a
  measurement from another Direction. The app's own ping takes precedence.
- **Core memory in Statistics → Memory.** The core's figure is shown as «Core
  memory» next to the process RSS, with the limit beside it when a number is
  chosen.
- **Debug API: the selected node of every group.** `GET /state` gets
  `group_selected`: group tag → the node the core has selected, for every
  selector and urltest group, not only for the Direction open on the home
  screen.

## 🔄 Changed

- **Template DNS servers and groups are editable ([task 695](docs/spec/tasks/695-dns-disabled-group-holds.md), issue #182).**
  The editor shows the same form as for your own servers below the
  variables; a changed server is saved as your copy under the same tag,
  marked «Overridden», and «Reset to template» in the ⋮ menu brings the
  template version back. DNS Final, Default Domain Resolver, a server's
  domain resolver and a group's members offer only enabled servers. A
  server that something refers to stays on and locked. Adding a server from
  the catalog also adds the servers it needs: the members of a group and its
  domain resolver. A disabled group with no enabled members cannot be
  switched on.
- **VPN notification buttons: Stop, «🔄 Restart» and «📋 Send»
  ([task 707](docs/spec/tasks/707-taildrop-send-receive-files.md#итерация-8--кнопки-уведомления-vpn-restart-вернулся-список-в-настройках)).**
  Reconnect is now «🔄 Restart». App Settings → General → Quick connect →
  VPN notification buttons chooses which of the three are shown; all by
  default. «📋 Send» appears only while a Tailscale node has Allow Taildrop.
- **App Settings → General and Diagnostics as cards ([task 716](docs/spec/tasks/716-app-settings-islands.md)).**
  Each section of both tabs is a card with its title, as in VPN Settings.
  The settings themselves are unchanged.
- **Taildrop and notification settings travel in the backup
  ([task 707](docs/spec/tasks/707-taildrop-send-receive-files.md)).** The
  node's Taildrop switches and the notification buttons are stored with the
  other settings and restored from a backup; the app theme mode is backed up
  too. Per-device Taildrop permissions from the release candidates are
  removed: what your own devices send is accepted by the node's switch.
- **A dedicated DNS server in a rule turns on «Resolve before routing»
  ([task 711](docs/spec/tasks/711-ru-direct-resolve-always-dedicated-sets-resolve.md)).**
  Choosing a dedicated DNS server in the rule editor also turns on Resolve
  before routing with that server; the checkbox can be cleared.

## 🐛 Fixed

- **Ru internet segment resolved its domains through the default resolver
  with Force IPv4 off ([task 711](docs/spec/tasks/711-ru-direct-resolve-always-dedicated-sets-resolve.md)).**
  The checkbox removed the whole resolve rule instead of only the IPv4
  strategy, so with FakeIP above the preset the Yandex DNS group was not
  used. The resolve rule is now always present; the checkbox controls only
  the address family.
- **FakeIP: fake IPv6 addresses could not be turned off ([task 690](docs/spec/tasks/690-fakeip-custom-ranges.md), issue #181).**
  An emptied IPv6 pool could not be saved: the field refilled with
  `fc00::/18`. The preset now has a «Fake IPv6 addresses» toggle; when it is
  off, AAAA queries get an answer with no address, and the IPv4 pool stays
  in use.
- **Auto card in Load balance showed the protocol instead of the pool ([task 715](docs/spec/tasks/715-auto-twin-pool-label-core-delays.md), issue #191).**
  The card now shows `🔀 [N/M]` with the pool badges, or the slot names when
  no member gives a badge, the same as an auto-select node.
- **A WireGuard/AWG peer showed «connected» when the server did not answer ([task 613](docs/spec/tasks/613-wg-peers-tailscale-path-health.md)).**
  The peer was green while its last handshake was under three minutes old,
  so a new server in the group the node goes through that passes no traffic,
  and a node just turned off and on, looked alive. Now a peer that sends but
  gets nothing back for about 8 seconds is orange, «no response». After the
  node is turned on or wakes up, the peer shows «never connected» until a new
  handshake, and ↓/↑ count only the current session.
- **Stopping the VPN hung on a MASQUE node with a detour.** When such a node
  (WARP over vless+ws, for example) was being pinged or connecting at that
  moment, the stop waited for it; the pending connection is now cancelled.
- **Start failed with `initialize cache-file: timeout` after a stop that hung ([task 703](docs/spec/tasks/703-cache-db-lock-timeout-retry.md)).**
  The new core instance now takes `cache.db` over by itself and keeps the
  group selection, FakeIP assignments and rule-set cache. If that still fails,
  the app deletes the file and retries the start once; force-stopping the app
  or clearing the DNS cache by hand is no longer needed.
- **A MASQUE, TrustTunnel, Hysteria2 or TUIC node with a detour on a group
  stayed on the old node after a switch.** The tunnel kept running through
  the previous node until its session died; now a switch in the group closes
  the session and the next connection goes through the new node (core
  lx.31).
- **The WARP endpoint picked in the wizard was replaced ([task 386](docs/spec/tasks/386-warp-endpoint-preset-combobox.md)).**
  A picked `engage.cloudflareclient.com:2408` no longer gets replaced by a
  random IP when obfuscation is on, by the address from Cloudflare's reply, or
  by the endpoint of a cached registration.
- **Route on the node screen did not follow the selector.** When the selected
  node of a group on the path changed elsewhere (home screen, Debug API, a
  urltest reselect), Route kept the old pick until the screen was reopened.
  Route and the checkmark in a group's member list now follow the core.
- **Servers could not be removed from Shield DNS.** After 2.25.17 the
  members of Shield DNS stayed locked «used by Shield DNS», and the group
  itself could not be edited (see Changed above).
- **The Network tab of a signed-out Tailscale node could erase the saved exit
  node ([task 706](docs/spec/tasks/706-tailscale-network-tab-logged-out.md)).**
  Outside Running the tab now shows the saved exit node as a line and offers
  Replace key.
- **A node row jumped in height while nodes were pinged.** The row of a node
  without a subtitle (`direct`, for example) collapsed and expanded with the
  ping badge; it now keeps its height.

## 🔧 Under the hood

- Core `v1.14.4-lx.25` → `v1.14.4-lx.31`: the `hosts` key of a DNS group
  (Leadaxe/sing-box-lx#60); MTU alignment fixes (a proxy node inside a group
  no longer lowers the MTU of a tunnel above the group, tunnels carrying
  IPv6 are never set below 1280); WireGuard/AWG peer status per session; a
  MASQUE dial with a detour is cancelled on stop; `cache.db` is taken over
  from a previous instance that hung while stopping
  (Leadaxe/sing-box-lx#61); the memory limit compared with the core's Go
  runtime (Leadaxe/sing-box-lx#62); Tailscale sign-in with a new key and
  on/off without a restart, `disable_taildrop` and the sender of a received
  file (SPEC 149); the QUIC sniff decoy (SPEC 151). lx.31: TrustTunnel in the
  Android build (`with_trusttunnel`), AWG masquerade by path (SPEC 153,
  Leadaxe/sing-box-lx#64), the session of a tunnel with a detour follows the
  selector (SPEC 152), upstream sing-box v1.14.4 + 9 commits (SPEC 154: DNS
  transport setup no longer blocks the TUN packet loop, OpenVPN/OpenConnect
  reopen UDP on address change).
- Contract 1.1.140 → 1.1.160: `trusttunnel` outbounds are judged by the
  registry (a node without `username`, `password` or `tls` is dropped at
  parse time, as in the launcher); backup import merges template and user
  DNS servers by tag; `tcp_multi_path` in a pasted sing-box node is kept as a
  known dialer field; the core's root `lx` keys are template variables
  written by the template, with the same names on the desktop launcher;
  command files (clipboard, links) in one format on both sides; device-side
  settings in the backup; a Tailscale node's `state_dir_id` survives a backup
  round trip.
- The `tt://` section of the parser lives in a draft until the launcher's
  registry ships its own; warning codes may be renamed then.

</details>

<details open>
<summary><h2>🇷🇺 Русский</h2></summary>

## ⚠️ Прочтите до обновления

- **Бюджет узлов: по умолчанию 1000 узлов всего ([задача 714](docs/spec/tasks/714-node-budget-subscription-cut.md), issue #190).**
  Ручные серверы и включённые члены папок не режутся никогда; включённые
  подписки делят остаток. Подписка сверх своей доли оставляет первые узлы, и
  её карточка показывает «N of M nodes» с ⚠. Если ваши подписки больше,
  поднимите лимит в App Settings → General → Node budget.
- **Taildrop выключен на каждом узле Tailscale, включая существующие
  ([задача 707](docs/spec/tasks/707-taildrop-send-receive-files.md)).** Узел
  принимает и отправляет файлы только после включения «Allow Taildrop» в его
  настройках; действует после перезапуска VPN.
- **Настройки сна WireGuard переехали в VPN Settings → Core и начинают с
  дефолтов ([задача 709](docs/spec/tasks/709-quic-sniff-decoy-toggle.md)).**
  Suspend idle tunnels 30 секунд, Suspend active-route tunnels 5 минут, Lazy
  tunnel build включена, Built tunnels limit 5. Значения, выбранные раньше на
  вкладке System, не переносятся: если они отличались, выставьте заново.
- **Memory limit: Auto порога не ставит, Off слит с Auto ([задача 705](docs/spec/tasks/705-memory-limit-auto-off.md)).**
  Лимит теперь сравнивается с памятью самого ядра (его Go-рантаймом), а не
  всего процесса приложения, который ядро делит с интерфейсом и
  библиотеками: порог 200 MB срабатывал сразу на старте и только заставлял
  сборщик мусора греть телефон. За свободной памятью телефона ядро следит
  по-прежнему. Пресеты 200–768 MB остаются для явного выбора, выбранное
  раньше значение сохраняется.
- **Тумблер «Interrupt connections on switch» убран ([задача 143](docs/spec/tasks/143-interrupt-connections-on-node-switch.md)).**
  Тумблер в VPN Settings → System только дублировал одноимённую галочку
  каждого Направления и мог её перекрыть: с 2.20.9 ядро само рвёт соединения
  Направления при любой смене узла. Если он был включён, при обновлении
  галочка включается во всех Направлениях, где была снята. Маршрут Debug API
  `/settings/interrupt_on_switch` убран; старый бэкап с этой настройкой
  восстанавливается.
- **MTU tun по умолчанию 9000 вместо 1492 ([задача 700](docs/spec/tasks/700-tun-mtu-default-9000.md)).**
  9000 — значение sing-box. Интерфейс туннеля виртуальный, ядро пересылает
  TCP по MTU настоящей сети, и малое значение только добавляло пакетов и
  работы процессору. Где MTU не меняли, 9000 встанет со следующей сборкой
  конфига; заданное вручную значение остаётся.
- **DNS-серверы, на которые есть ссылка, включаются.** Состояние из старых
  версий, где выключен DNS-сервер, на который ссылаются (член группы,
  резолвер домена, DNS Final, Default Domain Resolver), исправляется при
  запуске: сервер включается, причина пишется в лог приложения.
- **Маскировка AmneziaWG через detour.** С ядром lx.31 узел AWG с
  маскировочной пачкой (`ip=quic`, `i1`…) шлёт пачку, только когда
  подключается с собственного сокета устройства; через `detour` уходит
  обычное рукопожатие. Так такой узел поднимается через релей, который
  сниффит QUIC. Если узел AWG за detour после обновления ведёт себя иначе —
  сообщите.

## ✨ Новое

- **Узлы TrustTunnel и ссылки `tt://` ([задача 717](docs/spec/tasks/717-trusttunnel-deeplink-uri.md), issue #194).**
  Ссылка `tt://` (deep-link клиента AdGuard TrustTunnel) распознаётся при
  вставке из буфера, в списке ссылок и в подписке и становится узлом
  `trusttunnel`: первый адрес — сервер и порт, имя пользователя и пароль,
  HTTP/2 или HTTP/3 (QUIC), SNI, закреплённый сертификат, пропуск проверки.
  Android-ядро теперь включает TrustTunnel; раньше ядро отвергало такой
  узел, и приложение его выключало. Поля ссылки, которым в узле нет места
  (дополнительные адреса, DNS-апстримы, `anti_dpi`, client random),
  снимаются с предупреждением, узел остаётся. Пока не поддержано: ссылка,
  в которой только адрес подписки (`subscription_url`), снимается, а
  экспорт узла ссылкой `tt://` появится позже.
- **Taildrop: отправка и приём файлов через узел Tailscale
  ([задача 707](docs/spec/tasks/707-taildrop-send-receive-files.md)).** L×Box
  — цель «Поделиться» для файлов: они уходят на одно из ваших устройств
  tailnet в сети, с прогрессом и Cancel в уведомлении. Тап по устройству на
  вкладке Network открывает его страницу: Ping, Send file…, адреса (тап
  копирует); долгий тап по строке копирует первый адрес. Принятое ложится во
  входящие узла (Inbox) на вкладке Network с Save (в Downloads) и Delete; у
  уведомлений о приёме есть Cancel, Save и Delete. При включённом «Allow
  Taildrop» два переключателя узла включены по умолчанию: «Save received
  files to Downloads» (Android 10+) переносит туда всё принятое само, а
  «Accept clipboard and links from my devices» выполняет присланное вашими
  же устройствами. В Debug API есть `/taildrop/*`.
- **📋 Send: текст и ссылки на свои устройства
  ([задача 707](docs/spec/tasks/707-taildrop-send-receive-files.md#итерация-7--окно-send-clipboard-буфер-и-ссылки-с-телефона)).**
  «📋 Send» в уведомлении VPN открывает окно-чат поверх текущего приложения
  с текстом буфера в поле: ➤ кладёт его в буфер устройства, «Open on
  <device>» открывает там одну ссылку. Текст из «Поделиться» и пункт «Send to
  device» в меню выделения текста открывают то же окно. Окно хранит
  переписку с каждым устройством, пока работает VPN. На другой стороне —
  десктопный лаунчер или другой L×Box. Кнопка, «Поделиться» и «Send to
  device» есть, только пока VPN держит узел Tailscale с Allow Taildrop.
- **Узел Tailscale включается, выключается и перезапускается на ходу
  ([задача 706](docs/spec/tasks/706-tailscale-network-tab-logged-out.md)).**
  На вкладке Network есть Node enabled и Restart node; Turn off / Turn on в
  списке узлов работают и для Tailscale. Replace key входит новым ключом без
  перезапуска VPN.
- **Mixins ([задача 704](docs/spec/tasks/704-config-mixins.md)).**
  Config → Mixins хранит операции, которые применяются в конце каждой сборки
  конфига: путь цели (`route.rules[action=hijack-dns]`, `inbounds[tag=dns-in]`),
  глагол (append, prepend, before, after, set, merge, remove) и JSON-значение.
  Форма показывает, находит ли путь цель, и предпросмотр результата. В
  отличие от ручной правки с Lock config, миксин переживает пересборки, едет
  в LX Backup и доступен через Debug API (`/mixins`). Миксин, который не
  применяется или вносит дубль тега, останавливает сборку с его именем в
  сообщении. Пример: inbound `direct` на `127.0.0.1:5354` с правилом
  `hijack-dns` отдаёт DNS ядра другому приложению.
- **Сервер Hosts и Hosts у DNS-группы ([задача 699](docs/spec/tasks/699-dns-hosts-server-and-group-overlay.md), issue #185).**
  В редакторе DNS-сервера есть тип Hosts: имена с заданными адресами
  IPv4/IPv6, строка на имя, правка в диалоге. У DNS-группы под Members
  появился блок Hosts: имена, которые знают эти серверы, отвечаются сразу,
  остальные уходят участникам, как раньше. Такая группа в Default Domain
  Resolver даёт узлу с адресом `wg.home` ваши адреса, семейство выбирает
  `strategy`. Сервер hosts, на который ссылается группа, нельзя выключить и
  удалить. Переименование DNS-сервера теперь переписывает членов и Hosts
  групп; раньше переименованный член выпадал из группы.
- **Бюджет узлов ([задача 714](docs/spec/tasks/714-node-budget-subscription-cut.md), issue #190).**
  App Settings → General → Node budget: один лимит узлов на всё приложение
  (по умолчанию 1000, от 1, без верхнего предела). Ручные серверы и
  включённые члены папок идут первыми и не режутся никогда; остаток
  делится между включёнными подписками поровну, а то, что не нужно маленькой
  подписке, уходит остальным. Узлы, на которые ссылаются правило, цепочка или
  default-фильтр Направления, остаются первыми. Включение подписки, правка
  серверов или папок и смена бюджета перерезают подписки из кэша, без сети.
  Настройка едет в бэкапе и есть в Debug API (`/settings/node_budget`).
- **Parallel checks ([задача 713](docs/spec/tasks/713-ping-concurrency-setting.md), issue #192).**
  App Settings → General → Parallel checks задаёт, сколько серверов разом
  меряют массовый пинг и Test servers у папки (1–100, по умолчанию 10, с
  кнопкой сброса). Едет в бэкапе и есть в Debug API.
- **Регулярки в правилах маршрутизации ([задача 712](docs/spec/tasks/712-package-name-regex-domain-regex-rules.md), issue #193).**
  Правило принимает регулярку имени пакета (под пикером приложений) и
  регулярку домена (под Domain keyword), по шаблону Go RE2 на строку. Один
  шаблон вроде `^com\.oplus\.` заменяет выбор каждого системного пакета
  производителя. Удалённые правила `.srs` тоже принимают регулярку пакета.
- **Правила по типу сети и лимитным сетям ([задача 694](docs/spec/tasks/694-rule-network-type-metered.md), issue #178).**
  Секция Wi-Fi в редакторе правила стала «NETWORK»: Any / Wi-Fi / Cellular /
  Ethernet и флажок «Metered networks only» (мобильные данные и Wi-Fi,
  отмеченные в Android как лимитные). Ни то, ни другое не требует
  разрешения на геолокацию, как условие по SSID; список SSID виден только
  при Wi-Fi. Правило проверяется при открытии соединения: при переходе
  между Wi-Fi и мобильной сетью приложение сбрасывает соединения, новые
  идут по новой сети; если Android только меняет флаг лимитности, открытые
  соединения живут со старым решением.
- **VPN Settings → Core карточками
  ([задача 709](docs/spec/tasks/709-quic-sniff-decoy-toggle.md)).** General,
  Network, TUN, TLS Fragmentation, WireGuard и QUIC — отдельные карточки. У
  собственных настроек ядра (i) с короткой подсказкой.
  - **WireGuard** — четыре настройки сна и сборки, переехали с System.
    Строки, зависящие от сна, серые, пока он выключен.
  - **Network → Align MTU to the path** — Clamp (по умолчанию), Fill или Off:
    как узел поверх туннеля (detour, chain) получает влезающий в него размер
    пакета.
  - **QUIC → Anti-sniff decoy** — Off, Through detour (по умолчанию), Direct
    или All: один мусорный байт перед QUIC-рукопожатием MASQUE (HTTP/3),
    Hysteria2 и TUIC, чтобы релей со сниффингом UDP не перенаправил
    соединение по SNI. Серверы этот байт отбрасывают. По умолчанию байт
    получают только соединения поверх другого узла: DPI своего канала может
    на него среагировать.
  - **QUIC → MASQUE idle timeout** — по умолчанию Off; закрывает простаивающий
    туннель MASQUE, собственный таймаут узла сильнее.
- **UID в пикере приложений ([задача 693](docs/spec/tasks/693-app-picker-shared-uid-hint.md), issue #180).**
  Android разрешает нескольким пакетам делить один UID (на Samsung под UID
  1000 живут десятки системных приложений), а ядро и системный per-app VPN
  различают приложения по UID, поэтому правило или запись Tunnel apps на
  один пакет действует на всю группу. Строки пикера и Tunnel apps
  показывают «пакет · UID n»; у общего UID строка «Shared with N other apps —
  they are routed together» открывает список. Правила и Tunnel apps работают
  как раньше.
- **Ru internet segment: любой DNS-сервер Яндекса можно выключить ([задача 697](docs/spec/tasks/697-ru-direct-dns-servers-off.md), issue #183).**
  Рядом с «UDP server IP» появились «DoT server IP» и «DoH server IP», в
  каждом из трёх списков есть «Off»: этот сервер не используется и выходит
  из группы. Адрес задаёт профиль Яндекса (Базовый, Безопасный или
  Семейный) у DoT и DoH так же, как у UDP; раньше оба были закреплены за
  Безопасным. Если выключены все три, DNS пресета работает как при
  выключенном тумблере DNS. Значения по умолчанию прежние.
- **Полноэкранный подбор фильтра узлов в редакторе Направления ([задача 702](docs/spec/tasks/702-direction-node-filter-picker.md)).**
  Кнопка справа от Node filter открывает экран: поле regex с `!`, эмодзи из
  имён узлов с числом узлов у каждого (тап добавляет эмодзи в паттерн,
  повторный убирает) и полный список узлов: совпавшие сверху с ✓,
  остальные с ✗. ✓ в верхней панели возвращает паттерн в редактор.
- **Перестановка DNS-серверов ([задача 710](docs/spec/tasks/710-dns-servers-reorder.md)).**
  Серверы на вкладке DNS переставляются перетаскиванием за полосу слева от
  строки, как DNS-правила; порядок сохраняется в списке серверов шаблона.
- **URL-тест ядра в списке узлов ([задача 715](docs/spec/tasks/715-auto-twin-pool-label-core-delays.md), issue #191).**
  Пока туннель поднят, результаты собственного URL-теста ядра видны в
  списке узлов как чужой замер: бледные, с префиксом `~`, как замер из
  другого Направления. Свой пинг приложения важнее.
- **Память ядра в Statistics → Memory.** Цифра ядра показана как «Core
  memory» рядом с RSS процесса, с лимитом рядом, если выбрано число.
- **Debug API: выбранный узел каждой группы.** В `GET /state` добавлено поле
  `group_selected`: тег группы → узел, выбранный ядром, для каждой selector-
  и urltest-группы, а не только для Направления, открытого на главной.

## 🔄 Изменено

- **Шаблонные DNS-серверы и группы редактируются ([задача 695](docs/spec/tasks/695-dns-disabled-group-holds.md), issue #182).**
  В редакторе под переменными та же форма, что у своих серверов;
  изменённый сервер сохраняется своей копией под тем же тегом с пометкой
  «Overridden», «Reset to template» в меню ⋮ возвращает шаблонную версию.
  DNS Final, Default Domain Resolver, резолвер домена сервера и состав
  группы предлагают только включённые серверы. Сервер, на который есть
  ссылка, остаётся включённым и под замком. Добавление сервера из каталога
  добавляет и нужные ему серверы: участников группы и резолвер домена.
  Выключенную группу без включённых участников включить нельзя.
- **Кнопки уведомления VPN: Stop, «🔄 Restart» и «📋 Send»
  ([задача 707](docs/spec/tasks/707-taildrop-send-receive-files.md#итерация-8--кнопки-уведомления-vpn-restart-вернулся-список-в-настройках)).**
  Reconnect теперь называется «🔄 Restart». App Settings → General → Quick
  connect → VPN notification buttons выбирает, какие из трёх показаны; по
  умолчанию все. «📋 Send» есть, только пока у узла Tailscale включён Allow
  Taildrop.
- **App Settings → General и Diagnostics карточками ([задача 716](docs/spec/tasks/716-app-settings-islands.md)).**
  Каждая секция обеих вкладок — карточка со своим заголовком, как в VPN
  Settings. Сами настройки не менялись.
- **Настройки Taildrop и уведомления едут в бэкапе
  ([задача 707](docs/spec/tasks/707-taildrop-send-receive-files.md)).**
  Переключатели Taildrop узла и кнопки уведомления хранятся вместе с
  остальными настройками и восстанавливаются из бэкапа; режим темы
  приложения тоже попадает в бэкап. Разрешения Taildrop по устройствам из
  релиз-кандидатов сняты: присланное вашими же устройствами принимает
  переключатель узла.
- **Выделенный DNS-сервер в правиле включает «Resolve before routing»
  ([задача 711](docs/spec/tasks/711-ru-direct-resolve-always-dedicated-sets-resolve.md)).**
  Выбор выделенного DNS-сервера в редакторе правила включает и Resolve
  before routing с тем же сервером; галочку можно снять.

## 🐛 Исправлено

- **Ru internet segment резолвил свои домены резолвером по умолчанию при
  снятом Force IPv4 ([задача 711](docs/spec/tasks/711-ru-direct-resolve-always-dedicated-sets-resolve.md)).**
  Галочка снимала всё правило резолва, а не только стратегию IPv4, и при
  FakeIP выше пресета DNS-группа Яндекса не использовалась. Правило резолва
  теперь есть всегда; галочка управляет только семейством адресов.
- **FakeIP: фейковые IPv6-адреса нельзя было выключить ([задача 690](docs/spec/tasks/690-fakeip-custom-ranges.md), issue #181).**
  Опустошённый пул IPv6 не сохранялся: поле снова заполнялось `fc00::/18`.
  У пресета появился переключатель «Fake IPv6 addresses»; когда он выключен,
  запросы AAAA получают ответ без адреса, а пул IPv4 работает дальше.
- **Карточка Auto в Load balance показывала протокол вместо пула ([задача 715](docs/spec/tasks/715-auto-twin-pool-label-core-delays.md), issue #191).**
  Карточка теперь показывает `🔀 [N/M]` со значками пула или именами слотов,
  если значков нет ни у одного члена, — так же, как узел автовыбора.
- **Пир WireGuard/AWG показывал «connected», когда сервер не отвечал ([задача 613](docs/spec/tasks/613-wg-peers-tailscale-path-health.md)).**
  Пир был зелёным, пока последнему хендшейку меньше трёх минут, поэтому
  живыми выглядели новый сервер в группе, через которую идёт узел, не
  пропускающий трафик, и узел, который только что выключили и включили.
  Теперь пир, который шлёт, но около 8 секунд ничего не получает в ответ,
  оранжевый — «no response». После включения или пробуждения узла пир
  показывает «never connected» до нового хендшейка, а ↓/↑ считают только
  текущую сессию.
- **Остановка VPN зависала на узле MASQUE с detour.** Если такой узел
  (например, WARP поверх vless+ws) в этот момент пинговался или
  подключался, остановка его ждала; теперь незавершённое подключение
  отменяется.
- **Запуск падал с `initialize cache-file: timeout` после зависшей остановки ([задача 703](docs/spec/tasks/703-cache-db-lock-timeout-retry.md)).**
  Новое ядро само забирает `cache.db`, сохраняя выбор узлов в группах,
  FakeIP и кеш rule-set. Если и это не удалось, приложение удаляет файл и
  повторяет запуск один раз; force stop приложения и ручной сброс DNS-кэша
  больше не нужны.
- **Узел MASQUE, TrustTunnel, Hysteria2 или TUIC с detour на группу
  оставался на старом узле после переключения.** Туннель продолжал жить
  через прежний узел до конца сессии; теперь переключение в группе
  закрывает сессию, и следующее соединение идёт через новый узел (ядро
  lx.31).
- **Выбранный в мастере endpoint WARP подменялся ([задача 386](docs/spec/tasks/386-warp-endpoint-preset-combobox.md)).**
  Выбранный `engage.cloudflareclient.com:2408` больше не заменяется ни
  случайным IP при обфускации, ни адресом из ответа Cloudflare, ни
  endpoint'ом закешированной регистрации.
- **Route на экране узла не следил за селектором.** Если выбор группы на
  пути менялся не с этого экрана (на главной, через Debug API, после
  переселекта urltest), Route показывал старый выбор, пока экран не открыть
  заново. Теперь Route и галка в списке участников группы следуют за ядром.
- **Из Shield DNS нельзя было убрать сервер.** После 2.25.17 участники
  Shield DNS оставались под замком «used by Shield DNS», а саму группу
  нельзя было изменить (см. «Изменено» выше).
- **Вкладка Network узла Tailscale без входа могла стереть сохранённый exit
  node ([задача 706](docs/spec/tasks/706-tailscale-network-tab-logged-out.md)).**
  Вне Running вкладка показывает сохранённый exit node строкой и предлагает
  Replace key.
- **Строка узла прыгала по высоте во время пинга.** Строка узла без
  подзаголовка (например, `direct`) схлопывалась и раскрывалась вместе с
  бейджем пинга; теперь высота держится.

## 🔧 Под капотом

- Ядро `v1.14.4-lx.25` → `v1.14.4-lx.31`: ключ `hosts` у DNS-группы
  (Leadaxe/sing-box-lx#60); поправки выравнивания MTU (прокси-узел в группе
  больше не занижает MTU туннеля над группой, туннели с IPv6 не опускаются
  ниже 1280); статус пира WireGuard/AWG по сессиям; подключение MASQUE с
  detour отменяется при остановке; `cache.db` забирается у прежнего
  экземпляра, зависшего на остановке (Leadaxe/sing-box-lx#61); лимит памяти
  сравнивается с Go-рантаймом ядра (Leadaxe/sing-box-lx#62); вход новым
  ключом и включение/выключение эндпоинтов Tailscale без перезапуска,
  `disable_taildrop` и отправитель принятого файла (SPEC 149); обманка от
  сниффинга QUIC (SPEC 151). lx.31: TrustTunnel в Android-сборке
  (`with_trusttunnel`), маскировка AWG по пути (SPEC 153,
  Leadaxe/sing-box-lx#64), сессия туннеля с detour следует за селектором
  (SPEC 152), апстрим sing-box v1.14.4 + 9 коммитов (SPEC 154: установка
  DNS-транспорта больше не тормозит пакетный цикл TUN, OpenVPN/OpenConnect
  переоткрывают UDP при смене адресов).
- Контракт 1.1.140 → 1.1.160: узлы `trusttunnel` судит реестр (узел без
  `username`, `password` или `tls` снимается при разборе, как у лаунчера);
  импорт бэкапа сливает шаблонные и пользовательские DNS-серверы по тегу;
  `tcp_multi_path` во вставленном sing-box узле сохраняется как известное
  поле диалера; корневые ключи `lx` ядра — переменные шаблона, их пишет
  шаблон, имена те же, что у десктопного лаунчера; служебные файлы (буфер,
  ссылки) в одном формате у обеих сторон; настройки стороны устройства в
  бэкапе; `state_dir_id` узла Tailscale переживает бэкап без потерь.
- Секция разбора `tt://` живёт в черновике, пока реестр лаунчера не привезёт
  свою; коды предупреждений тогда могут быть переименованы.

</details>

---

## Install / Установка

```bash
adb install -r LxBox-v2.25.19-arm64-v8a.apk
```

Без uninstall! Поверх существующей установки. Настройки и подписки сохранятся.

No uninstall needed — install over the existing one. Settings and subscriptions
are preserved.

---

Previous release / Предыдущий релиз: [v2.25.18](docs/releases/v2.25.18.md).
