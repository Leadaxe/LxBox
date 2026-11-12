# L×Box v2.25.22-rc.1

**The first release candidate on top of [v2.25.21](https://github.com/Leadaxe/LxBox/releases/tag/v2.25.21).**

This is a pre-release on GitHub; in Google Play it goes to Open testing. It is
not offered to users of the stable release.

Two import fixes for nodes from **Xray** configs and links: XHTTP keeps its
session id alphabet and length, and a node with Xray `mux` enabled connects
again. Core `v1.14.4-lx.33`, contract 1.1.169.

**Первый релиз-кандидат поверх [v2.25.21](https://github.com/Leadaxe/LxBox/releases/tag/v2.25.21).**

На GitHub это pre-release, в Google Play сборка уходит в открытое
тестирование. Пользователям стабильного релиза она не предлагается.

Два исправления импорта узлов из конфигов и ссылок **Xray**: XHTTP сохраняет
алфавит и длину идентификатора сессии, а узел с включённым Xray `mux` снова
соединяется. Ядро `v1.14.4-lx.33`, контракт 1.1.169.

---

<details open>
<summary><h2>🇬🇧 English</h2></summary>

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

- Shared contract 1.1.169 (1.1.168: XHTTP session id; 1.1.169: Xray mux).

</details>

<details open>
<summary><h2>🇷🇺 Русский</h2></summary>

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

- Общий контракт 1.1.169 (1.1.168 — session id XHTTP; 1.1.169 — Xray mux).

</details>

---

## Install / Установка

```bash
adb install -r LxBox-v2.25.22-rc.1-arm64-v8a.apk
```

Без uninstall! Поверх существующей установки. Настройки и подписки сохранятся.

No uninstall needed — install over the existing one. Settings and subscriptions
are preserved.

---

Previous release / Предыдущий релиз: [v2.25.21](docs/releases/v2.25.21.md).
