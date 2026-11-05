# L×Box v2.25.20

**A patch on top of [v2.25.19](https://github.com/Leadaxe/LxBox/releases/tag/v2.25.19).**

**Tunnel routes**: a WireGuard / AWG, OpenVPN or OpenConnect tunnel can take
only the networks it announces and work alongside the selected server.
**AWG masquerade**: a new setting in VPN Settings → Core → WireGuard, and an
AWG node behind another node masquerades again. Core `v1.14.4-lx.32`,
contract 1.1.162.

**Патч поверх [v2.25.19](https://github.com/Leadaxe/LxBox/releases/tag/v2.25.19).**

**Tunnel routes**: туннель WireGuard / AWG, OpenVPN или OpenConnect может
брать только сети, которые сам объявляет, и работать рядом с выбранным
сервером. **AWG masquerade**: новая настройка в VPN Settings → Core →
WireGuard, а узел AWG за другим узлом снова маскируется. Ядро
`v1.14.4-lx.32`, контракт 1.1.162.

---

<details open>
<summary><h2>🇬🇧 English</h2></summary>

## ⚠️ Read before updating

- **AmneziaWG behind another node masquerades again (core `v1.14.4-lx.32`, [task 720](docs/spec/tasks/720-awg-masquerade-setting.md)).**
  In v2.25.19 an AWG node reached through another node (a `detour`) sent a
  single handshake packet without the masquerade packets (`ip=quic`, `i1`…).
  The core default is flipped back: the masquerade goes out on every path.
  "Anti-sniff decoy" (on for detours by default) keeps a relay that sniffs UDP
  from redirecting such a node by the SNI of the masquerade. To get the
  v2.25.19 behaviour, set VPN Settings → Core → WireGuard → "AWG masquerade"
  to "Direct only".

## ✨ New

- **Tunnel routes: a tunnel takes only its own networks ([task 718](docs/spec/tasks/718-tunnel-routes-preset.md)).**
  A WireGuard / AWG, OpenVPN or OpenConnect node gets the switch "Only its
  own networks" in its settings. With it the tunnel receives only the networks
  it announces — WireGuard allowed IPs, routes pushed by the OpenVPN or
  OpenConnect server — and works alongside the selected server; it does not
  have to be chosen as a direction. Everything else follows the other rules.
  For OpenVPN and OpenConnect the names the tunnel announces are resolved by
  the tunnel's own DNS (the "DNS" variable of the preset). The "Tunnel routes"
  preset is on by default and does nothing until the switch is set on a node.
  A tunnel that announces the default route takes all traffic; the node page
  warns about it.

- **"AWG masquerade" setting ([task 720](docs/spec/tasks/720-awg-masquerade-setting.md)).**
  VPN Settings → Core → WireGuard: "All paths" (default) sends the masquerade
  packets of an AmneziaWG node before the handshake on every path; "Direct
  only" sends them only when the node dials from the device's own socket, and
  through another node a single handshake packet goes out.

## 🔄 Changed

- **"Anti-sniff decoy" names AWG.** The tooltip, the (i) hint and the
  description of the QUIC section now say that the decoy also covers AWG
  nodes whose masquerade imitates QUIC (`ip=quic`).
- **"Direct" means a direct path through a group too.** For "AWG masquerade"
  and "Anti-sniff decoy" a detour to a group (selector / urltest) whose
  current choice is direct counts as direct; a group switched to a proxy
  counts as a detour from the next dial.

## 🔧 Under the hood

- **Core `v1.14.4-lx.31` → `v1.14.4-lx.32`.** The default of
  `lx.awg_masquerade` is `all`; no new keys of the root `lx` block; the Java
  surface and build tags are unchanged.
- **Contract 1.1.160 → 1.1.162.** The node record field `own_routes` and the
  `tunnel-routes` preset (1.1.161); the template variable `awg_masquerade`
  (1.1.162, mobile only).
- **F-Droid build watch ([task 719](docs/spec/tasks/719-fdroid-mr-watch.md)).**
  A daily CI job checks the build of our merge request in fdroiddata and
  reopens the issue when it fails.
- Not verified on a device or emulator: the new core, "AWG masquerade" and
  "Only its own networks".

</details>

<details open>
<summary><h2>🇷🇺 Русский</h2></summary>

## ⚠️ Прочтите до обновления

- **AmneziaWG за другим узлом снова маскируется (ядро `v1.14.4-lx.32`, [задача 720](docs/spec/tasks/720-awg-masquerade-setting.md)).**
  В v2.25.19 узел AWG, идущий через другой узел (`detour`), отправлял один
  пакет рукопожатия без маскировочных пакетов (`ip=quic`, `i1`…). Дефолт ядра
  возвращён: маскировка уходит на любом пути. «Anti-sniff decoy» (для detour
  включён по умолчанию) не даёт релею, который сниффит UDP, перенаправить
  такой узел по SNI маскировки. Поведение v2.25.19 возвращает VPN Settings →
  Core → WireGuard → «AWG masquerade» → «Direct only».

## ✨ Новое

- **Tunnel routes: туннель берёт только свои сети ([задача 718](docs/spec/tasks/718-tunnel-routes-preset.md)).**
  У узла WireGuard / AWG, OpenVPN или OpenConnect в настройках появился
  переключатель «Only its own networks». С ним туннель получает только сети,
  которые сам объявляет — allowed IPs у WireGuard, маршруты, присланные
  сервером OpenVPN или OpenConnect, — и работает рядом с выбранным сервером;
  выбирать его Направлением не нужно. Всё остальное идёт по прочим правилам.
  У OpenVPN и OpenConnect имена, которые объявляет туннель, резолвит DNS
  самого туннеля (переменная «DNS» пресета). Пресет «Tunnel routes» включён
  по умолчанию и ничего не делает, пока переключатель не поставлен на узле.
  Туннель, объявляющий маршрут по умолчанию, забирает весь трафик; страница
  узла об этом предупреждает.

- **Настройка «AWG masquerade» ([задача 720](docs/spec/tasks/720-awg-masquerade-setting.md)).**
  VPN Settings → Core → WireGuard: «All paths» (по умолчанию) — маскировочные
  пакеты узла AmneziaWG уходят перед рукопожатием на любом пути; «Direct
  only» — только когда узел звонит с собственного сокета устройства, а через
  другой узел идёт один пакет рукопожатия.

## 🔄 Изменено

- **«Anti-sniff decoy» называет AWG.** Тултип, подсказка (i) и описание
  секции QUIC теперь говорят, что обманка действует и на узлы AWG с
  маскировкой под QUIC (`ip=quic`).
- **«Direct» — это и прямой путь через группу.** Для «AWG masquerade» и
  «Anti-sniff decoy» detour на группу (selector / urltest), в которой сейчас
  выбран direct, считается прямым путём; группа, переключённая на прокси,
  считается detour со следующего дозвона.

## 🔧 Под капотом

- **Ядро `v1.14.4-lx.31` → `v1.14.4-lx.32`.** Дефолт `lx.awg_masquerade` —
  `all`; новых ключей корневого блока `lx` нет; Java-интерфейс и build-теги
  без изменений.
- **Контракт 1.1.160 → 1.1.162.** Поле записи узла `own_routes` и пресет
  `tunnel-routes` (1.1.161); переменная шаблона `awg_masquerade` (1.1.162,
  только мобильная сторона).
- **Сторож сборки F-Droid ([задача 719](docs/spec/tasks/719-fdroid-mr-watch.md)).**
  Суточная джоба CI проверяет сборку нашего merge request в fdroiddata и
  переоткрывает issue, если она упала.
- Не проверено на устройстве и эмуляторе: новое ядро, «AWG masquerade» и
  «Only its own networks».

</details>

---

## Install / Установка

```bash
adb install -r LxBox-v2.25.20-arm64-v8a.apk
```

Без uninstall! Поверх существующей установки. Настройки и подписки сохранятся.

No uninstall needed — install over the existing one. Settings and subscriptions
are preserved.

---

Previous release / Предыдущий релиз: [v2.25.19](docs/releases/v2.25.19.md).
