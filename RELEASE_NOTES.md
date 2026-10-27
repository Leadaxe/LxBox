# L×Box v2.25.18-rc.1

**A release candidate on top of [v2.25.17](https://github.com/Leadaxe/LxBox/releases/tag/v2.25.17).**

This is a pre-release on GitHub; in Google Play it goes to Open testing. It is
not offered to users of the stable release.

The new **Diagnostics** section replaces **Speed Test** in the side menu. Its
**URL Check** tab sends a real request to a site through your routing and
shows every step as it happens: DNS, the matched rule, the group and node, the
node's detours, TCP, TLS and the response, with times and the step where the
path broke. Speed Test is the second tab. WireGuard and AmneziaWG nodes get an
**INI** tab with the node as a `.conf`, an INI with several `[Peer]` sections
keeps all of them, and the auto node of a folder is edited in Node Settings.
The subscription update interval has an **As subscription** mode, and a
manually chosen interval is no longer overwritten by the server. Core
`v1.14.3-lx.24-rc.1`, contract 1.1.140.

**Релиз-кандидат поверх [v2.25.17](https://github.com/Leadaxe/LxBox/releases/tag/v2.25.17).**

На GitHub это pre-release, в Google Play сборка уходит в открытое
тестирование. Пользователям стабильного релиза она не предлагается.

Новый раздел **Diagnostics** заменяет **Speed Test** в боковом меню. Его
вкладка **URL Check** отправляет к сайту настоящий запрос через вашу
маршрутизацию и показывает каждый шаг по мере прохождения: DNS, сработавшее
правило, группу и узел, detour узла, TCP, TLS и ответ — со временем и шагом,
на котором путь оборвался. Speed Test — вторая вкладка. У узлов WireGuard и
AmneziaWG появилась вкладка **INI** с узлом в виде `.conf`, INI с несколькими
секциями `[Peer]` сохраняет все, а auto-узел папки правится в Node Settings.
У интервала обновления подписки есть режим **As subscription**, и выбранный
вручную интервал сервер больше не перезаписывает. Ядро
`v1.14.3-lx.24-rc.1`, контракт 1.1.140.

---

<details open>
<summary><h2>🇬🇧 English</h2></summary>

## ⚠️ Read before updating

- **Speed Test moved into Diagnostics ([task 687](docs/spec/tasks/687-diagnostics-url-check.md)).**
  The **Speed Test** item is gone from the side menu. The same screen is the
  **Speed Test** tab of **Diagnostics**, next to **URL Check**; it works as
  before, and a running test is not interrupted when you switch tabs. Support
  links to Speed Test open that tab.
- **The core is a release candidate.** `v1.14.3-lx.24-rc.1` carries the
  connection test behind URL Check; the stable core `lx.24` follows a field
  run.

## ✨ New

- **Diagnostics → URL Check ([task 687](docs/spec/tasks/687-diagnostics-url-check.md), issue #176).**
  Enter a site (`example.com` or a full `http`/`https` URL) and press **Run**.
  The core makes a real request through your routing and streams the steps as
  a tree:
  - the app's DNS queries (A, AAAA, HTTPS), the DNS rule and the server that
    answered;
  - the route rule, the group choice, the node and its detours, the lookup of
    the node's own address with its DNS server;
  - TCP, TLS and the transport to the node, then TLS to the site, the first
    byte and the HTTP status.

  Each step shows its time and result. A step the protocol does not confirm
  (the VLESS, VMess, Trojan or Shadowsocks header) is marked **sent, not
  confirmed**; a step taken from the cache or an open connection is marked
  **reused**. When the path breaks, the step where it broke is highlighted and
  named above the tree, for example `Failed at app_dns nonexistent.invalid:
  rcode NXDOMAIN`. A tap on a step shows its details (rule, server, answers,
  addresses). Options:
  - **App** — run the request on behalf of an installed app, so rules by app
    apply;
  - depth **Full · Connect · Route · DNS** — Route stops after choosing the
    node and opens no connection, DNS runs only the app's DNS queries;
  - **From scratch** — bypass the DNS cache and open new connections.

  **Copy** puts the whole trace on the clipboard as text. The check needs a
  running VPN; **Stop** cancels it.
- **INI tab for WireGuard / AmneziaWG nodes ([task 686](docs/spec/tasks/686-folder-auto-node-source-tab.md)).**
  Node Settings shows the node as a `.conf` whatever it was added from (link,
  INI or JSON): all peers, masquerade and AmneziaWG fields, with **Copy**,
  **Share .conf** and **Edit INI**. Edit INI replaces the node's source with
  the edited INI after a warning; keys of the body that INI cannot express are
  listed under **Not in INI**.
- **Several `[Peer]` sections in a WireGuard INI are accepted (task 686).**
  Each section becomes its own peer of the node; before, everything after the
  first was dropped. A peer without a public key or endpoint is dropped with a
  warning naming it.

## 🔄 Changed

- **Subscription update interval: "As subscription"; the server no longer
  overwrites your choice ([task 685](docs/spec/tasks/685-subscription-interval-as-subscription.md)).**
  The first item of **Update interval** is **As subscription**: the interval
  comes from the server's `profile-update-interval` header (24 h when the
  server sends none). A manually chosen interval stays as chosen; before,
  every update replaced it with the server's value. New subscriptions start in
  As subscription. **Never (respect server)** is removed. Existing
  subscriptions keep their current number as a manual choice; pick As
  subscription to follow the server again.
- **The auto node of a folder is edited in Node Settings (task 686).** A tap
  opens the group form on the **Settings** tab (name, servers in the pool,
  mode, advanced); **Source** shows the stored record and can be edited; the
  **JSON** tab says "Members are resolved at build time" instead of an empty
  `outbounds`. Before, a tap opened an empty Source, the name could not be
  saved and the JSON tab showed no members. The pool preview no longer counts
  disabled servers and marks them with ⏻.
- **The long-press menu no longer duplicates Node Settings (task 686).**
  **Edit…** of a folder member and **Edit source…** / **Update** of a
  standalone server are removed; a tap opens the same screen.
- **`#` comments in pasted JSON (task 686).** A node JSON and the Config
  screen accept `#` line comments, as the core does, next to `//` and
  `/* */`; they are stripped like the others.
- **Direction editor:** a caption under **Replace groups** says what the
  checkbox does — a ticked group joins even when the filter does not match it
  and goes above the servers; groups never join the Direction's auto group.

## 🩹 Fixed

- The subscription filter rule editor showed "Совпадений: из узлов" without
  the numbers; the "Applied — …" message after saving filters lost them too.
- Node delay is shown as `120ms` instead of `120MS`.

## 🔧 Under the hood

- **Core `v1.14.3-lx.23` → `v1.14.3-lx.24-rc.1`.** Adds the active
  connection test (`CommandClient.startConnectionTest`,
  Leadaxe/sing-box-lx#59) and fixes a data race in the selection of the Auto
  (`urltest`) group. No config changes. The Java surface only grows
  (258 → 270 classes).
- Contract 1.1.140: several `[Peer]` sections in INI (`repeat each`,
  `wgconf_peer_dropped`).
- Among the new tests: the connection test trace (tree, order by start time, result,
  stream error, text export, URL normalization).

</details>

<details open>
<summary><h2>🇷🇺 Русский</h2></summary>

## ⚠️ Прочтите до обновления

- **Speed Test переехал в Diagnostics ([задача 687](docs/spec/tasks/687-diagnostics-url-check.md)).**
  Пункта **Speed Test** в боковом меню больше нет. Тот же экран — вкладка
  **Speed Test** раздела **Diagnostics**, рядом с **URL Check**; работает как
  раньше, идущий замер не прерывается при переключении вкладок. Ссылки
  поддержки на Speed Test открывают эту вкладку.
- **Ядро — релиз-кандидат.** `v1.14.3-lx.24-rc.1` несёт проверку
  соединения для URL Check; стабильное ядро `lx.24` выйдет после полевой
  проверки.

## ✨ Новое

- **Diagnostics → URL Check ([задача 687](docs/spec/tasks/687-diagnostics-url-check.md), issue #176).**
  Введите сайт (`example.com` или полный URL `http`/`https`) и нажмите
  **Run**. Ядро делает настоящий запрос через вашу маршрутизацию и потоком
  отдаёт шаги деревом:
  - DNS-запросы приложения (A, AAAA, HTTPS), правило DNS и ответивший сервер;
  - правило маршрута, выбор в группе, узел и его detour, резолв адреса
    самого узла со своим DNS-сервером;
  - TCP, TLS и транспорт до узла, затем TLS до сайта, первый байт и статус
    HTTP.

  У каждого шага время и исход. Шаг, который протокол не подтверждает
  (заголовок VLESS, VMess, Trojan или Shadowsocks), помечен **отправлено, без
  подтверждения**; шаг, взятый из кэша или открытого соединения, —
  **использовано готовое**. Если путь оборвался, шаг обрыва подсвечен и
  назван над деревом, например `Failed at app_dns nonexistent.invalid: rcode
  NXDOMAIN`. Тап по шагу раскрывает подробности (правило, сервер, ответы,
  адреса). Параметры:
  - **App** — запрос от имени установленного приложения, чтобы сработали
    правила по приложениям;
  - глубина **Full · Connect · Route · DNS** — Route останавливается после
    выбора узла и не открывает соединений, DNS выполняет только DNS-запросы
    приложения;
  - **From scratch** — мимо кэша DNS, с новыми соединениями.

  **Copy** кладёт всю трассу текстом в буфер. Проверке нужен запущенный VPN;
  **Stop** её отменяет.
- **Вкладка INI у узлов WireGuard / AmneziaWG ([задача 686](docs/spec/tasks/686-folder-auto-node-source-tab.md)).**
  Node Settings показывает узел в виде `.conf`, откуда бы он ни был добавлен
  (ссылка, INI или JSON): все пиры, маскировка и поля AmneziaWG, с **Copy**,
  **Share .conf** и **Edit INI**. Edit INI после предупреждения заменяет
  источник узла отредактированным INI; ключи тела, которые INI выразить не
  может, перечислены под **Not in INI**.
- **INI WireGuard с несколькими секциями `[Peer]` принимается (задача 686).**
  Каждая секция становится своим пиром узла; раньше всё после первой
  отбрасывалось. Пир без публичного ключа или endpoint отбрасывается с
  предупреждением, где он назван.

## 🔄 Изменено

- **Интервал обновления подписки: «As subscription»; сервер больше не
  перезаписывает ваш выбор ([задача 685](docs/spec/tasks/685-subscription-interval-as-subscription.md)).**
  Первый пункт **Update interval** — **As subscription**: интервал берётся из
  заголовка сервера `profile-update-interval` (24 ч, если сервер его не
  шлёт). Выбранный вручную интервал остаётся; раньше каждое обновление
  заменяло его значением сервера. Новые подписки начинают с As subscription.
  Пункт **Never (respect server)** снят. У существующих подписок текущее
  число сохраняется как ручной выбор; чтобы снова следовать серверу,
  выберите As subscription.
- **Auto-узел папки правится в Node Settings (задача 686).** Тап открывает
  форму группы на вкладке **Settings** (имя, серверы пула, режим,
  дополнительно); **Source** показывает хранимую запись и правится; вкладка
  **JSON** пишет «Members are resolved at build time» вместо пустого
  `outbounds`. Раньше тап открывал пустой Source, имя не сохранялось, а JSON
  не показывал членов. Превью пула больше не считает выключенные серверы и
  помечает их ⏻.
- **Меню долгого тапа больше не дублирует Node Settings (задача 686).**
  **Edit…** у члена папки и **Edit source…** / **Update** у отдельного
  сервера сняты; тап открывает тот же экран.
- **Комментарии `#` во вставленном JSON (задача 686).** JSON узла и экран
  Config принимают комментарии `#` до конца строки, как ядро, наряду с `//`
  и `/* */`; снимаются так же.
- **Редактор направления:** подпись под **Replace groups** объясняет галку —
  отмеченная группа входит, даже если фильтр её не пропускает, и встаёт выше
  серверов; в auto-группу направления группы не входят.

## 🩹 Исправлено

- Редактор правил фильтра подписки показывал «Совпадений: из узлов» без
  чисел; сообщение «Applied — …» после сохранения фильтров теряло их тоже.
- Задержка узла пишется `120ms`, а не `120MS`.

## 🔧 Под капотом

- **Ядро `v1.14.3-lx.23` → `v1.14.3-lx.24-rc.1`.** Добавлена активная
  проверка соединения (`CommandClient.startConnectionTest`,
  Leadaxe/sing-box-lx#59) и исправлена гонка данных при выборе узла в группе
  Auto (`urltest`). Конфиг не меняется. Java-поверхность только растёт
  (258 → 270 классов).
- Контракт 1.1.140: несколько секций `[Peer]` в INI (`repeat each`,
  `wgconf_peer_dropped`).
- Среди новых тестов: трасса проверки соединения (дерево, порядок по времени
  старта, итог, ошибка потока, текстовая выгрузка, нормализация URL).

</details>

---

## Install / Установка

```bash
adb install -r LxBox-v2.25.18-rc.1-arm64-v8a.apk
```

Без uninstall! Поверх существующей установки. Настройки и подписки сохранятся.

No uninstall needed — install over the existing one. Settings and subscriptions
are preserved.

---

Previous release / Предыдущий релиз: [v2.25.17](docs/releases/v2.25.17.md).
