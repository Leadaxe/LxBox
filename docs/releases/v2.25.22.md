# L×Box v2.25.22

**A patch on top of [v2.25.21](https://github.com/Leadaxe/LxBox/releases/tag/v2.25.21).**

**Sniff guard** replaces the QUIC anti-sniff decoy: the core hides the first
handshake packet of TLS and QUIC nodes from a relay that redirects by SNI and
learns which paths need it. ⚠️ The four «Anti-sniff decoy» settings are gone,
their values are not carried over. ⚠️ A server whose detour is unavailable no
longer disappears from the config: it connects directly and gets a ⚠.
**Test servers** now follow the source's detour. The app no longer freezes
when the core stops answering. **System colors** (Material You), TV remote
fixes in the app picker, two import fixes for **Xray** nodes. Core
`v1.14.4-lx.35`, contract 1.1.171.

**Патч поверх [v2.25.21](https://github.com/Leadaxe/LxBox/releases/tag/v2.25.21).**

**Защита от сниффинга** заменяет QUIC-обманку: ядро прячет первый пакет
рукопожатия TLS- и QUIC-узлов от релея, который перенаправляет по SNI, и
само учится, каким путям это нужно. ⚠️ Четыре настройки «Обманки от
сниффинга» убраны, их значения не переносятся. ⚠️ Сервер с недоступным
detour больше не пропадает из конфига: он подключается напрямую и получает
⚠. **Тест серверов** теперь учитывает detour источника. Приложение больше
не зависает, когда ядро перестаёт отвечать. **Системные цвета** (Material
You), исправления пульта TV в выборе приложений, два исправления импорта
узлов **Xray**. Ядро `v1.14.4-lx.35`, контракт 1.1.171.

---

<details open>
<summary><h2>🇬🇧 English</h2></summary>

## ⚠️ Changed

- **Sniff guard replaces the QUIC anti-sniff decoy ([task 729](docs/spec/tasks/729-sniff-guard-block.md), [#215](https://github.com/Leadaxe/LxBox/issues/215)).**
  Core settings get a **Sniff guard** section: the TLS method (Record
  fragment by default), the QUIC method (Decoy byte by default), «Only nodes
  with a masked SNI» (on) and «Remember relays across restarts» (off). The
  core hides the first handshake packet from a relay or router that redirects
  connections by SNI, and learns from connection outcomes which paths need
  it: paths through direct, SSH and SOCKS start unprotected, other relays
  start protected. The decoy byte is never sent through a SOCKS relay.
  - The four «Anti-sniff decoy» settings are gone and their saved values are
    not carried over. The decoy, off by default before, is now on.
  - The core no longer splits the TLS ClientHello for every node behind a
    detour on its own. A node whose detour is a group with `direct` selected
    now starts without the split — the case from #215, where a network drops
    a ClientHello split into TLS records.
  - If a node stopped connecting after the update, try another TLS method or
    Off in Core → Sniff guard.
  - Node checks use the same protection as the tunnel.
- **Merged duplicates can be opened ([task 589](docs/spec/tasks/589-duplicates-collapsed-on-survivor.md)).**
  The «N duplicates merged» line on the subscription page is now tappable:
  it opens a sheet with a card for every server that was kept, showing how
  many repeats it absorbed and under which names.
- **An unavailable detour no longer removes the server ([task 739](docs/spec/tasks/739-detour-unavailable-node-warning.md)).**
  When a detour target is not available — the Direction is turned off, the
  server was deleted, renamed or disappeared from its subscription — the
  config is built without that detour: the server stays and connects
  directly. Before, such a server either vanished from the config or went
  direct with only a line in the build report. Now a ⚠ «Hop … unavailable:
  hop removed» marks the subscription, folder or server in the source list
  and the node's own card. On the subscription and folder pages the same
  warning is a tappable line, like «N entries dropped»: tap it to read what
  happened and what to do. A detour onto the node itself and a ring of
  detours still drop the node; chains are unchanged.
- **TLS settings say they skip servers with a detour ([task 737](docs/spec/tasks/737-tls-skip-detour-toggle.md)).**
  TLS fragmentation and mixed-case SNI apply only to servers that connect
  directly; a server with a detour runs its TLS inside the hop, where Sniff
  guard decides. The global section, the subscription and folder TLS section
  and the server screen now say so. The behaviour is unchanged.

## ✨ Added

- **System colors (Material You) ([task 735](docs/spec/tasks/735-material-you-system-colors.md), [#218](https://github.com/Leadaxe/LxBox/issues/218)).**
  App Settings → Appearance has a «System colors» switch: the app takes its
  accent color from the wallpaper palette, like other Android apps. It is off
  by default, so nothing changes until you turn it on, and it is shown only
  on Android 12 and newer, not on TV. Status colors (ping, online/offline)
  stay green and orange.
- **An HTTP proxy node says it carries only TCP ([task 728](docs/spec/tasks/728-http-proxy-tcp-only-notice.md), [#187](https://github.com/Leadaxe/LxBox/issues/187)).**
  Node Settings of an HTTP proxy shows a note under Server: nodes with a TCP
  transport work through it fully, UDP-based nodes (Hysteria2, TUIC,
  WireGuard) do not.

## 🐛 Fixed

- **Test servers ignored the source's detour ([task 730](docs/spec/tasks/730-probe-test-source-detour.md), [#187](https://github.com/Leadaxe/LxBox/issues/187)).**
  With the VPN off, the server test checked every node directly, so a
  subscription behind an operator's HTTP proxy showed all nodes dead on a
  network without direct internet. A detour that points at one specific node
  is now followed in the test, as in the tunnel; in a folder, members' own
  detours count too. A detour the test cannot follow — a Direction, its auto
  node, a chain, a group, a node that is off or has its own detour — is named
  under the test bar, which says either «Tested through <node>.» or that
  nodes are checked directly. Node Diagnostics with the VPN off follows the
  same rule.
- **Test servers: the detour note and the «VPN is running» dialog ([task 738](docs/spec/tasks/738-probe-note-wording-vpn-gate-autoclose.md)).**
  The note under the test no longer says «of this source» — a folder node
  can have its own detour. It now reads «Detour is not applied in the test»,
  in the singular for one node. The «VPN is running» dialog closes by itself
  when the VPN is stopped elsewhere — the notification, the tile,
  Automation — and the test goes on.
- **The app no longer freezes when the core stops answering ([task 732](docs/spec/tasks/732-main-thread-core-calls-off-main.md), [#210](https://github.com/Leadaxe/LxBox/issues/210)).**
  Connecting to the core and pausing/waking it on screen off/on and Doze ran
  on Android's main thread; when the core could not be reached, buttons,
  notification updates and Stop stopped responding. These calls now run in
  the background, the retry pause grows up to 8 seconds, and a stuck call is
  named in the app log. A server test can no longer start while the VPN is
  still starting — that could leave pings at «err» until the VPN was
  restarted.
- **A ping the core never answered hung forever ([task 731](docs/spec/tasks/731-chain-links-namesakes-ping-deadline.md)).**
  The row stayed in «PING…», mass ping lost a slot and the log was silent.
  The app now stops waiting 3 s after the test timeout, marks the node as
  failed and writes a log line.
- **A renamed copy of a folder node took over the original's links ([task 731](docs/spec/tasks/731-chain-links-namesakes-ping-deadline.md)).**
  Two folder members with the same name share one address, and the first
  one holds it. Renaming the second one moved chain positions, detours and
  auto-group members of the first onto the copy. Links now stay with the
  node that holds the address.
- **The chain editor showed stale nodes after folder edits ([task 731](docs/spec/tasks/731-chain-links-namesakes-ping-deadline.md)).**
  A new folder node was marked as lost and a deleted one stayed in the
  position picker until the Servers screen was reopened. The editor now
  rebuilds the config on open when sources changed since the last build.
- **A file subscription without its file no longer stays silent ([#219](https://github.com/Leadaxe/LxBox/issues/219)).**
  A backup keeps subscription settings, not their contents, so after a
  restore on another phone or a reinstall a subscription added from a file
  has no servers, and Update did nothing. The list row now says «Choose the
  file again», the Nodes tab explains why (Android does not let the app read
  the file again) with a button to pick the file, and Update shows the same
  hint.
- **Android TV: the app list could not be scrolled with the remote ([task 736](docs/spec/tasks/736-tv-search-field-dpad-mouse-drag.md), [#220](https://github.com/Leadaxe/LxBox/issues/220)).**
  In the app picker (Routing → Tunnel apps, apps of a routing rule, URL
  Check) the D-pad stopped at the search field. Up/Down now leave
  single-line search fields above lists (app pickers, Logs filter, connection
  filter, node filters). Lists also scroll by dragging with a mouse pointer,
  which is how a TV remote in mouse mode works.
- **XHTTP session id alphabet and length were lost on import from Xray ([task 726](docs/spec/tasks/726-xhttp-session-id-table-length.md), [#211](https://github.com/Leadaxe/LxBox/issues/211)).**
  A server behind a CDN that blocks the default dashed-UUID session id
  answered 403 when the node came from an Xray config or a share link, while
  the same node written as sing-box JSON worked. `sessionIDTable` and
  `sessionIDLength` now reach the node as `session_table` / `session_length`
  — from Xray JSON (`xhttpSettings` / `splithttpSettings`, flat or in
  `extra`) and from the `extra` and query of a link. One without the other is
  removed with a warning: the core accepts them only together.
- **A node imported from Xray JSON with `mux` enabled did not connect ([task 727](docs/spec/tasks/727-xray-mux-not-multiplex.md)).**
  Xray `mux` was turned into sing-box `multiplex`, but these are different
  protocols on the wire (Mux.Cool vs h2mux / smux / yamux), and an Xray
  server refuses the latter. Xray `mux` is now dropped with an info note on
  the node; the node connects without multiplexing. `multiplex` written
  explicitly in sing-box JSON is kept. Nodes from a subscription are fixed on
  the next subscription update.

## 🔧 Under the hood

- Core `v1.14.4-lx.35`: `lx.sniff_guard`, upstream `stable` sync to
  2026-11-14 (uTLS, REALITY client fixes, sing-tun).
- Shared contract 1.1.171 (1.1.168: XHTTP session id; 1.1.169: Xray mux;
  1.1.170: sniff guard; 1.1.171: warning code `detour_unavailable`).
- The Debug API folder probe reports the detour the test followed.

</details>

<details open>
<summary><h2>🇷🇺 Русский</h2></summary>

## ⚠️ Изменено

- **Защита от сниффинга заменяет QUIC-обманку ([задача 729](docs/spec/tasks/729-sniff-guard-block.md), [#215](https://github.com/Leadaxe/LxBox/issues/215)).**
  В настройках Core появилась секция **«Защита от сниффинга»**: метод для
  TLS (по умолчанию Record fragment), метод для QUIC (по умолчанию
  байт-обманка), «Только узлы с маскировочным SNI» (включено) и «Помнить
  релеи между перезапусками» (выключено). Ядро прячет первый пакет
  рукопожатия от релея или роутера, который перенаправляет соединения по
  SNI, и по исходам подключений учится, каким путям это нужно: пути
  напрямую, через SSH и SOCKS стартуют без защиты, через остальные релеи — с
  защитой. Через SOCKS-релей байт-обманка не отправляется никогда.
  - Четыре настройки «Обманки от сниффинга» убраны, их сохранённые значения
    не переносятся. Обманка, раньше выключенная по умолчанию, теперь
    включена.
  - Ядро больше не режет TLS ClientHello само у каждого узла за detour. Узел,
    у которого detour — группа с выбранным `direct`, теперь стартует без
    разреза: это случай из #215, где сеть дропает ClientHello, разрезанный на
    TLS-записи.
  - Если после обновления узел перестал соединяться, попробуйте другой метод
    TLS или Off в Core → «Защита от сниффинга».
  - Проверка узлов использует ту же защиту, что и туннель.
- **Склеенные дубли можно раскрыть ([задача 589](docs/spec/tasks/589-duplicates-collapsed-on-survivor.md)).**
  Строка «N duplicates merged» на странице подписки теперь нажимается:
  открывается шторка с карточкой на каждый оставшийся сервер — сколько
  повторов в него слилось и под какими именами.
- **Недоступный detour больше не убирает сервер ([задача 739](docs/spec/tasks/739-detour-unavailable-node-warning.md)).**
  Если цель detour недоступна — Направление выключено, сервер удалён,
  переименован или пропал из подписки, — конфиг собирается без этого
  detour: сервер остаётся и подключается напрямую. Раньше такой сервер либо
  исчезал из конфига, либо шёл напрямую, оставив только строку в отчёте
  сборки. Теперь ⚠ «Hop … unavailable: hop removed» стоит у подписки, папки
  или сервера в списке источников и на карточке самого узла. На странице
  подписки и папки то же предупреждение — строка, по которой можно нажать,
  как «N entries dropped»: по тапу видно, что случилось и что делать. detour на
  самого себя и кольцо из detour по-прежнему убирают узел, цепочки не
  менялись.
- **Подписи у TLS-настроек говорят, что серверы с detour пропускаются ([задача 737](docs/spec/tasks/737-tls-skip-detour-toggle.md)).**
  Фрагментация TLS и SNI в смешанном регистре применяются только к
  серверам, которые подключаются напрямую; у сервера с detour TLS идёт
  внутри хопа, и там решает защита от сниффинга. Об этом теперь сказано в
  глобальном разделе, в разделе TLS у подписки и папки и на экране сервера.
  Поведение не менялось.

## ✨ Добавлено

- **Системные цвета (Material You) ([задача 735](docs/spec/tasks/735-material-you-system-colors.md), [#218](https://github.com/Leadaxe/LxBox/issues/218)).**
  В App Settings → Appearance появился переключатель «Системные цвета»:
  приложение берёт акцентный цвет из палитры обоев, как другие приложения
  Android. По умолчанию он выключен, так что ничего не меняется, пока вы
  его не включите, и показывается только на Android 12 и новее, не на TV.
  Цвета статусов (пинг, online/offline) остаются зелёным и оранжевым.
- **Узел HTTP-прокси говорит, что передаёт только TCP ([задача 728](docs/spec/tasks/728-http-proxy-tcp-only-notice.md), [#187](https://github.com/Leadaxe/LxBox/issues/187)).**
  На экране настроек HTTP-прокси под строкой Server стоит заметка: узлы с
  TCP-транспортом работают через него полностью, узлы на UDP (Hysteria2,
  TUIC, WireGuard) — нет.

## 🐛 Исправлено

- **Тест серверов не учитывал detour источника ([задача 730](docs/spec/tasks/730-probe-test-source-detour.md), [#187](https://github.com/Leadaxe/LxBox/issues/187)).**
  При выключенном VPN тест проверял каждый узел напрямую, поэтому подписка
  за HTTP-прокси оператора в сети без прямого интернета показывала все узлы
  мёртвыми. Теперь detour, который указывает на конкретный узел, в тесте
  учитывается так же, как в туннеле; в папке учитываются и личные detour
  её узлов. detour, который тест учесть не может, — Направление, его
  auto-узел, цепочка, группа, выключенный узел или узел со своим detour —
  назван под полосой теста: там написано либо «Tested through <узел>.», либо
  что узлы проверяются напрямую. Диагностика узла без VPN работает так же.
- **Тест серверов: пометка про detour и диалог «VPN is running» ([задача 738](docs/spec/tasks/738-probe-note-wording-vpn-gate-autoclose.md)).**
  Пометка под тестом больше не говорит «этого источника» — у узла папки
  detour бывает личным. Теперь там «Detour is not applied in the test», для
  одного узла — в единственном числе. Диалог «VPN is running» закрывается
  сам, если VPN остановили в другом месте — из уведомления, плитки,
  Automation, — и тест продолжается.
- **Приложение больше не зависает, когда ядро перестаёт отвечать ([задача 732](docs/spec/tasks/732-main-thread-core-calls-off-main.md), [#210](https://github.com/Leadaxe/LxBox/issues/210)).**
  Подключение к ядру и его пауза/пробуждение при гашении экрана и в Doze
  шли с главного потока Android; если ядро было недоступно, кнопки,
  обновление уведомления и Stop переставали отвечать. Теперь эти вызовы
  идут в фоне, пауза между повторами растёт до 8 секунд, а зависший вызов
  назван в журнале приложения. Тест серверов больше не стартует, пока VPN
  ещё запускается, — из-за этого пинги могли показывать «err» до
  перезапуска VPN.
- **Пинг, на который ядро не ответило, висел бесконечно ([задача 731](docs/spec/tasks/731-chain-links-namesakes-ping-deadline.md)).**
  Строка оставалась в «PING…», массовый пинг терял слот, в журнале было
  пусто. Теперь приложение перестаёт ждать через 3 с после таймаута замера,
  узел получает ошибку, в журнал идёт строка.
- **Переименованная копия узла папки забирала ссылки оригинала ([задача 731](docs/spec/tasks/731-chain-links-namesakes-ping-deadline.md)).**
  Два узла папки с одинаковым именем делят один адрес, и держит его первый.
  Переименование второго переносило на копию позиции цепочек, detour и
  членство в автогруппах первого. Теперь ссылки остаются у узла, который
  держит адрес.
- **Редактор цепочки показывал устаревшие узлы после правок в папке ([задача 731](docs/spec/tasks/731-chain-links-namesakes-ping-deadline.md)).**
  Новый узел папки отмечался потерянным, а удалённый оставался в списке
  позиций, пока не откроешь экран серверов заново. Теперь при открытии
  редактор пересобирает конфиг, если источники менялись с последней сборки.
- **Файловая подписка без файла больше не молчит ([#219](https://github.com/Leadaxe/LxBox/issues/219)).**
  Резервная копия хранит настройки подписок, а не их содержимое, поэтому
  после восстановления на другом телефоне или переустановки у подписки,
  добавленной из файла, нет серверов, а Update ничего не делал. Теперь в
  списке написано «Выберите файл заново», на вкладке Nodes объяснено
  почему (Android не даёт приложению прочитать файл снова) и есть кнопка
  выбора файла, а Update показывает ту же подсказку.
- **Android TV: список приложений не прокручивался пультом ([задача 736](docs/spec/tasks/736-tv-search-field-dpad-mouse-drag.md), [#220](https://github.com/Leadaxe/LxBox/issues/220)).**
  В выборе приложений (Routing → Tunnel apps, приложения правила
  маршрутизации, URL Check) D-pad упирался в строку поиска. Теперь ↑/↓
  уводят из однострочного поля поиска в список под ним (выбор приложений,
  фильтр Logs, фильтр соединений, фильтры узлов). Ещё списки прокручиваются
  перетаскиванием указателем мыши — так работает пульт TV в режиме мыши.
- **Алфавит и длина идентификатора сессии XHTTP терялись при импорте из Xray ([задача 726](docs/spec/tasks/726-xhttp-session-id-table-length.md), [#211](https://github.com/Leadaxe/LxBox/issues/211)).**
  Сервер за CDN, который блокирует стандартный идентификатор сессии в виде
  UUID с дефисами, отвечал 403, если узел пришёл из конфига Xray или из
  ссылки, — хотя тот же узел в виде sing-box JSON работал. `sessionIDTable`
  и `sessionIDLength` теперь доезжают до узла как `session_table` /
  `session_length` — из Xray JSON (`xhttpSettings` / `splithttpSettings`,
  плоско или в `extra`) и из `extra` и параметров ссылки. Одно поле без
  второго снимается с предупреждением: ядро принимает их только вместе.
- **Узел из Xray JSON с включённым `mux` не соединялся ([задача 727](docs/spec/tasks/727-xray-mux-not-multiplex.md)).**
  Xray `mux` превращался в `multiplex` sing-box, но на проводе это разные
  протоколы (Mux.Cool против h2mux / smux / yamux), и сервер Xray второй не
  принимает. Теперь Xray `mux` снимается с пометкой на узле, узел
  соединяется без мультиплексирования. `multiplex`, явно записанный в
  sing-box JSON, остаётся. Узлы из подписки исправятся при следующем её
  обновлении.

## 🔧 Под капотом

- Ядро `v1.14.4-lx.35`: `lx.sniff_guard`, синк с `stable` апстрима до
  14.11.2026 (uTLS, правки клиента REALITY, sing-tun).
- Общий контракт 1.1.171 (1.1.168 — session id XHTTP; 1.1.169 — Xray mux;
  1.1.170 — защита от сниффинга; 1.1.171 — код предупреждения
  `detour_unavailable`).
- Проба папки в Debug API сообщает, какой detour учёл тест.

</details>

---

## Install / Установка

```bash
adb install -r LxBox-v2.25.22-arm64-v8a.apk
```

Без uninstall! Поверх существующей установки. Настройки и подписки сохранятся.

No uninstall needed — install over the existing one. Settings and subscriptions
are preserved.

---

Previous release / Предыдущий релиз: [v2.25.21](docs/releases/v2.25.21.md).
