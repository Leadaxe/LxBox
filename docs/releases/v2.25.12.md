# L×Box v2.25.12

**A patch on top of [v2.25.11](https://github.com/Leadaxe/LxBox/releases/tag/v2.25.11).**

Every JSON field and the config editor now run on a native Android editor:
the keyboard no longer covers the text, keyboard arrows and Copy work, and
JSON fields get a Format button. Every screen with a Save button asks before
dropping unsaved edits. Your own WireGuard/AmneziaWG nodes get a Masquerade
section. A new intent re-tests every Direction at once. Direct connections
get a configurable connect timeout. REALITY nodes no longer get the global
TLS fragmentation. Core `v1.14.3-lx.15`, contract 1.1.115.

**Патч поверх [v2.25.11](https://github.com/Leadaxe/LxBox/releases/tag/v2.25.11).**

Все JSON-поля и редактор конфига переведены на нативный редактор Android:
клавиатура больше не закрывает текст, стрелки и Copy клавиатуры работают, у
JSON-полей появилась кнопка Format. Все экраны с кнопкой Save спрашивают,
прежде чем потерять несохранённые правки. У своих узлов WireGuard/AmneziaWG
появилась секция Masquerade. Новый интент перепроверяет все Направления
разом. У прямых соединений настраиваемый таймаут. Глобальная фрагментация
TLS больше не применяется к узлам REALITY. Ядро `v1.14.3-lx.15`, контракт
1.1.115.

---

<details open>
<summary><h2>🇬🇧 English</h2></summary>

## ⚠️ Read before updating

- **Core `v1.14.3-lx.15` (from `v1.14.2-lx.12`, base sing-box 1.14.3, [docs/KERNEL.md](docs/KERNEL.md)).**
  - AWG masquerade `ip=quic` (WARP wizard nodes and any node with
    `ip=quic`): the decoy is generated before every handshake, a new QUIC
    Initial with fresh connection IDs on each start, rekey, wake and
    reconnect. Before, the node sent the same datagram with the same DCID
    for its whole lifetime.
  - `ib=chrome` and `ib=firefox` are real QUIC ClientHellos of the browser,
    calibrated against Chrome 147/155 and Firefox 149 captures. Before, a
    TCP ClientHello sat inside the QUIC Initial.
  - `ip=sip` sends only INVITE; `ip=dns` sends EDNS without options.
  - The core value `ib=chrome-full` is experimental and not offered: a node
    with it gets the value dropped with a warning.
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
- **The config editor no longer wraps long lines.**
  They scroll sideways; in exchange the headers of the enclosing blocks stay
  pinned while you scroll (see Changed).

## ✨ Added

- **Masquerade section for your own WireGuard/AmneziaWG node ([task 623](docs/spec/tasks/623-node-masquerade-section.md)).**
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
- **One intent re-tests every Direction ([task 625](docs/spec/tasks/625-urltest-all-intent.md)).**
  `com.leadaxe.lxbox.URLTEST_ALL` takes no extras and runs the URL test of
  every Direction's auto group in turn; the core re-selects a live node in
  each. The same command is `urltest-all` in the Tasker/Locale plugin and
  `POST /action/urltest-all` in the Debug API. Handy on a MacroDroid shake
  gesture when the network goes stale.
- **Direct connect timeout for `direct-out` ([task 616](docs/spec/tasks/616-direct-connect-timeout.md)).**
  The connect timeout of the direct outbound is a setting now: Traffic
  Processing → Params → Direct connect timeout, presets 5s–2m or any
  duration. The default is 15s instead of the core's 5s, so apps on networks
  that lose SYN packets (e.g. T-Bank over Tele2) no longer get their
  connections cut. Proxy nodes and auto groups are unchanged.
- **Format button for JSON fields ([task 624](docs/spec/tasks/624-sora-editor-for-json-fields.md)).**
  Editable JSON fields (node Source, Edit server in a folder, DNS server
  JSON, rule JSON, the DNS rule editor, the wizard's JSON field) have a
  Format button: it parses the text as JSON5, like Save on Config, and lays
  it out with a two-space indent. Undo reverts it. A parse error shows the
  position and leaves the text alone; if the text has comments, a dialog
  warns that they will be removed.

## 🔄 Changed

- **JSON fields run on a native Android editor ([task 624](docs/spec/tasks/624-sora-editor-for-json-fields.md)).**
  The config editor and every JSON field (node Source and JSON, rules, DNS,
  the add-server wizard, subscription Source) use a native editor now. The
  keyboard no longer covers the line with the cursor. The arrows of
  Unexpected Keyboard and Hacker's Keyboard move the cursor instead of
  closing the keyboard. The keyboard's Copy takes the whole multi-line
  selection. The selection menu follows the app language. Fields that take
  anything highlight WireGuard `.conf` and links as well as JSON. The config
  editor and the add-server wizard no longer open the keyboard on their own.
  On a TV the D-pad moves into the field and OK opens the keyboard. The
  editor works on Android 7 as well.
- **Pinned block headers instead of folding.**
  Block folding is gone. Instead, up to three lines of the enclosing blocks
  stay pinned at the top while you scroll the config, the node JSON and a
  JSON subscription Source.
- **Field buttons above the field.**
  Find, Copy and Format sit in a row above the field, next to its caption,
  instead of over the text. A field that grows with its text counts wrapped
  lines, so a one-line compact JSON grows to the field's limit. Wrapped
  fields no longer shade the whole field as the current line.
- **The custom DNS rule is edited on a full-screen editor ([task 626](docs/spec/tasks/626-unsaved-changes-everywhere.md)),**
  like the DNS server, with the JSON body taking the rest of the screen,
  instead of a bottom sheet.

## 🩹 Fixed

- **Every screen with a Save button asks before dropping unsaved edits ([task 626](docs/spec/tasks/626-unsaved-changes-everywhere.md)).**
  Config, node settings (Tag and Source), the replace-with-group editor,
  Edit server in a folder, renaming a folder or a subscription, the
  subscription filter rule editor and the custom DNS rule editor used to
  drop edits on Back without a word. Now they show the "Unsaved changes"
  dialog: Save, Discard or Keep. Save works like the screen's Save button:
  if the save is refused (for example, a parse error on Config), the screen
  stays open with the message. Changing a field back to what it was is not
  an edit.
- **REALITY nodes no longer get the global TLS fragmentation ([task 627](docs/spec/tasks/627-reality-no-global-fragment.md)).**
  With TLS record fragmentation on, some VLESS + REALITY servers stopped
  answering: the server does not accept a ClientHello split into several
  records. The global fragmentation toggles now skip REALITY nodes.
- **XHTTP keeps the query part of `path` ([task 620](docs/spec/tasks/620-xhttp-path-query-verbatim.md)).**
  A path like `/?proxyip=…` (Cloudflare Worker relays) lost its `?…` tail on
  import, so the relay never got its parameter and sites behind Cloudflare
  failed with 502. The path now goes to the core verbatim, as in Xray, and
  the core sends the tail as the request query. Applies to share links, Xray
  JSON and sing-box JSON. Nodes of one server that differ only in the path
  query are no longer merged into one.
- **Tailscale Network tab: the exit device is back under Devices ([task 613](docs/spec/tasks/613-wg-peers-tailscale-path-health.md)).**
  In v2.25.11 the chosen exit node was shown only in the Exit node block,
  which has no row menu, so it could not be pinged or copied. It is listed
  under Devices again with its status and path.
- **Wrapped lines in JSON fields no longer lose a character at the right edge.**

## 🔧 Under the hood

- Core `v1.14.3-lx.15` (from lx.12); the Java surface of the core is
  unchanged for the app.
- Contract 1.1.115 (from 1.1.114).
- The APK is about 2 MB larger: the native editor and its highlighting
  grammars.
- Release candidates go to Google Play Open testing
  ([task 619](docs/spec/tasks/619-rc-to-play-open-testing.md)).
- CI: `actions/checkout` v7, `actions/download-artifact` v8.

</details>

<details open>
<summary><h2>🇷🇺 Русский</h2></summary>

## ⚠️ Прочтите до обновления

- **Ядро `v1.14.3-lx.15` (было `v1.14.2-lx.12`, база sing-box 1.14.3, [docs/KERNEL.md](docs/KERNEL.md)).**
  - Маскировка AWG `ip=quic` (узлы мастера WARP и любой узел с `ip=quic`):
    decoy генерируется перед каждым хендшейком — новый QUIC Initial со
    свежими connection ID при каждом старте, rekey, пробуждении и
    переподключении. Раньше узел всё время жизни слал один и тот же
    датаграм с одним DCID.
  - `ib=chrome` и `ib=firefox` — настоящие QUIC ClientHello браузера,
    откалиброванные по захватам Chrome 147/155 и Firefox 149. Раньше
    внутри QUIC Initial лежал TCP ClientHello.
  - `ip=sip` шлёт только INVITE; `ip=dns` шлёт EDNS без опций.
  - Значение ядра `ib=chrome-full` экспериментальное и не предлагается: у
    узла с ним значение снимается с предупреждением.
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
- **Редактор конфига больше не переносит длинные строки.**
  Они прокручиваются вбок; взамен заголовки охватывающих блоков закреплены
  при прокрутке (см. «Изменено»).

## ✨ Добавлено

- **Секция Masquerade у своего узла WireGuard/AmneziaWG ([задача 623](docs/spec/tasks/623-node-masquerade-section.md)).**
  На вкладке Settings узла появилась Masquerade: протокол (Off, QUIC, DNS,
  STUN, SIP), домен и браузер — строками, как Detour server. Выбор
  сохраняется сразу: `ip`/`id`/`ib` пишутся в источник узла (ссылку,
  `.conf` или тело sing-box), остальной текст не меняется. При включении
  QUIC, DNS или SIP подставляется случайный домен из пула; кубик выбирает
  другой, стрелка показывает весь пул. QUIC требует домен (он становится
  SNI decoy-ClientHello) и по умолчанию берёт профиль Chrome. Узел, где `I1`
  задан явно, сохраняет его: секция выключена и объясняет почему.
  Упакованные ссылки (`awg://` в base64, `vpn://`) и источники Xray не
  переписываются. Мастер WARP использует те же поля; его подсказка к QUIC
  больше не называет домен косметикой.
- **Один интент перепроверяет все Направления ([задача 625](docs/spec/tasks/625-urltest-all-intent.md)).**
  `com.leadaxe.lxbox.URLTEST_ALL` без extras по очереди запускает URL-тест
  авто-группы каждого Направления; ядро в каждой переключается на живой
  узел. Та же команда — `urltest-all` в плагине Tasker/Locale и
  `POST /action/urltest-all` в Debug API. Удобно повесить на встряхивание в
  MacroDroid, когда сеть подвисла.
- **Таймаут соединения для `direct-out` ([задача 616](docs/spec/tasks/616-direct-connect-timeout.md)).**
  Таймаут соединения прямого выхода теперь настройка: Traffic Processing →
  Params → Direct connect timeout, пресеты 5s–2m или любая длительность. По
  умолчанию 15 с вместо 5 с ядра, поэтому приложения в сетях, теряющих
  SYN-пакеты (например, Т‑Банк через Tele2), больше не обрываются.
  Прокси-узлы и авто-группы не затронуты.
- **Кнопка Format у JSON-полей ([задача 624](docs/spec/tasks/624-sora-editor-for-json-fields.md)).**
  У редактируемых JSON-полей (Source узла, Edit server в папке, JSON
  DNS-сервера, JSON правила, редактор DNS-правила, JSON-поле мастера) есть
  кнопка Format: разбирает текст как JSON5, как Save на Config, и
  раскладывает с отступом в два пробела. Undo отменяет. Ошибка разбора
  показывает позицию и не трогает текст; если в тексте есть комментарии,
  диалог предупреждает, что они будут удалены.

## 🔄 Изменено

- **JSON-поля на нативном редакторе Android ([задача 624](docs/spec/tasks/624-sora-editor-for-json-fields.md)).**
  Редактор конфига и все JSON-поля (Source и JSON узла, правила, DNS, мастер
  добавления сервера, Source подписки) работают на нативном редакторе.
  Клавиатура больше не закрывает строку с курсором. Стрелки Unexpected
  Keyboard и Hacker's Keyboard двигают курсор, а не сворачивают клавиатуру.
  Copy клавиатуры копирует всё многострочное выделение. Меню выделения — на
  языке приложения. Поля, принимающие что угодно, подсвечивают, кроме JSON,
  `.conf` WireGuard и ссылки. Редактор конфига и мастер добавления сервера
  больше не открывают клавиатуру сами. На ТВ D-pad заходит в поле, OK
  открывает клавиатуру. Редактор работает и на Android 7.
- **Закреплённые заголовки блоков вместо свёртки.**
  Свёртки блоков больше нет. Вместо неё при прокрутке конфига, JSON узла и
  JSON-Source подписки сверху закреплены до трёх строк охватывающих блоков.
- **Кнопки поля — над полем.**
  Поиск, Copy и Format стоят строкой над полем, рядом с его подписью, а не
  поверх текста. Растущее поле учитывает перенос строк, поэтому
  однострочный компактный JSON растёт до предела поля. Поле с переносом
  больше не заливается целиком подсветкой текущей строки.
- **Своё DNS-правило правится на полноэкранном редакторе ([задача 626](docs/spec/tasks/626-unsaved-changes-everywhere.md)),**
  как DNS-сервер, с JSON-телом на всю оставшуюся высоту, а не в шторке.

## 🩹 Исправлено

- **Все экраны с кнопкой Save спрашивают, прежде чем потерять правки ([задача 626](docs/spec/tasks/626-unsaved-changes-everywhere.md)).**
  Config, настройки узла (Tag и Source), редактор свёртки в группу, Edit
  server в папке, переименование папки и подписки, редактор правила
  фильтров подписки и редактор своего DNS-правила теряли правки на Back
  молча. Теперь они показывают диалог «Unsaved changes»: Save, Discard или
  Keep. Save работает как кнопка Save экрана: если сохранение отклонено
  (например, ошибка разбора на Config), экран остаётся открытым с
  сообщением. Вернуть поле к прежнему значению — не правка.
- **Глобальная фрагментация TLS больше не применяется к узлам REALITY ([задача 627](docs/spec/tasks/627-reality-no-global-fragment.md)).**
  При включённой фрагментации TLS-записей часть серверов VLESS + REALITY
  переставала отвечать: сервер не принимает ClientHello, разрезанный на
  несколько записей. Глобальные переключатели фрагментации теперь
  пропускают узлы REALITY.
- **XHTTP сохраняет query в `path` ([задача 620](docs/spec/tasks/620-xhttp-path-query-verbatim.md)).**
  Путь вида `/?proxyip=…` (релеи Cloudflare Worker) при импорте терял хвост
  `?…`: релей не получал свой параметр, и сайты за Cloudflare отвечали 502.
  Теперь путь уходит в ядро дословно, как в Xray, а ядро отправляет хвост
  как query запроса. Касается ссылок, Xray JSON и sing-box JSON. Узлы одного
  сервера, различающиеся только query пути, больше не схлопываются в один.
- **Вкладка Network у Tailscale: выходное устройство снова в Devices ([задача 613](docs/spec/tasks/613-wg-peers-tailscale-path-health.md)).**
  В v2.25.11 выбранный exit node показывался только в блоке Exit node, где
  нет меню строки, поэтому его нельзя было пинговать или скопировать. Теперь
  он снова в списке Devices со статусом и путём.
- **Перенесённые строки в JSON-полях больше не теряют символ у правого края.**

## 🔧 Под капотом

- Ядро `v1.14.3-lx.15` (было lx.12); Java-поверхность ядра для приложения
  не изменилась.
- Контракт 1.1.115 (было 1.1.114).
- APK вырос примерно на 2 МБ: нативный редактор и грамматики подсветки.
- Релиз-кандидаты уходят в открытое тестирование Google Play
  ([задача 619](docs/spec/tasks/619-rc-to-play-open-testing.md)).
- CI: `actions/checkout` v7, `actions/download-artifact` v8.

</details>

---

## Install / Установка

```bash
adb install -r LxBox-v2.25.12-arm64-v8a.apk
```

Без uninstall! Поверх существующей установки. Настройки и подписки сохранятся.

No uninstall needed — install over the existing one. Settings and subscriptions
are preserved.

---

Previous release / Предыдущий релиз: [v2.25.11](docs/releases/v2.25.11.md).
