# L×Box v2.25.21

**A patch on top of [v2.25.20](https://github.com/Leadaxe/LxBox/releases/tag/v2.25.20).**

**Path MTU** on the direct node: the largest packet that passes your network
whole, and the MTU to set on WireGuard / AWG and MASQUE nodes. **Xray JSON**
nodes are saved on the Source tab as written. The home screen remembers the
**Direction** you picked. Android assistants can switch the VPN (Android 16+,
off by default). Core `v1.14.4-lx.33`, contract 1.1.167.

**Патч поверх [v2.25.20](https://github.com/Leadaxe/LxBox/releases/tag/v2.25.20).**

**Path MTU** у узла direct: самый большой пакет, который проходит вашу сеть
целиком, и MTU, который стоит задать узлам WireGuard / AWG и MASQUE. Узлы из
**Xray JSON** сохраняются на вкладке Source как написаны. Главный экран
помнит выбранное **Направление**. Ассистенты Android могут включать и
выключать VPN (Android 16+, по умолчанию выключено). Ядро `v1.14.4-lx.33`,
контракт 1.1.167.

---

<details open>
<summary><h2>🇬🇧 English</h2></summary>

## ⚠️ Read before updating

- **"Anti-sniff decoy" is off by default (core `v1.14.4-lx.33`, [task 709](docs/spec/tasks/709-quic-sniff-decoy-toggle.md)).**
  If you never touched the setting, the decoy byte is no longer sent. A mode
  you chose yourself is kept. Turn it on in VPN Settings → Core → QUIC if a
  relay that sniffs UDP redirects your MASQUE or AWG node.
- **The "AWG masquerade" setting is removed ([task 720](docs/spec/tasks/720-awg-masquerade-setting.md)).**
  The core dropped the option and sends the AmneziaWG masquerade packets on
  every path. A saved "Direct only" value no longer has any effect.

## ✨ New

- **Path MTU on the direct node ([task 725](docs/spec/tasks/725-path-mtu-direct-diagnostics.md)).**
  View details of `direct-out` → Diagnostics has a Path MTU card. It shows
  the network interface and its MTU, sends ping packets that may not be
  fragmented straight over the phone's network — past the tunnel, with the
  VPN on or off — and finds the largest packet that gets an answer. Under the
  result: the MTU to set on WireGuard / AWG nodes (`− 60`, `− 80` for an IPv6
  target) and on MASQUE nodes (`− 51`), the list of probes and a copy button.
  The target is `8.8.8.8` by default; ▾ lists well-known addresses, or type
  your own IP or host name. A port in the target is dropped — ping has no
  ports. The target has to answer ping. Debug API:
  `POST /action/pathmtu[?target=]`.

- **Android assistants can turn the VPN on or off and read its status ([task 721](docs/spec/tasks/721-appfunctions-vpn-toggle-status.md)).**
  On Android 16+ the app declares the AppFunctions `startVpn`, `stopVpn` and
  `getVpnStatus`. They work only after App Settings → Automation → "AI
  assistant control" is turned on (off by default, hidden below Android 16).
  Connecting needs a VPN permission granted earlier. The API is experimental:
  Gemini calls only apps from Google's early access programme for now.

- **Three more settings for "Anti-sniff decoy" ([task 709](docs/spec/tasks/709-quic-sniff-decoy-toggle.md)).**
  VPN Settings → Core → QUIC: "Decoy sending" (On retry / Always), "Decoy
  node types" and "Decoy relay types". The two type lists are picked from the
  core's own list: chosen types show as tags with ×, "Add ▾" offers the rest.

## 🔄 Changed

- **The node's Diagnostics tab is laid out in cards, and Endpoint takes your own address ([task 725](docs/spec/tasks/725-path-mtu-direct-diagnostics.md)).**
  Check and Notifications are separate cards. The Endpoint field is a combo
  box: ▾ fills in a ready check, or type any `http://` / `https://` URL.
- **The home screen opens on the Direction you picked last ([task 724](docs/spec/tasks/724-home-direction-remembered.md), [#212](https://github.com/Leadaxe/LxBox/issues/212)).**
  The choice survives an app restart and a VPN restart. If that Direction no
  longer exists, the first one in the list is shown.
- **Picking a value from a ▾ list no longer raises the keyboard.**

## 🐛 Fixed

- **A node from Xray JSON could not be saved on the Source tab ([task 722](docs/spec/tasks/722-origin-kind-dialect.md), [#209](https://github.com/Leadaxe/LxBox/issues/209)).**
  The dialect of a node's source (sing-box or Xray) is now stored with the
  record instead of being re-guessed from the text. An Xray source is kept as
  written and yields all its nodes — a `dialerProxy` relay becomes a separate
  node. Such a record shows `· N nodes` in Servers and a "Nodes in this
  source" list with a Tag field per node.
- **One server the core rejects no longer breaks the ping of the whole list ([task 723](docs/spec/tasks/723-probe-core-rejected-node.md)).**
  Such a server is left out and marked `core rejected: …` with the core's own
  text; the rest are measured.
- **Tunnel apps crashed on open with many installed apps ([task 693](docs/spec/tasks/693-app-picker-shared-uid-hint.md)).**
  The app list and icons are read off the main thread, icons are scaled down
  and requested only for the rows on screen.
- **A narrow tunnel showed ERR on every ping ([task 718](docs/spec/tasks/718-tunnel-routes-preset.md)).**
  A tunnel without a route to the internet (WireGuard / AWG with narrow
  allowed IPs, OpenVPN or OpenConnect with "Only its own networks") is no
  longer pinged and shows `no route`.

## 🔧 Under the hood

- Core `v1.14.4-lx.33`: `lx.quic_sniff_decoy` is an object
  `{mode, outbound_type, detour_type, send}`.
- Shared contract 1.1.167: `origin.kind` stores the dialect
  (`singbox` / `xray` / `uri` / `wg_ini`); an empty `text_list` in state
  beats the default.
- The app module builds with `compileSdk 37` and KSP
  (`androidx.appfunctions` 1.0.0-rc01).

</details>

<details open>
<summary><h2>🇷🇺 Русский</h2></summary>

## ⚠️ Прочтите до обновления

- **«Anti-sniff decoy» по умолчанию выключен (ядро `v1.14.4-lx.33`, [задача 709](docs/spec/tasks/709-quic-sniff-decoy-toggle.md)).**
  Если вы не трогали настройку, байт-обманка больше не отправляется.
  Выбранный вами режим сохраняется. Включите её в VPN Settings → Core → QUIC,
  если посредник, который разбирает UDP, перенаправляет ваш узел MASQUE или
  AWG.
- **Настройка «AWG masquerade» убрана ([задача 720](docs/spec/tasks/720-awg-masquerade-setting.md)).**
  Ядро сняло опцию и отправляет маскировочные пакеты AmneziaWG на любом
  пути. Сохранённое значение «Direct only» больше ни на что не влияет.

## ✨ Новое

- **Path MTU у узла direct ([задача 725](docs/spec/tasks/725-path-mtu-direct-diagnostics.md)).**
  View details узла `direct-out` → Diagnostics: карточка Path MTU. Она
  показывает сетевой интерфейс и его MTU, отправляет ping-пакеты с запретом
  фрагментации прямо через сеть телефона — мимо туннеля, при включённом и
  выключенном VPN — и находит самый большой пакет, на который приходит
  ответ. Под результатом: MTU для узлов WireGuard / AWG (`− 60`, для
  IPv6-цели `− 80`) и MASQUE (`− 51`), список проб и кнопка копирования.
  Цель по умолчанию `8.8.8.8`; ▾ — список известных адресов, либо введите
  свой IP или имя хоста. Порт в цели отбрасывается — у ping портов нет. Цель
  должна отвечать на ping. Debug API: `POST /action/pathmtu[?target=]`.

- **Ассистенты Android могут включать и выключать VPN и читать его статус ([задача 721](docs/spec/tasks/721-appfunctions-vpn-toggle-status.md)).**
  На Android 16+ приложение объявляет AppFunctions `startVpn`, `stopVpn` и
  `getVpnStatus`. Они работают только после включения App Settings →
  Automation → «AI assistant control» (по умолчанию выключено, ниже
  Android 16 скрыто). Для подключения нужно ранее выданное разрешение VPN.
  API экспериментальный: Gemini пока вызывает только приложения из
  программы раннего доступа Google.

- **Ещё три настройки «Anti-sniff decoy» ([задача 709](docs/spec/tasks/709-quic-sniff-decoy-toggle.md)).**
  VPN Settings → Core → QUIC: «Decoy sending» (On retry / Always), «Decoy
  node types» и «Decoy relay types». Оба списка типов выбираются из списка
  самого ядра: выбранные типы показаны тегами с ×, «Add ▾» предлагает
  остальные.

## 🔄 Изменено

- **Вкладка Diagnostics узла разложена на карточки, а Endpoint принимает свой адрес ([задача 725](docs/spec/tasks/725-path-mtu-direct-diagnostics.md)).**
  Check и Notifications — отдельные карточки. Поле Endpoint — комбобокс: ▾
  подставляет готовую проверку, либо введите любой URL `http://` /
  `https://`.
- **Главный экран открывается на Направлении, выбранном последним ([задача 724](docs/spec/tasks/724-home-direction-remembered.md), [#212](https://github.com/Leadaxe/LxBox/issues/212)).**
  Выбор переживает перезапуск приложения и VPN. Если такого Направления уже
  нет, показывается первое в списке.
- **Выбор значения из списка ▾ больше не поднимает клавиатуру.**

## 🐛 Исправлено

- **Узел из Xray JSON не сохранялся на вкладке Source ([задача 722](docs/spec/tasks/722-origin-kind-dialect.md), [#209](https://github.com/Leadaxe/LxBox/issues/209)).**
  Диалект источника узла (sing-box или Xray) теперь хранится в записи, а не
  угадывается заново по тексту. Источник Xray сохраняется как написан и даёт
  все свои узлы — посредник `dialerProxy` становится отдельным узлом. Такая
  запись показывает `· N nodes` в Servers и список «Nodes in this source» с
  полем Tag у каждого узла.
- **Один сервер, который отвергло ядро, больше не ломает пинг всего списка ([задача 723](docs/spec/tasks/723-probe-core-rejected-node.md)).**
  Такой сервер пропускается и получает отметку `core rejected: …` с текстом
  ядра; остальные замеряются.
- **Tunnel apps падал при открытии, когда установлено много приложений ([задача 693](docs/spec/tasks/693-app-picker-shared-uid-hint.md)).**
  Список приложений и иконки читаются вне главного потока, иконки
  уменьшаются и запрашиваются только для строк на экране.
- **Узкий туннель показывал ERR на каждом пинге ([задача 718](docs/spec/tasks/718-tunnel-routes-preset.md)).**
  Туннель без маршрута в интернет (WireGuard / AWG с узкими allowed IPs,
  OpenVPN или OpenConnect с «Only its own networks») больше не пингуется и
  показывает `no route`.

## 🔧 Под капотом

- Ядро `v1.14.4-lx.33`: `lx.quic_sniff_decoy` — объект
  `{mode, outbound_type, detour_type, send}`.
- Общий контракт 1.1.167: `origin.kind` хранит диалект
  (`singbox` / `xray` / `uri` / `wg_ini`); пустой `text_list` в состоянии
  побеждает значение по умолчанию.
- Модуль приложения собирается с `compileSdk 37` и KSP
  (`androidx.appfunctions` 1.0.0-rc01).

</details>

---

## Install / Установка

```bash
adb install -r LxBox-v2.25.21-arm64-v8a.apk
```

Без uninstall! Поверх существующей установки. Настройки и подписки сохранятся.

No uninstall needed — install over the existing one. Settings and subscriptions
are preserved.

---

Previous release / Предыдущий релиз: [v2.25.20](docs/releases/v2.25.20.md).
