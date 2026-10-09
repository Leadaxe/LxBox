# L×Box v2.25.12-rc.1

**A release candidate on top of [v2.25.11](https://github.com/Leadaxe/LxBox/releases/tag/v2.25.11).**

This is a pre-release on GitHub; in Google Play it goes to Open testing. It is
not offered to users of the stable release.

Core release candidate `v1.14.2-lx.13-rc.1`: the AWG masquerade decoy
`ip=quic` is built fresh for every handshake, and the `ib=chrome` /
`ib=firefox` profiles are real QUIC ClientHellos. The direct outbound gets a
connect timeout setting with a 15s default.

**Релиз-кандидат поверх [v2.25.11](https://github.com/Leadaxe/LxBox/releases/tag/v2.25.11).**

На GitHub это pre-release, в Google Play сборка уходит в открытое
тестирование. Пользователям стабильного релиза она не предлагается.

Релиз-кандидат ядра `v1.14.2-lx.13-rc.1`: decoy маскировки AWG `ip=quic`
собирается заново на каждый хендшейк, профили `ib=chrome` / `ib=firefox`
стали настоящими QUIC ClientHello. У прямого выхода появилась настройка
таймаута соединения, по умолчанию 15 с.

---

<details open>
<summary><h2>🇬🇧 English</h2></summary>

## ⚠️ Read before updating

- **Core release candidate `v1.14.2-lx.13-rc.1` (from lx.12, [docs/KERNEL.md](docs/KERNEL.md)).**
  It changes the packets of AWG masquerade `ip=quic` (WARP wizard nodes and
  any node with `ip=quic`):
  - The decoy is generated before every handshake: a new QUIC Initial with
    fresh connection IDs, random and key share on each start, rekey, wake
    and reconnect. Before, the node sent the same datagram with the same
    DCID for its whole lifetime, a fixed fingerprint on the wire.
  - `ib=chrome` and `ib=firefox` are real QUIC ClientHellos of the browser.
    Before, a TCP ClientHello sat inside the QUIC Initial, with TLS 1.2
    ciphers and no QUIC transport parameters. The profiles are calibrated
    against Chrome 147/155 and Firefox 149 captures, for packet shape parity
    with the browser.
  - `ip=sip` sends only INVITE (a client never sends `100 Trying`);
    `ip=dns` sends EDNS without options.
  - The core's new value `ib=chrome-full` is not supported by the app yet: a
    node with it gets the value dropped with a warning.

  This core is a release candidate too: the field run of `chrome-full` did
  not happen before its tag.

## ✨ Added

- **Direct connect timeout for `direct-out` ([task 616](docs/spec/tasks/616-direct-connect-timeout.md)).**
  The connect timeout of the direct outbound is a setting now: Traffic
  Processing → Params → Direct connect timeout, presets 5s–2m or any
  duration. The default is 15s instead of the core's 5s, so apps on
  networks that lose SYN packets (e.g. T-Bank over Tele2) no longer get
  their connections cut. Proxy nodes and auto groups are unchanged.

## 🔧 Under the hood

- Core `v1.14.2-lx.13-rc.1` (from lx.12); the Java surface of the core is
  unchanged for the app.
- Release candidates now land in Google Play Open testing
  ([task 619](docs/spec/tasks/619-rc-to-play-open-testing.md)).

</details>

<details open>
<summary><h2>🇷🇺 Русский</h2></summary>

## ⚠️ Прочтите до обновления

- **Релиз-кандидат ядра `v1.14.2-lx.13-rc.1` (было lx.12, [docs/KERNEL.md](docs/KERNEL.md)).**
  Меняются пакеты маскировки AWG `ip=quic` (узлы мастера WARP и любой узел
  с `ip=quic`):
  - Decoy собирается перед каждым хендшейком: новый QUIC Initial со свежими
    идентификаторами соединения, random и key share при каждом старте,
    rekey, пробуждении и переподключении. Раньше узел весь срок жизни слал
    одну и ту же датаграмму с тем же DCID — постоянный отпечаток в сети.
  - `ib=chrome` и `ib=firefox` — настоящие QUIC ClientHello браузера.
    Раньше внутри QUIC Initial лежал TCP ClientHello с шифрами TLS 1.2 и без
    транспортных параметров QUIC. Профили откалиброваны по захватам
    Chrome 147/155 и Firefox 149 — форма пакета как у браузера.
  - `ip=sip` шлёт только INVITE (клиент `100 Trying` не шлёт); `ip=dns` —
    EDNS без опций.
  - Новое значение ядра `ib=chrome-full` приложение пока не поддерживает: у
    узла с ним значение снимается с предупреждением.

  Ядро тоже релиз-кандидат: полевой прогон `chrome-full` до его тега не
  состоялся.

## ✨ Добавлено

- **Таймаут соединения прямого выхода `direct-out` ([задача 616](docs/spec/tasks/616-direct-connect-timeout.md)).**
  Таймаут соединения прямого выхода вынесен в настройку: Traffic
  Processing → Params → Direct connect timeout, пресеты 5s–2m или любая
  длительность. По умолчанию 15 с вместо 5 с ядра, поэтому приложения в
  сетях с потерей SYN (например, Т‑Банк через Tele2) больше не обрываются.
  Прокси-узлы и авто-группы не затронуты.

## 🔧 Под капотом

- Ядро `v1.14.2-lx.13-rc.1` (было lx.12); Java-поверхность ядра для
  приложения не изменилась.
- Релиз-кандидаты теперь уходят в открытое тестирование Google Play
  ([задача 619](docs/spec/tasks/619-rc-to-play-open-testing.md)).

</details>

---

## Install / Установка

```bash
adb install -r LxBox-v2.25.12-rc.1-arm64-v8a.apk
```

Без uninstall! Поверх существующей установки. Настройки и подписки сохранятся.

No uninstall needed — install over the existing one. Settings and subscriptions
are preserved.

---

Previous release / Предыдущий релиз: [v2.25.11](docs/releases/v2.25.11.md).
