# L×Box v2.25.14

**A patch on top of [v2.25.13](https://github.com/Leadaxe/LxBox/releases/tag/v2.25.13).**
Part of it went to Open testing as `v2.25.14-rc.1`.

TLS fragmentation and mixed-case SNI can be set per server, folder and
subscription, and the setting travels in the backup. A Transfer to desktop
file without rules no longer wipes the rules, and the import screen says
what happens to them. Quit & reopen app stops the VPN for good. In an
imported sing-box config a node with a broken `detour` chain is dropped
instead of connecting directly; Hysteria v1 is rejected with a hint. The URL
test gets two YouTube addresses. Core `v1.14.3-lx.18`, contract 1.1.118.

**Патч поверх [v2.25.13](https://github.com/Leadaxe/LxBox/releases/tag/v2.25.13).**
Часть изменений выходила в Open testing как `v2.25.14-rc.1`.

Фрагментацию TLS и mixed-case SNI можно задать для сервера, папки и
подписки, настройка едет в бэкапе. Файл Transfer to desktop без правил больше
не стирает правила, а экран импорта говорит, что с ними будет. Quit & reopen
app останавливает VPN окончательно. В импортированном конфиге sing-box узел с
битой цепочкой `detour` отбрасывается, а не идёт напрямую; Hysteria v1
отклоняется с подсказкой. В URL-тесте два адреса YouTube. Ядро
`v1.14.3-lx.18`, контракт 1.1.118.

---

<details open>
<summary><h2>🇬🇧 English</h2></summary>

## ⚠️ Read before updating

- **A MASQUE node written by hand with the `network` key stops loading.**
  The core removed the old `network` key of the `masque` outbound: it
  duplicated `vhttp` (h3/h2) under a name that means the tcp/udp list on every
  other outbound. The app has always written `vhttp` and nodes from links and
  subscriptions are not affected. If you pasted a sing-box body with
  `"network": "h3"` yourself, the core rejects it at start and the app
  disables the node: rename the key to `vhttp`, the values are the same.
- **An imported sing-box node with a broken `detour` chain no longer connects.**
  Before, such a node silently went direct. Now it is dropped and listed among
  the subscription's dropped entries with the reason. Check that list if a
  node from a sing-box config is missing.

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
  - The per-server and per-source settings travel in the Transfer to desktop
    file (contract 1.1.117). On merge the device keeps its own.
  - Debug API returns the `tls` field of a source and a folder member and
    accepts a partial PATCH.
- **uTLS fingerprint `chrome_155` ([task 642](docs/spec/tasks/642-contract-1-1-118-sync.md)).**
  The Chrome 155 preset of the core is accepted in links and JSON and counts
  as a hybrid fingerprint under REALITY.
- **YouTube addresses in the URL test.**
  Ping Settings and the Test URL of the auto group offer two more presets:
  YouTube (`https://www.youtube.com/generate_204`) and YouTube (ytimg)
  (`https://i.ytimg.com/generate_204`).

## 🔄 Changed

- **A node with a broken `detour` chain is dropped instead of connecting directly ([task 642](docs/spec/tasks/642-contract-1-1-118-sync.md)).**
  Contract 1.1.118: in an imported sing-box config, a node whose `detour`
  points to a missing tag, to a hop that did not become a node or to a group
  is not created, and every node of a `detour` loop is dropped. Each one is
  listed among the subscription's dropped entries with its tag and the
  reason. `detour: direct` and the 8-hop limit work as before.
- **Hysteria v1 is rejected with a hint ([task 642](docs/spec/tasks/642-contract-1-1-118-sync.md)).**
  A `hysteria://` / `hy://` link, a sing-box `type: hysteria` entry and an
  Xray `hysteria` element of version 1 are reported as an unsupported protocol
  with the hint to use hysteria2, instead of disappearing silently or as an
  unknown protocol.
- **TLS fragmentation skips QUIC nodes ([task 642](docs/spec/tasks/642-contract-1-1-118-sync.md)).**
  Hysteria, Hysteria2 and TUIC nodes no longer get the TLS Fragment / Record
  Fragment flags from any level: QUIC is not fragmented.
- **MASQUE `network` is no longer an old name of `vhttp` ([task 642](docs/spec/tasks/642-contract-1-1-118-sync.md)).**
  A link with `network=h2` gets the default h3 and the parameter is reported
  as unknown; the key is reserved for the tcp/udp list (contract 1.1.118).
- **MASQUE recommended SNI is `www.cloudflare.com` ([task 638](docs/spec/tasks/638-audit-591-four-defects.md)).**
  With `consumer-masque.cloudflareclient.com` h3 does not come up on Russian
  networks. The old domain stays in the SNI pool for scanning.

## 🩹 Fixed

- **A Transfer to desktop file without rules no longer wipes the rules ([task 640](docs/spec/tasks/640-backup-rules-key-absent-untouched.md)).**
  Contract 1.1.116: a file without the `rules` key (one server, a folder, a
  Direction) leaves the current rules as they were. A file with the key, even
  an empty one, replaces them as before, and the preview names how many rules
  are removed. Export always writes the key.
- **The Transfer to desktop import screen tells the truth about rules ([task 641](docs/spec/tasks/641-backup-import-ui-rules-replaced.md)).**
  The preview ends with "This file has no rules. The current rules stay.",
  "Importing adds the file's rules." or "Importing replaces the current N
  rule(s)." The result no longer counts replaced rules as "not applied" and
  says "replaced N rule(s)".
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

- **Core `v1.14.3-lx.15` → `v1.14.3-lx.18`** ([docs/KERNEL.md](docs/KERNEL.md)).
  lx.18 removes the legacy `network` key of the `masque` outbound (see "Read
  before updating"). lx.16 and lx.17 change only the Linux router daemon and
  the Windows 7 build; nothing of them is in the Android library. The Java
  surface is identical to lx.15.
- **Launcher contract 1.1.115 → 1.1.118.** 1.1.116: the `rules` key of the
  backup file is optional on import. 1.1.117: the `tls` field of a server and a
  source in the backup. 1.1.118: `detour` errors drop the node, Hysteria v1 is
  an unsupported protocol with an alternative, `chrome_155`, MASQUE `network`
  is not an alias of `vhttp`.
- New tests: return to the home screen, the config mtime flag, the rule-set
  auto-update schedule, LX backup import into a fresh state, the update check;
  TLS codec, backup slice and merge, probe by levels; address masking in
  `VPN_ERROR`; the `rules` key table; QUIC nodes without fragmentation.

</details>

<details open>
<summary><h2>🇷🇺 Русский</h2></summary>

## ⚠️ Прочтите до обновления

- **Узел MASQUE, вписанный руками с ключом `network`, перестаёт загружаться.**
  Ядро убрало старый ключ `network` у outbound `masque`: он дублировал `vhttp`
  (h3/h2) под именем, которое у всех остальных outbound означает список
  tcp/udp. Приложение всегда писало `vhttp`, узлы из ссылок и подписок это не
  затрагивает. Если вы сами вставили тело sing-box с `"network": "h3"`, ядро
  отвергнет его на старте, и приложение отключит узел: переименуйте ключ в
  `vhttp`, значения те же.
- **Импортированный узел sing-box с битой цепочкой `detour` больше не подключается.**
  Раньше такой узел молча шёл напрямую. Теперь он отбрасывается и попадает в
  отброшенные записи подписки с причиной. Если узла из конфига sing-box не
  видно, проверьте этот список.

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
  - Настройки сервера и источника едут в файле Transfer to desktop
    (контракт 1.1.117). При слиянии на устройстве остаются свои.
  - Debug API отдаёт поле `tls` источника и члена папки и принимает
    частичный PATCH.
- **Отпечаток uTLS `chrome_155` ([задача 642](docs/spec/tasks/642-contract-1-1-118-sync.md)).**
  Пресет Chrome 155 ядра принимается в ссылках и JSON и под REALITY считается
  гибридным.
- **Адреса YouTube в URL-тесте.**
  В Ping Settings и в Test URL авто-группы два новых пресета: YouTube
  (`https://www.youtube.com/generate_204`) и YouTube (ytimg)
  (`https://i.ytimg.com/generate_204`).

## 🔄 Изменено

- **Узел с битой цепочкой `detour` отбрасывается, а не идёт напрямую ([задача 642](docs/spec/tasks/642-contract-1-1-118-sync.md)).**
  Контракт 1.1.118: в импортированном конфиге sing-box узел, чей `detour`
  ведёт на несуществующий тег, на хоп, не ставший узлом, или на группу, не
  создаётся, а кольцо `detour` роняет всех участников. Каждый попадает в
  отброшенные записи подписки со своим тегом и причиной. `detour: direct` и
  предел в 8 звеньев — как прежде.
- **Hysteria v1 отклоняется с подсказкой ([задача 642](docs/spec/tasks/642-contract-1-1-118-sync.md)).**
  Ссылка `hysteria://` / `hy://`, запись sing-box `type: hysteria` и элемент
  Xray `hysteria` версии 1 помечаются как неподдерживаемый протокол с
  подсказкой «используйте hysteria2», а не пропадают молча или как
  неизвестный протокол.
- **Фрагментация TLS пропускает QUIC-узлы ([задача 642](docs/spec/tasks/642-contract-1-1-118-sync.md)).**
  Узлы Hysteria, Hysteria2 и TUIC больше не получают флаги TLS Fragment /
  Record Fragment ни с одного уровня: QUIC не фрагментируется.
- **`network` у MASQUE — больше не старое имя `vhttp` ([задача 642](docs/spec/tasks/642-contract-1-1-118-sync.md)).**
  Ссылка с `network=h2` получает дефолт h3, параметр помечается неизвестным;
  ключ зарезервирован под список tcp/udp (контракт 1.1.118).
- **Рекомендованный SNI для MASQUE — `www.cloudflare.com` ([задача 638](docs/spec/tasks/638-audit-591-four-defects.md)).**
  С `consumer-masque.cloudflareclient.com` h3 в российских сетях не
  поднимается. Прежний домен остался в пуле SNI для перебора.

## 🩹 Исправлено

- **Файл Transfer to desktop без правил больше не стирает правила ([задача 640](docs/spec/tasks/640-backup-rules-key-absent-untouched.md)).**
  Контракт 1.1.116: файл без ключа `rules` (один сервер, папка, Направление)
  оставляет текущие правила как были. Файл с ключом, даже пустым, замещает
  их, как и раньше, а превью называет, сколько правил будет снято. Экспорт
  пишет ключ всегда.
- **Экран импорта Transfer to desktop говорит правду о правилах ([задача 641](docs/spec/tasks/641-backup-import-ui-rules-replaced.md)).**
  Превью заканчивается фразой «This file has no rules. The current rules
  stay.», «Importing adds the file's rules.» или «Importing replaces the
  current N rule(s).». Итог больше не считает заменённые правила
  «не применёнными» и пишет «replaced N rule(s)».
- **Quit & reopen app больше не поднимает VPN обратно ([задача 638](docs/spec/tasks/638-audit-591-four-defects.md)).**
  Quit убивал процесс, но оставлял признак «VPN желателен» и будильник
  сторожа, и через 2–3 минуты сторож запускал VPN снова. Теперь Quit снимает
  оба.
- **Quit & reopen app не оставляет уведомление VPN ([задача 639](docs/spec/tasks/639-quit-clears-vpn-notification.md)).**
  Служба умирала вместе с процессом, а её уведомление оставалось в шторке и
  показывало VPN, которого нет. Теперь Quit останавливает службу так же, как
  Stop (ждёт до 3 с), и затем закрывает приложение.
- **Уведомление об ошибке старта снимается после успешного старта ([задача 637](docs/spec/tasks/637-clear-error-notification-on-successful-start.md)).**
  Когда ядро отвергало узел, приложение отключало его и стартовало снова;
  старт удавался, но «Error» висел рядом с уведомлением VPN. Теперь оно
  снимается, когда служба запустилась и когда вы запускаете VPN заново. Новая
  неудача показывает новое.
- **Диалог удаления цепочки говорит, что будет ([задача 638](docs/spec/tasks/638-audit-591-four-defects.md)).**
  Он утверждал, что другие цепочки перестанут собираться. На деле узел
  убирается из них, и они пересобираются короче. Новый текст: «Chains using
  this node will be rebuilt without it.»
- **`VPN_ERROR(tunnel_error)` в Intent API скрывает адреса серверов ([задача 638](docs/spec/tasks/638-audit-591-four-defects.md)).**
  Текст ошибки ядра (`dial tcp <ip>:<port>: …`) доходил до каждого
  подписчика broadcast. IPv4, IPv6 и имена хостов в нём теперь заменены на
  `***`; порт и остальной текст остаются. Другие коды ошибок не тронуты.

## 📚 Документация

- Аудит спек закрыт ([задача 591](docs/spec/tasks/591-spec-kit-revision-audit.md)):
  около 85 файлов спек фич приведены к тому, как приложение работает.

## 🔧 Под капотом

- **Ядро `v1.14.3-lx.15` → `v1.14.3-lx.18`** ([docs/KERNEL.md](docs/KERNEL.md)).
  lx.18 снимает устаревший ключ `network` у outbound `masque` (см. «Прочтите
  до обновления»). lx.16 и lx.17 меняют только Linux-демон для роутеров и
  сборку для Windows 7; в Android-библиотеке их нет. Java-поверхность
  идентична lx.15.
- **Контракт лаунчера 1.1.115 → 1.1.118.** 1.1.116: ключ `rules` файла
  бэкапа необязателен при импорте. 1.1.117: поле `tls` сервера и источника в
  бэкапе. 1.1.118: ошибки `detour` роняют узел, Hysteria v1 — неподдерживаемый
  протокол с альтернативой, `chrome_155`, `network` у MASQUE — не алиас
  `vhttp`.
- Новые тесты: возврат на главный, mtime-флаг конфига, расписание
  автообновления наборов, импорт бэкапа LX в чистое состояние, проверка
  обновлений; кодек TLS, срез и слияние бэкапа, проба по уровням; маска
  адресов в `VPN_ERROR`; таблица ключа `rules`; QUIC-узлы без фрагментации.

</details>

---

## Install / Установка

```bash
adb install -r LxBox-v2.25.14-arm64-v8a.apk
```

Без uninstall! Поверх существующей установки. Настройки и подписки сохранятся.

No uninstall needed — install over the existing one. Settings and subscriptions
are preserved.

---

Previous release / Предыдущий релиз: [v2.25.13](docs/releases/v2.25.13.md).
