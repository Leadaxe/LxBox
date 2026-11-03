# L×Box v2.25.19-rc.3

**The third release candidate on top of [v2.25.18](https://github.com/Leadaxe/LxBox/releases/tag/v2.25.18).**

This is a pre-release on GitHub; in Google Play it goes to Open testing. It is
not offered to users of the stable release. It contains everything from
[v2.25.19-rc.2](https://github.com/Leadaxe/LxBox/releases/tag/v2.25.19-rc.2);
below are the changes since rc.2.

**Taildrop**: send and receive files over a Tailscale node, and «Send
clipboard» from the VPN notification. VPN Settings →
Core is rebuilt as cards, with new WireGuard, MTU and QUIC settings. Core
`v1.14.4-lx.30`.

**Третий релиз-кандидат поверх [v2.25.18](https://github.com/Leadaxe/LxBox/releases/tag/v2.25.18).**

На GitHub это pre-release, в Google Play сборка уходит в открытое
тестирование. Пользователям стабильного релиза она не предлагается. В нём
всё из [v2.25.19-rc.2](https://github.com/Leadaxe/LxBox/releases/tag/v2.25.19-rc.2);
ниже — изменения относительно rc.2.

**Taildrop** — отправка и приём файлов через узел Tailscale и «Send
clipboard» из уведомления VPN. VPN Settings →
Core переделан карточками, в нём новые настройки WireGuard, MTU и QUIC. Ядро
`v1.14.4-lx.30`.

---

<details open>
<summary><h2>🇬🇧 English</h2></summary>

## ⚠️ Read before updating

- **Taildrop is off on every Tailscale node, existing ones included
  ([task 707](docs/spec/tasks/707-taildrop-send-receive-files.md)).** A node
  receives and sends files only after «Allow Taildrop» is turned on in its
  settings; it takes effect after the VPN restarts.
- **The VPN notification has no Reconnect button
  ([task 707](docs/spec/tasks/707-taildrop-send-receive-files.md#итерация-7--окно-send-clipboard-буфер-и-ссылки-с-телефона)).** Its buttons are Stop and
  «📋 Send clipboard»; Reconnect stays in the ⟳ menu on the home screen.
- **WireGuard sleep settings moved to VPN Settings → Core and start from the
  defaults ([task 709](docs/spec/tasks/709-quic-sniff-decoy-toggle.md)).**
  Suspend idle tunnels 30 seconds, Suspend active-route tunnels 5 minutes,
  Lazy tunnel build on, Built tunnels limit 5. Values chosen earlier on the
  System tab are not carried over: set them again if they differed.

## ✨ New

- **Taildrop: send and receive files over a Tailscale node
  ([task 707](docs/spec/tasks/707-taildrop-send-receive-files.md)).** L×Box
  is a Share target for files: they go to one of your online devices in the
  tailnet, with progress and Cancel in a notification. A tap on a device on
  the Network tab opens its page: Ping, Send file…, addresses (a tap copies)
  and the device's permissions; a long tap on the row copies its first
  address. Received files land in the node's Inbox on the Network tab with
  Save (to Downloads) and Delete; «Save received files to Downloads» moves
  every received file there by itself (Android 10+). The Debug API has
  `/taildrop/*`.
- **Send clipboard: text and links to your devices
  ([task 707](docs/spec/tasks/707-taildrop-send-receive-files.md#итерация-7--окно-send-clipboard-буфер-и-ссылки-с-телефона)).** «📋 Send clipboard» in the
  VPN notification opens a chat-like window over the current app with the
  clipboard text in the field: ➤ puts it into the device's clipboard, «Open
  on <device>» opens a single link there. Shared text and «Send to device» in
  the text selection menu open the same window. The window keeps the exchange
  with each device while the VPN runs. The other side is the desktop launcher
  or another L×Box; what they send runs only from devices allowed on the
  device page (Clipboard from this device, Links from this device; off by
  default). The button, Share and «Send to device» appear only while the VPN
  runs a Tailscale node with Allow Taildrop.
- **Tailscale node on/off and restart on the fly
  ([task 706](docs/spec/tasks/706-tailscale-network-tab-logged-out.md)).**
  The Network tab has Node enabled and Restart node; Turn off / Turn on in the
  node list works for Tailscale nodes too. Replace key signs the node in with
  the new key without restarting the VPN.
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

## 🐞 Fixed

- **The Network tab of a signed-out Tailscale node could erase the saved exit
  node ([task 706](docs/spec/tasks/706-tailscale-network-tab-logged-out.md)).**
  Outside Running the tab now shows the saved exit node as a line and offers
  Replace key.

## 🔧 Under the hood

- Core `v1.14.4-lx.29` → `v1.14.4-lx.30`: sign-in with a new key and
  on/off for Tailscale endpoints without a restart, `disable_taildrop` and the
  sender of a received file (SPEC 149), the QUIC sniff decoy (SPEC 151).
- Contract 1.1.152 → 1.1.156: the core's root `lx` keys are template
  variables written by the template, the same names on the desktop launcher;
  command files (clipboard, links) in one format on both sides.

</details>

<details open>
<summary><h2>🇷🇺 Русский</h2></summary>

## ⚠️ Прочтите до обновления

- **Taildrop выключен на каждом узле Tailscale, включая существующие
  ([задача 707](docs/spec/tasks/707-taildrop-send-receive-files.md)).** Узел
  принимает и отправляет файлы только после включения «Allow Taildrop» в его
  настройках; действует после перезапуска VPN.
- **В уведомлении VPN нет кнопки Reconnect
  ([задача 707](docs/spec/tasks/707-taildrop-send-receive-files.md#итерация-7--окно-send-clipboard-буфер-и-ссылки-с-телефона)).** Кнопки — Stop и
  «📋 Send clipboard»; Reconnect остался в меню ⟳ на главном экране.
- **Настройки сна WireGuard переехали в VPN Settings → Core и начинают с
  дефолтов ([задача 709](docs/spec/tasks/709-quic-sniff-decoy-toggle.md)).**
  Suspend idle tunnels 30 секунд, Suspend active-route tunnels 5 минут, Lazy
  tunnel build включена, Built tunnels limit 5. Значения, выбранные раньше на
  вкладке System, не переносятся: если они отличались, выставьте заново.

## ✨ Новое

- **Taildrop: отправка и приём файлов через узел Tailscale
  ([задача 707](docs/spec/tasks/707-taildrop-send-receive-files.md)).** L×Box
  — цель «Поделиться» для файлов: они уходят на одно из ваших устройств
  tailnet в сети, с прогрессом и Cancel в уведомлении. Тап по устройству на
  вкладке Network открывает его страницу: Ping, Send file…, адреса (тап
  копирует) и разрешения устройства; долгий тап по строке копирует первый
  адрес. Принятое ложится во входящие узла на вкладке Network с Save (в
  Downloads) и Delete; «Save received files to Downloads» переносит туда всё
  принятое само (Android 10+). В Debug API есть `/taildrop/*`.
- **Send clipboard: текст и ссылки на свои устройства
  ([задача 707](docs/spec/tasks/707-taildrop-send-receive-files.md#итерация-7--окно-send-clipboard-буфер-и-ссылки-с-телефона)).** «📋 Send clipboard» в
  уведомлении VPN открывает окно-чат поверх текущего приложения с текстом
  буфера в поле: ➤ кладёт его в буфер устройства, «Open on <device>»
  открывает там одну ссылку. Текст из «Поделиться» и пункт «Send to device»
  в меню выделения текста открывают то же окно. Окно хранит переписку с
  каждым устройством, пока работает VPN. На другой стороне — десктопный
  лаунчер или другой L×Box; присланное ими выполняется только с устройств,
  разрешённых на странице устройства (Clipboard from this device, Links from
  this device; по умолчанию выключены). Кнопка, «Поделиться» и «Send to
  device» есть, только пока VPN держит узел Tailscale с Allow Taildrop.
- **Узел Tailscale включается, выключается и перезапускается на ходу
  ([задача 706](docs/spec/tasks/706-tailscale-network-tab-logged-out.md)).**
  На вкладке Network есть Node enabled и Restart node; Turn off / Turn on в
  списке узлов работают и для Tailscale. Replace key входит новым ключом без
  перезапуска VPN.
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

## 🐞 Исправлено

- **Вкладка Network узла Tailscale без входа могла стереть сохранённый exit
  node ([задача 706](docs/spec/tasks/706-tailscale-network-tab-logged-out.md)).**
  Вне Running вкладка показывает сохранённый exit node строкой и предлагает
  Replace key.

## 🔧 Под капотом

- Ядро `v1.14.4-lx.29` → `v1.14.4-lx.30`: вход новым ключом и
  включение/выключение эндпоинтов Tailscale без перезапуска,
  `disable_taildrop` и отправитель принятого файла (SPEC 149), обманка от
  сниффинга QUIC (SPEC 151).
- Контракт 1.1.152 → 1.1.156: корневые ключи `lx` ядра — переменные
  шаблона, их пишет шаблон, имена те же, что у десктопного лаунчера;
  служебные файлы (буфер, ссылки) в одном формате у обеих сторон.

</details>

---

## Install / Установка

```bash
adb install -r LxBox-v2.25.19-rc.3-arm64-v8a.apk
```

Без uninstall! Поверх существующей установки. Настройки и подписки сохранятся.

No uninstall needed — install over the existing one. Settings and subscriptions
are preserved.

---

Previous release / Предыдущий релиз: [v2.25.19-rc.2](https://github.com/Leadaxe/LxBox/releases/tag/v2.25.19-rc.2) · stable / стабильный: [v2.25.18](docs/releases/v2.25.18.md).
