# L×Box v2.25.22-rc.2

**The second release candidate on top of [v2.25.21](https://github.com/Leadaxe/LxBox/releases/tag/v2.25.21).**

This is a pre-release on GitHub; in Google Play it goes to Open testing. It is
not offered to users of the stable release.

New in rc.2: the core moves to `v1.14.4-lx.35`, and **Sniff guard** replaces
the QUIC anti-sniff decoy — the core now hides the first handshake packet of
TLS and QUIC nodes from a relay that redirects by SNI and learns which paths
need it. ⚠️ The four «Anti-sniff decoy» settings are gone, their values are
not carried over. An HTTP proxy node now says it carries only TCP. From rc.1:
two import fixes for nodes from **Xray** configs and links. Contract 1.1.170.

**Второй релиз-кандидат поверх [v2.25.21](https://github.com/Leadaxe/LxBox/releases/tag/v2.25.21).**

На GitHub это pre-release, в Google Play сборка уходит в открытое
тестирование. Пользователям стабильного релиза она не предлагается.

Новое в rc.2: ядро `v1.14.4-lx.35`, а **защита от сниффинга** заменяет
QUIC-обманку — ядро прячет первый пакет рукопожатия TLS- и QUIC-узлов от
релея, который перенаправляет по SNI, и само учится, каким путям это нужно.
⚠️ Четыре настройки «Обманки от сниффинга» убраны, их значения не
переносятся. Узел HTTP-прокси теперь говорит, что передаёт только TCP. Из
rc.1: два исправления импорта узлов из конфигов и ссылок **Xray**.
Контракт 1.1.170.

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

## ✨ Added

- **An HTTP proxy node says it carries only TCP ([task 728](docs/spec/tasks/728-http-proxy-tcp-only-notice.md), [#187](https://github.com/Leadaxe/LxBox/issues/187)).**
  Node Settings of an HTTP proxy shows a note under Server: nodes with a TCP
  transport work through it fully, UDP-based nodes (Hysteria2, TUIC,
  WireGuard) do not.

## 🐛 Fixed

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
  2026-11-14 (uTLS, REALITY client fixes, sing-tun). Not yet run on a device.
- Shared contract 1.1.170 (1.1.168: XHTTP session id; 1.1.169: Xray mux;
  1.1.170: sniff guard).

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

## ✨ Добавлено

- **Узел HTTP-прокси говорит, что передаёт только TCP ([задача 728](docs/spec/tasks/728-http-proxy-tcp-only-notice.md), [#187](https://github.com/Leadaxe/LxBox/issues/187)).**
  На экране настроек HTTP-прокси под строкой Server стоит заметка: узлы с
  TCP-транспортом работают через него полностью, узлы на UDP (Hysteria2,
  TUIC, WireGuard) — нет.

## 🐛 Исправлено

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
  14.11.2026 (uTLS, правки клиента REALITY, sing-tun). На устройстве ещё не
  запускалось.
- Общий контракт 1.1.170 (1.1.168 — session id XHTTP; 1.1.169 — Xray mux;
  1.1.170 — защита от сниффинга).

</details>

---

## Install / Установка

```bash
adb install -r LxBox-v2.25.22-rc.2-arm64-v8a.apk
```

Без uninstall! Поверх существующей установки. Настройки и подписки сохранятся.

No uninstall needed — install over the existing one. Settings and subscriptions
are preserved.

---

Previous release / Предыдущий релиз: [v2.25.21](docs/releases/v2.25.21.md).
