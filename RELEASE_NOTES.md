# L×Box v2.25.14-rc.1

**A release candidate on top of [v2.25.13](https://github.com/Leadaxe/LxBox/releases/tag/v2.25.13).**

This is a pre-release on GitHub; in Google Play it goes to Open testing. It is
not offered to users of the stable release.

TLS fragmentation and mixed-case SNI can be set per server, folder and
subscription. Quit & reopen app stops the VPN for good and leaves no VPN
notification behind. The start error notification goes away after a
successful start. Core `v1.14.3-lx.15` and contract 1.1.115 are unchanged.

**Релиз-кандидат поверх [v2.25.13](https://github.com/Leadaxe/LxBox/releases/tag/v2.25.13).**

На GitHub это pre-release, в Google Play сборка уходит в открытое
тестирование. Пользователям стабильного релиза она не предлагается.

Фрагментацию TLS и mixed-case SNI можно задать для сервера, папки и
подписки. «Quit & reopen app» останавливает VPN окончательно и не оставляет
уведомление VPN в шторке. Уведомление об ошибке старта снимается после
успешного старта. Ядро `v1.14.3-lx.15` и контракт 1.1.115 без изменений.

---

<details open>
<summary><h2>🇬🇧 English</h2></summary>

## ✨ Added

- **TLS options per server, folder and subscription ([task 636](docs/spec/tasks/636-tls-settings-per-node-folder-subscription.md)).**
  The four TLS Fragmentation options (TLS Fragment, TLS Record Fragment,
  Fallback delay, Mixed-case SNI) get a **TLS** section on a server's
  Settings tab and on a subscription's or folder's settings tab.
  - Each option resolves server → subscription/folder → global. Default
    inherits; Off on a lower level beats On above it.
  - A checkbox set on a REALITY server itself fragments it; the folder,
    subscription and global levels still skip REALITY.
  - Ping and the node test use the same levels.
  - A server's own TLS settings move with it on Ungroup and when it is moved
    into a folder.
  - The per-server and per-source settings are not saved into the backup file
    yet; the export lists them as left out. On merge the device keeps its own.
  - Debug API returns the `tls` field of a source and a folder member and
    accepts a partial PATCH.

## 🔄 Changed

- **MASQUE recommended SNI is `www.cloudflare.com` ([task 638](docs/spec/tasks/638-audit-591-four-defects.md)).**
  With `consumer-masque.cloudflareclient.com` h3 does not come up on Russian
  networks. The old domain stays in the SNI pool for scanning.

## 🩹 Fixed

- **Quit & reopen app no longer brings the VPN back ([task 638](docs/spec/tasks/638-audit-591-four-defects.md)).**
  Quit killed the process but kept the "VPN wanted" flag and the watchdog
  alarm, so 2–3 minutes later the watchdog started the VPN again. Quit now
  clears both.
- **Quit & reopen app leaves no VPN notification ([task 639](docs/spec/tasks/639-quit-clears-vpn-notification.md)).**
  The service died together with the process, and its notification stayed in
  the shade showing a VPN that was not running. Quit now stops the service the
  same way as Stop (waiting up to 3 s), then closes the app.
- **The start error notification goes away after a successful start ([task 637](docs/spec/tasks/637-clear-error-notification-on-successful-start.md)).**
  When the core rejected a node, the app disabled the node and started again;
  the start succeeded, but "Error" stayed next to the VPN notification. It is
  now removed when the service starts and when you start the VPN again. A new
  failure shows a new one.
- **The chain delete dialog tells what happens ([task 638](docs/spec/tasks/638-audit-591-four-defects.md)).**
  It said other chains would stop building. In fact the node is removed from
  them and they are rebuilt shorter. New text: "Chains using this node will be
  rebuilt without it."
- **Intent API `VPN_ERROR(tunnel_error)` hides server addresses ([task 638](docs/spec/tasks/638-audit-591-four-defects.md)).**
  The core's error text (`dial tcp <ip>:<port>: …`) reached every subscriber
  of the broadcast. IPv4, IPv6 and host names in it are now replaced with
  `***`; the port and the rest of the text stay. Other error codes are
  unchanged.

## 📚 Documentation

- The spec audit is closed ([task 591](docs/spec/tasks/591-spec-kit-revision-audit.md)):
  about 85 feature spec files now describe the app as it behaves.

## 🔧 Under the hood

- Core `v1.14.3-lx.15` and launcher contract 1.1.115, unchanged from v2.25.13.
- New tests: return to the home screen, the config mtime flag, the rule-set
  auto-update schedule, LX backup import into a fresh state, the update check;
  TLS codec, backup slice and merge, probe by levels; address masking in
  `VPN_ERROR`.

</details>

<details open>
<summary><h2>🇷🇺 Русский</h2></summary>

## ✨ Добавлено

- **Настройки TLS на сервере, папке и подписке ([задача 636](docs/spec/tasks/636-tls-settings-per-node-folder-subscription.md)).**
  Четыре опции TLS Fragmentation (TLS Fragment, TLS Record Fragment,
  Fallback delay, Mixed-case SNI) получили секцию **TLS** на вкладке Settings
  сервера и на вкладке настроек подписки или папки.
  - Каждая опция решается в порядке сервер → подписка/папка → глобально.
    Default наследует; Off на нижнем уровне бьёт On на верхнем.
  - Галка на самом сервере REALITY его фрагментирует; уровни папки,
    подписки и глобальный REALITY по-прежнему пропускают.
  - Пинг и тест узла учитывают те же уровни.
  - Свои настройки TLS сервера переезжают с ним при Ungroup и при переносе
    в папку.
  - Настройки сервера и источника пока не попадают в файл бэкапа; экспорт
    называет их в списке пропущенного. При слиянии на устройстве остаются
    свои.
  - Debug API отдаёт поле `tls` источника и члена папки и принимает
    частичный PATCH.

## 🔄 Изменено

- **Рекомендованный SNI для MASQUE — `www.cloudflare.com` ([задача 638](docs/spec/tasks/638-audit-591-four-defects.md)).**
  С `consumer-masque.cloudflareclient.com` h3 не поднимается в российских
  сетях. Прежний домен остался в пуле SNI для перебора.

## 🩹 Исправлено

- **«Quit & reopen app» больше не воскрешает VPN ([задача 638](docs/spec/tasks/638-audit-591-four-defects.md)).**
  Quit убивал процесс, но оставлял признак «VPN желателен» и будильник
  сторожа, и через 2–3 мин сторож поднимал VPN снова. Теперь Quit снимает
  и то, и другое.
- **После «Quit & reopen app» не остаётся уведомление VPN ([задача 639](docs/spec/tasks/639-quit-clears-vpn-notification.md)).**
  Сервис умирал вместе с процессом, и его уведомление оставалось в шторке —
  VPN «работал», хотя его не было. Теперь Quit останавливает сервис так же,
  как Stop (ждёт до 3 с), и затем закрывает приложение.
- **Уведомление об ошибке старта снимается после успешного старта ([задача 637](docs/spec/tasks/637-clear-error-notification-on-successful-start.md)).**
  Когда ядро отвергало узел, приложение отключало его и стартовало снова;
  старт удавался, но «Error» висело рядом с уведомлением VPN. Теперь оно
  снимается, когда сервис запустился, и при новом запуске VPN. Новый отказ
  покажет новое уведомление.
- **Диалог удаления цепочки говорит, что будет ([задача 638](docs/spec/tasks/638-audit-591-four-defects.md)).**
  Он обещал, что другие цепочки перестанут собираться. На деле узел из них
  убирается, и они собираются укороченными. Новый текст: «Chains using this
  node will be rebuilt without it.»
- **Событие Intent API `VPN_ERROR(tunnel_error)` скрывает адреса серверов ([задача 638](docs/spec/tasks/638-audit-591-four-defects.md)).**
  Текст ошибки ядра (`dial tcp <ip>:<port>: …`) уходил всем подписчикам
  broadcast. IPv4, IPv6 и имена хостов в нём теперь заменяются на `***`;
  порт и остальной текст остаются. Другие коды ошибок не тронуты.

## 📚 Документация

- Аудит спек закрыт ([задача 591](docs/spec/tasks/591-spec-kit-revision-audit.md)):
  около 85 файлов спек фич описывают приложение таким, какое оно есть.

## 🔧 Под капотом

- Ядро `v1.14.3-lx.15` и контракт лаунчера 1.1.115 — без изменений с v2.25.13.
- Новые тесты: возврат на главный экран, mtime-флаг конфига, расписание
  автообновления наборов правил, импорт бэкапа LX в чистое состояние,
  проверка обновлений; кодек TLS, срез и слияние бэкапа, проба по уровням;
  маска адресов в `VPN_ERROR`.

</details>

---

## Install / Установка

```bash
adb install -r LxBox-v2.25.14-rc.1-arm64-v8a.apk
```

Без uninstall! Поверх существующей установки. Настройки и подписки сохранятся.

No uninstall needed — install over the existing one. Settings and subscriptions
are preserved.

---

Previous release / Предыдущий релиз: [v2.25.13](docs/releases/v2.25.13.md).
