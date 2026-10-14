# L×Box v2.25.15

**A patch on top of [v2.25.14](https://github.com/Leadaxe/LxBox/releases/tag/v2.25.14).**
Part of it went to Open testing as `v2.25.15-rc.1`.

The Network tab of a Tailscale node shows how each device is reached:
directly or through a relay, with the address and the relay region. The path
was meant to be there since v2.25.11 but never appeared. Device rows are
shorter, all addresses are listed, and the tab refreshes on its own while it
is open. Default routing presets are on right after install. Core
`v1.14.3-lx.18` and contract 1.1.119 are unchanged.

**Патч поверх [v2.25.14](https://github.com/Leadaxe/LxBox/releases/tag/v2.25.14).**
Часть изменений выходила в Open testing как `v2.25.15-rc.1`.

Вкладка Network узла Tailscale показывает, как связано каждое устройство:
напрямую или через ретранслятор, с адресом и регионом ретранслятора. Путь
должен был показываться с v2.25.11, но не появлялся никогда. Строки устройств
стали короче, видны все адреса, вкладка обновляется сама, пока открыта.
Дефолтные пресеты маршрутизации включаются сразу после установки. Ядро
`v1.14.3-lx.18` и контракт 1.1.119 без изменений.

---

<details open>
<summary><h2>🇬🇧 English</h2></summary>

## 🔄 Changed

- **Tailscale Network tab: how each device is reached ([task 645](docs/spec/tasks/645-tailscale-devices-path-addresses.md)).**
  Each device in **Devices** has a third line with the path: a green bolt and
  `direct <ip:port>` when packets go straight to the device, an orange cloud
  and `relay <region>` through a Tailscale DERP server, an orange hub and
  `peer relay` through one of your own devices. A device that is offline shows
  `last seen 33h ago` instead of a date, plus `key expired` when it applies.
  The chosen exit node shows its path with the same icon.
- **Shorter device rows, all addresses.** The name and the first address are
  on the first line, the OS and roles (`exit node`, `shared`) with the second
  address on the second. More than two addresses fold into `+N`; a tap opens
  the rest. The MagicDNS name moved into the device menu (**Copy MagicDNS
  name**), and **Copy address** is offered for every address. The section
  header counts devices: `Devices · 2 online / 6`.
- **This device** lists its addresses under one **Address** heading.
- **The tab refreshes itself.** While the Network tab is open and the VPN is
  on, it asks the core for the full status every 3 seconds, so the path and
  the device list are current from the first second rather than waiting for
  the next status event. With an older core the tab works as before.

## 🩹 Fixed

- **The connection path never appeared (task 645).** Since v2.25.11 the core
  reported the path in lower case (`direct`, `peer_relay`, `derp`) and the app
  compared it with upper case, so the path line was always empty. It now
  matches regardless of case.
- **Default routing presets are on right after install ([task 644](docs/spec/tasks/644-default-presets-seed-before-routing.md)).**
  Presets the template enables by default (Russia-only services, BitTorrent,
  Tailscale networks, Unknown traffic, VoWiFi) reached the config only after
  the Routing screen was opened once. A node added and connected before that
  ran without them. They are now seeded at app start and before the config is
  built, once per install. A preset you removed does not come back.

## 📚 Documentation

- The template feature spec (024) is updated to contract 1.1.119.
- The Tailscale feature spec (030) describes the new Network tab.

## 🔧 Under the hood

- Core `v1.14.3-lx.18` and launcher contract 1.1.119, unchanged from v2.25.14.
- The app calls the core's one-shot `GetTailscaleStatus`; the stream and the
  call share one converter on the Android side.
- New tests: path text and icon for every path, the address column for 0–3
  addresses, the 3-second refresh (start, stop, old core, overlapping calls),
  path parsing in both cases, default presets on a clean install.
- `scripts/debug-api-swap-tailscale.sh` adds a Tailscale node with an auth key
  through the Debug API and switches the old one off; the key is typed in by
  hand.

</details>

<details open>
<summary><h2>🇷🇺 Русский</h2></summary>

## 🔄 Изменено

- **Вкладка Network узла Tailscale: как связано каждое устройство ([задача 645](docs/spec/tasks/645-tailscale-devices-path-addresses.md)).**
  У каждого устройства в **Devices** третья строка с путём: зелёная молния и
  `direct <ip:port>`, когда пакеты идут прямо до устройства; оранжевое облако
  и `relay <регион>` — через сервер DERP Tailscale; оранжевый хаб и
  `peer relay` — через одно из ваших устройств. У устройства не в сети —
  `last seen 33h ago` вместо даты и `key expired`, если ключ истёк. Выбранный
  exit node показывает путь с той же иконкой.
- **Строки устройств короче, видны все адреса.** На первой строке имя и
  первый адрес, на второй ОС и роли (`exit node`, `shared`) со вторым адресом.
  Больше двух адресов сворачиваются в `+N`, тап раскрывает остальные.
  MagicDNS-имя переехало в меню устройства (**Copy MagicDNS name**), **Copy
  address** есть для каждого адреса. В заголовке секции счётчик:
  `Devices · 2 online / 6`.
- **This device** перечисляет адреса под одним заголовком **Address**.
- **Вкладка обновляется сама.** Пока вкладка Network открыта и VPN включён,
  она раз в 3 секунды запрашивает у ядра полный статус, поэтому путь и список
  устройств актуальны с первой секунды, без ожидания следующего события
  статуса. Со старым ядром вкладка работает как раньше.

## 🩹 Исправлено

- **Путь соединения не показывался никогда (задача 645).** С v2.25.11 ядро
  отдавало путь строчными буквами (`direct`, `peer_relay`, `derp`), а
  приложение сравнивало с заглавными, и строка пути всегда была пустой.
  Теперь регистр не важен.
- **Дефолтные пресеты маршрутизации включаются сразу после установки ([задача 644](docs/spec/tasks/644-default-presets-seed-before-routing.md)).**
  Пресеты, включённые в шаблоне по умолчанию (Russia-only services,
  BitTorrent, Tailscale networks, Unknown traffic, VoWiFi), попадали в конфиг
  только после первого открытия экрана Routing. Узел, добавленный и
  подключённый до этого, шёл без них. Теперь они засеваются при старте
  приложения и перед сборкой конфига, один раз на установку. Удалённый
  пресет не возвращается.

## 📚 Документация

- Спека фичи шаблона (024) приведена к контракту 1.1.119.
- Спека фичи Tailscale (030) описывает новую вкладку Network.

## 🔧 Под капотом

- Ядро `v1.14.3-lx.18` и контракт лаунчера 1.1.119 — без изменений с v2.25.14.
- Приложение вызывает одиночный `GetTailscaleStatus` ядра; поток и вызов
  разбирает один конвертер на стороне Android.
- Новые тесты: текст и иконка для каждого пути, столбец адресов для 0–3
  адресов, обновление раз в 3 секунды (старт, стоп, старое ядро, наложение
  вызовов), разбор пути в обоих регистрах, дефолтные пресеты на чистой
  установке.
- `scripts/debug-api-swap-tailscale.sh` добавляет узел Tailscale с auth key
  через Debug API и выключает старый; ключ вводится руками.

</details>

---

## Install / Установка

```bash
adb install -r LxBox-v2.25.15-arm64-v8a.apk
```

Без uninstall! Поверх существующей установки. Настройки и подписки сохранятся.

No uninstall needed — install over the existing one. Settings and subscriptions
are preserved.

---

Previous release / Предыдущий релиз: [v2.25.14](docs/releases/v2.25.14.md).
