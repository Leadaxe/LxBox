# L×Box v2.25.12-rc.2

**The second release candidate on top of [v2.25.11](https://github.com/Leadaxe/LxBox/releases/tag/v2.25.11).**

This is a pre-release on GitHub; in Google Play it goes to Open testing. It is
not offered to users of the stable release. It contains everything from
[v2.25.12-rc.1](https://github.com/Leadaxe/LxBox/releases/tag/v2.25.12-rc.1);
below are the changes since rc.1.

Every JSON field and the config editor now run on a native Android editor:
the keyboard no longer covers the text, keyboard arrows and Copy work. Your
own WireGuard/AmneziaWG nodes get a Masquerade section. A new intent re-tests
every Direction at once. The core moves to the stable `v1.14.3-lx.15`.

**Второй релиз-кандидат поверх [v2.25.11](https://github.com/Leadaxe/LxBox/releases/tag/v2.25.11).**

На GitHub это pre-release, в Google Play сборка уходит в открытое
тестирование. Пользователям стабильного релиза она не предлагается. В нём
всё из [v2.25.12-rc.1](https://github.com/Leadaxe/LxBox/releases/tag/v2.25.12-rc.1);
ниже — изменения относительно rc.1.

Все JSON-поля и редактор конфига переведены на нативный редактор Android:
клавиатура больше не закрывает текст, стрелки и Copy клавиатуры работают. У
своих узлов WireGuard/AmneziaWG появилась секция Masquerade. Новый интент
перепроверяет все Направления разом. Ядро — стабильное `v1.14.3-lx.15`.

---

<details open>
<summary><h2>🇬🇧 English</h2></summary>

## ⚠️ Read before updating

- **Core `v1.14.3-lx.15` (from `v1.14.2-lx.13-rc.1` in rc.1, base sing-box 1.14.3, [docs/KERNEL.md](docs/KERNEL.md)).**
  Everything rc.1 brought to the AWG masquerade (`ip=quic` decoy fresh on
  every handshake, real QUIC ClientHellos for `ib=chrome` / `ib=firefox`)
  stays. New in this core:
  - Auto groups test their nodes on every `interval`. Before, a node was
    probed once per two intervals; with the default 15 minutes that means
    twice as many background probes as before.
  - Hold until failure also leaves a node that answers but is more than
    twice as slow as the others.
  - `fingerprint: random` / `randomized` no longer leave REALITY nodes to
    Xray v26.9.8 and newer dead until restart.
  - Hysteria2, TUIC and WireGuard on top of WARP (MASQUE) or another IP
    tunnel get a packet size that fits the tunnel, so hysteria2 over WARP to
    an IPv6 server works.
  - MASQUE `vhttp: auto` no longer stays on h2 until restart after one
    quick h3 failure.
  - uTLS/REALITY connections hold 18–25 KB less memory; gRPC is updated for
    a critical advisory.
- **XHTTP nodes with a `?…` tail in `path` get a new content hash.**
  Their config is marked changed once; node selection and disabled marks are
  kept.

## ✨ Added

- **Masquerade section for your own WireGuard/AmneziaWG node.**
  The node's Settings tab has Masquerade: protocol (Off, QUIC, DNS, STUN,
  SIP), domain and browser, as rows like Detour server. A choice is saved at
  once: `ip`/`id`/`ib` go into the node's source (a link, a `.conf` or a
  sing-box body), the rest of the text stays as it was. Turning on QUIC, DNS
  or SIP fills a random domain from the pool; the dice picks another, the
  arrow lists the pool. QUIC needs a domain (it becomes the SNI of the decoy
  ClientHello) and defaults to the Chrome profile. A node that sets `I1`
  itself keeps it: the section is off and says why. Packed links (`awg://`
  base64, `vpn://`) and Xray sources are not written to. The WARP wizard
  uses the same fields; its QUIC hint no longer calls the domain cosmetic.
- **One intent re-tests every Direction.**
  `com.leadaxe.lxbox.URLTEST_ALL` takes no extras and runs the URL test of
  every Direction's auto group in turn; the core re-selects a live node in
  each. The same command is `urltest-all` in the Tasker/Locale plugin and
  `POST /action/urltest-all` in the Debug API. Handy on a MacroDroid shake
  gesture when the network goes stale.

## 🔄 Changed

- **JSON fields run on a native Android editor.**
  The config editor and every JSON field (node Source and JSON, rules, DNS,
  the add-server wizard, subscription Source) use a native editor now. The
  keyboard no longer covers the line with the cursor. The arrows of
  Unexpected Keyboard and Hacker's Keyboard move the cursor instead of
  closing the keyboard. The keyboard's Copy takes the whole multi-line
  selection. The selection menu follows the app language. Fields that take
  anything highlight WireGuard `.conf` and links as well as JSON. Search on
  Config works as before. The config editor and the add-server wizard no
  longer open the keyboard on their own. On a TV the D-pad moves into the
  field and OK opens the keyboard. The editor works on Android 7 as well.
- **Pinned block headers instead of folding.**
  Block folding is gone. Instead, up to three lines of the enclosing blocks
  stay pinned at the top while you scroll the config, the node JSON and a
  JSON subscription Source. For that the config editor no longer wraps long
  lines: they scroll sideways.

## 🩹 Fixed

- **XHTTP keeps the query part of `path`.**
  A path like `/?proxyip=…` (Cloudflare Worker relays) lost its `?…` tail on
  import, so the relay never got its parameter and sites behind Cloudflare
  failed with 502. The path now goes to the core verbatim, as in Xray, and
  the core sends the tail as the request query. Applies to share links, Xray
  JSON and sing-box JSON. Nodes of one server that differ only in the path
  query are no longer merged into one.
- **Tailscale Network tab: the exit device is back under Devices.**
  In v2.25.11 the chosen exit node was shown only in the Exit node block,
  which has no row menu, so it could not be pinged or copied. It is listed
  under Devices again with its status and path.

## 🔧 Under the hood

- Core `v1.14.3-lx.15`; the Java surface of the core is unchanged for the
  app.
- Contract 1.1.115 (from 1.1.114).
- The APK is about 2 MB larger: the native editor and its highlighting
  grammars.
- CI: `actions/checkout` v7, `actions/download-artifact` v8.

</details>

<details open>
<summary><h2>🇷🇺 Русский</h2></summary>

## ⚠️ Прочтите до обновления

- **Ядро `v1.14.3-lx.15` (в rc.1 было `v1.14.2-lx.13-rc.1`, база sing-box 1.14.3, [docs/KERNEL.md](docs/KERNEL.md)).**
  Всё, что rc.1 принёс в маскировку AWG (decoy `ip=quic` свежий на каждом
  хендшейке, настоящие QUIC ClientHello у `ib=chrome` / `ib=firefox`),
  остаётся. Новое в этом ядре:
  - Авто-группы проверяют узлы каждый `interval`. Раньше узел проверялся
    раз в два интервала; при стандартных 15 минутах фоновых проверок
    становится вдвое больше.
  - Hold until failure уходит и с узла, который отвечает, но вдвое
    медленнее остальных.
  - `fingerprint: random` / `randomized` больше не глушат до перезапуска
    узлы REALITY к Xray v26.9.8 и новее.
  - Hysteria2, TUIC и WireGuard поверх WARP (MASQUE) или другого
    IP-туннеля получают размер пакета, который туннель пропускает, —
    hysteria2 поверх WARP к серверу на IPv6 работает.
  - MASQUE `vhttp: auto` больше не застревает на h2 до перезапуска после
    одного быстрого отказа h3.
  - Соединения uTLS/REALITY держат на 18–25 КБ меньше памяти; gRPC обновлён
    по критической уязвимости.
- **У узлов XHTTP с хвостом `?…` в `path` меняется хеш содержимого.**
  Их конфиг один раз помечается изменившимся; выбор узла и отметки
  отключения сохраняются.

## ✨ Добавлено

- **Секция Masquerade у своего узла WireGuard/AmneziaWG.**
  На вкладке Settings узла появилась Masquerade: протокол (Off, QUIC, DNS,
  STUN, SIP), домен и браузер — строками, как Detour server. Выбор
  сохраняется сразу: `ip`/`id`/`ib` пишутся в источник узла (ссылку,
  `.conf` или тело sing-box), остальной текст не меняется. При включении
  QUIC, DNS или SIP подставляется случайный домен из пула; кубик выбирает
  другой, стрелка показывает весь пул. QUIC требует домен (он становится
  SNI decoy-ClientHello) и по умолчанию берёт профиль Chrome. Узел, где `I1`
  задан явно, сохраняет его: секция выключена и объясняет почему. Упакованные
  ссылки (`awg://` в base64, `vpn://`) и источники Xray не переписываются.
  Мастер WARP использует те же поля; его подсказка к QUIC больше не называет
  домен косметикой.
- **Один интент перепроверяет все Направления.**
  `com.leadaxe.lxbox.URLTEST_ALL` без extras по очереди запускает URL-тест
  авто-группы каждого Направления; ядро в каждой переключается на живой
  узел. Та же команда — `urltest-all` в плагине Tasker/Locale и
  `POST /action/urltest-all` в Debug API. Удобно повесить на встряхивание в
  MacroDroid, когда сеть подвисла.

## 🔄 Изменено

- **JSON-поля на нативном редакторе Android.**
  Редактор конфига и все JSON-поля (Source и JSON узла, правила, DNS, мастер
  добавления сервера, Source подписки) работают на нативном редакторе.
  Клавиатура больше не закрывает строку с курсором. Стрелки Unexpected
  Keyboard и Hacker's Keyboard двигают курсор, а не сворачивают клавиатуру.
  Copy клавиатуры копирует всё многострочное выделение. Меню выделения — на
  языке приложения. Поля, принимающие что угодно, подсвечивают, кроме JSON,
  `.conf` WireGuard и ссылки. Поиск на Config работает как прежде. Редактор
  конфига и мастер добавления сервера больше не открывают клавиатуру сами.
  На ТВ D-pad заходит в поле, OK открывает клавиатуру. Редактор работает и
  на Android 7.
- **Закреплённые заголовки блоков вместо свёртки.**
  Свёртки блоков больше нет. Вместо неё при прокрутке конфига, JSON узла и
  JSON-Source подписки сверху закреплены до трёх строк охватывающих блоков.
  Поэтому редактор конфига больше не переносит длинные строки — они
  прокручиваются вбок.

## 🩹 Исправлено

- **XHTTP сохраняет query в `path`.**
  Путь вида `/?proxyip=…` (релеи Cloudflare Worker) при импорте терял хвост
  `?…`: релей не получал свой параметр, и сайты за Cloudflare отвечали 502.
  Теперь путь уходит в ядро дословно, как в Xray, а ядро отправляет хвост
  как query запроса. Касается ссылок, Xray JSON и sing-box JSON. Узлы одного
  сервера, различающиеся только query пути, больше не схлопываются в один.
- **Вкладка Network у Tailscale: выходное устройство снова в Devices.**
  В v2.25.11 выбранный exit node показывался только в блоке Exit node, где
  нет меню строки, поэтому его нельзя было пинговать или скопировать. Теперь
  он снова в списке Devices со статусом и путём.

## 🔧 Под капотом

- Ядро `v1.14.3-lx.15`; Java-поверхность ядра для приложения не изменилась.
- Контракт 1.1.115 (было 1.1.114).
- APK вырос примерно на 2 МБ: нативный редактор и грамматики подсветки.
- CI: `actions/checkout` v7, `actions/download-artifact` v8.

</details>

---

## Install / Установка

```bash
adb install -r LxBox-v2.25.12-rc.2-arm64-v8a.apk
```

Без uninstall! Поверх существующей установки. Настройки и подписки сохранятся.

No uninstall needed — install over the existing one. Settings and subscriptions
are preserved.

---

Previous release / Предыдущий релиз: [v2.25.12-rc.1](https://github.com/Leadaxe/LxBox/releases/tag/v2.25.12-rc.1) · stable / стабильный: [v2.25.11](docs/releases/v2.25.11.md).
