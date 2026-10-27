# L×Box v2.25.18-rc.2

**The second release candidate on top of [v2.25.17](https://github.com/Leadaxe/LxBox/releases/tag/v2.25.17).**

This is a pre-release on GitHub; in Google Play it goes to Open testing. It is
not offered to users of the stable release. It contains everything from
[v2.25.18-rc.1](https://github.com/Leadaxe/LxBox/releases/tag/v2.25.18-rc.1);
below are the changes since rc.1.

URL Check explains itself: every step expands with a line on what the step is
and why it was skipped or reused, lines connect each step to its parent, and
the app's DNS query shows the answer record by record — the CNAME chain,
addresses with TTL, HTTPS record parameters, the SOA of a missing name, and
whether the answer came from the network, the cache or a local answer. Core
`v1.14.3-lx.24-rc.2`.

**Второй релиз-кандидат поверх [v2.25.17](https://github.com/Leadaxe/LxBox/releases/tag/v2.25.17).**

На GitHub это pre-release, в Google Play сборка уходит в открытое
тестирование. Пользователям стабильного релиза она не предлагается. В нём
всё из [v2.25.18-rc.1](https://github.com/Leadaxe/LxBox/releases/tag/v2.25.18-rc.1);
ниже — изменения относительно rc.1.

URL Check объясняет себя сам: любой шаг раскрывается со строкой о том, что
это за шаг и почему он пропущен или взят готовым, линии соединяют шаг с
родителем, а DNS-запрос приложения показывает ответ по записям — цепочку
CNAME, адреса с TTL, параметры HTTPS-записи, SOA несуществующего имени и
откуда ответ: из сети, из кэша или локальный. Ядро `v1.14.3-lx.24-rc.2`.

---

<details open>
<summary><h2>🇬🇧 English</h2></summary>

## ⚠️ Read before updating

- **The core is still a release candidate.** `v1.14.3-lx.24-rc.2` adds the
  full DNS answer to the connection test behind URL Check; the stable core
  `lx.24` follows a field run.

## ✨ New

- **URL Check: step details ([task 688](docs/spec/tasks/688-url-check-stage-details.md)).**
  Every step has a chevron and expands, not only steps with attributes.
  Inside:
  - a line on what the step is ("TLS handshake with the server", "Resolving
    the server address of a node or DNS server", …);
  - why it ended that way: "Not run: tls … failed" for steps after the
    break, "Reused: an open connection or a cached answer", "Sent; the
    protocol gives no confirmation";
  - the step's attributes and error.
- **URL Check: the DNS answer record by record (task 688, Leadaxe/sing-box-lx#59).**
  The app's DNS query lists the answer one record per line with TTL: the
  CNAME chain, each address with the name it belongs to, HTTPS record
  parameters such as `alpn` and `ech`. On NXDOMAIN or an empty answer the
  **Authority** block shows the SOA. A line says where the answer came from:
  **From the network**, **From cache, N old** (marked when the record expired
  and is being refreshed) or **Local answer: fake IP or hosts**.

## 🔄 Changed

- **URL Check: the tree is drawn with lines.** Each step is connected to its
  parent, so a node's lookup, its DNS server and that server's detour read as
  one branch.
- **URL Check: what opens by itself.** The step where the path broke and an
  app DNS query with an error code or an empty answer are expanded without a
  tap; an error code other than `NOERROR` is shown in the step's row. A tap
  on a finding highlights and expands the steps it refers to.

## 🔧 Under the hood

- Core `v1.14.3-lx.24-rc.2` (was `rc.1`): SPEC 139 release 2, stage
  attributes only (`answer`, `authority`, `source`, `cache_age`, `stale`).
  The Java surface of the core did not change.

</details>

<details open>
<summary><h2>🇷🇺 Русский</h2></summary>

## ⚠️ Прочтите до обновления

- **Ядро всё ещё релиз-кандидат.** `v1.14.3-lx.24-rc.2` добавляет в проверку
  соединения за URL Check полный ответ DNS; стабильное ядро `lx.24` выйдет
  после полевой проверки.

## ✨ Новое

- **URL Check: подробности шагов ([задача 688](docs/spec/tasks/688-url-check-stage-details.md)).**
  У каждого шага есть шеврон, раскрывается любой шаг, а не только шаг с
  атрибутами. Внутри:
  - строка о том, что это за шаг («TLS handshake with the server»,
    «Resolving the server address of a node or DNS server», …);
  - почему такой исход: «Not run: tls … failed» у шагов после обрыва,
    «Reused: an open connection or a cached answer», «Sent; the protocol
    gives no confirmation»;
  - атрибуты шага и ошибка.
- **URL Check: ответ DNS по записям (задача 688, Leadaxe/sing-box-lx#59).**
  DNS-запрос приложения показывает ответ по записи на строку с TTL: цепочку
  CNAME, каждый адрес с именем, которому он принадлежит, параметры
  HTTPS-записи вроде `alpn` и `ech`. При NXDOMAIN или пустом ответе блок
  **Authority** показывает SOA. Строка говорит, откуда ответ: **From the
  network**, **From cache, N old** (с пометкой, если запись просрочена и
  обновляется) или **Local answer: fake IP or hosts**.

## 🔄 Изменено

- **URL Check: дерево нарисовано линиями.** Каждый шаг соединён с родителем,
  так что резолв адреса узла, его DNS-сервер и detour этого сервера читаются
  одной веткой.
- **URL Check: что раскрыто сразу.** Шаг обрыва и DNS-запрос приложения с
  кодом ошибки или пустым ответом раскрыты без тапа; код, отличный от
  `NOERROR`, виден в строке шага. Тап по находке подсвечивает и раскрывает
  её шаги.

## 🔧 Под капотом

- Ядро `v1.14.3-lx.24-rc.2` (было `rc.1`): SPEC 139 релиз 2, только
  атрибуты стадий (`answer`, `authority`, `source`, `cache_age`, `stale`).
  Java-поверхность ядра не изменилась.

</details>

---

## Install / Установка

```bash
adb install -r LxBox-v2.25.18-rc.2-arm64-v8a.apk
```

Без uninstall! Поверх существующей установки. Настройки и подписки сохранятся.

No uninstall needed — install over the existing one. Settings and subscriptions
are preserved.

---

Previous release / Предыдущий релиз: [v2.25.18-rc.1](https://github.com/Leadaxe/LxBox/releases/tag/v2.25.18-rc.1) · stable / стабильный: [v2.25.17](docs/releases/v2.25.17.md).
