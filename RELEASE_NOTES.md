# L×Box v2.25.19-rc.1

**A release candidate on top of [v2.25.18](https://github.com/Leadaxe/LxBox/releases/tag/v2.25.18).**

This is a pre-release on GitHub; in Google Play it goes to Open testing. It is
not offered to users of the stable release.

DNS gets a **Hosts** server type and a Hosts block in DNS groups: names with
your own addresses, answered before the group's servers, so a node address
like `wg.home` resolves to your LAN. Template DNS servers and groups are
editable again, and servers can be removed from Shield DNS. Routing rules can
match the network type (Wi-Fi, Cellular, Ethernet) and metered networks. A
WireGuard/AWG peer that gets no answer is shown as «no response» instead of
green. Stopping the VPN no longer hangs on a MASQUE node with a detour, and the
next start no longer fails with `initialize cache-file: timeout`. Default TUN
MTU is 9000. Core `v1.14.4-lx.28`, contract 1.1.145.

**Релиз-кандидат поверх [v2.25.18](https://github.com/Leadaxe/LxBox/releases/tag/v2.25.18).**

На GitHub это pre-release, в Google Play сборка уходит в открытое
тестирование. Пользователям стабильного релиза она не предлагается.

В DNS появился тип сервера **Hosts** и блок Hosts у DNS-групп: имена с вашими
адресами отвечаются раньше серверов группы, и адрес узла вроде `wg.home`
резолвится в вашу локальную сеть. Шаблонные DNS-серверы и группы снова
редактируются, из Shield DNS можно убрать сервер. Правила маршрутизации
различают тип сети (Wi-Fi, Cellular, Ethernet) и лимитные сети. Пир
WireGuard/AWG, которому не отвечают, показан как «no response», а не зелёным.
Остановка VPN больше не зависает на узле MASQUE с detour, а следующий запуск
не падает с `initialize cache-file: timeout`. MTU tun по умолчанию 9000. Ядро
`v1.14.4-lx.28`, контракт 1.1.145.

---

<details open>
<summary><h2>🇬🇧 English</h2></summary>

## ⚠️ Read before updating

- **Default TUN MTU is 9000 instead of 1492 ([task 700](docs/spec/tasks/700-tun-mtu-default-9000.md)).**
  9000 is the sing-box default. The tunnel interface is virtual and the core
  re-sends TCP at the real network MTU, so a small value only added packets
  and CPU work. Installs where MTU was never changed get 9000 with the next
  config build; a value set by hand stays.
- **DNS servers that something refers to are switched on.** A setup from
  older versions where a referenced DNS server is off (a group member, a
  domain resolver, DNS Final, Default Domain Resolver) is fixed on start: the
  server is switched on, and the app log says why.

## ✨ New

- **Hosts DNS server and Hosts in a DNS group ([task 699](docs/spec/tasks/699-dns-hosts-server-and-group-overlay.md), issue #185).**
  The DNS server editor gets a Hosts type: names with fixed IPv4/IPv6
  addresses, one row per name, edited in a dialog. A DNS group gets a Hosts
  block under Members: the names these servers know are answered first, all
  other names go to the members as before. Put such a group into Default
  Domain Resolver and a node address like `wg.home` resolves to your own
  addresses, with `strategy` choosing the family. A hosts server referenced
  by a group cannot be turned off or deleted. Renaming a DNS server now
  updates group members and Hosts too; a renamed member used to drop out of
  its group.
- **Rules by network type and metered networks ([task 694](docs/spec/tasks/694-rule-network-type-metered.md), issue #178).**
  The rule editor's Wi-Fi section is now «NETWORK»: Any / Wi-Fi / Cellular /
  Ethernet and a «Metered networks only» checkbox (mobile data and Wi-Fi
  marked as metered in Android). Neither needs the location permission that
  SSID matching requires; the SSID list is shown only for Wi-Fi. Rules are
  checked when a connection opens: on a switch between Wi-Fi and mobile data
  the app resets connections, so new ones follow the new network; when
  Android only flips the metered flag, open connections keep their earlier
  decision.
- **UID in the app picker ([task 693](docs/spec/tasks/693-app-picker-shared-uid-hint.md), issue #180).**
  Android lets several packages share one UID (on Samsung dozens of system
  apps live under UID 1000), and the core and the system's per-app VPN tell
  apps apart by UID, so a rule or a Tunnel apps entry for one package covers
  the whole group. Rows in the app picker and in Tunnel apps read «package ·
  UID n»; for a shared UID, «Shared with N other apps — they are routed
  together» opens the list. Rules and Tunnel apps work as before.
- **Ru internet segment: each Yandex DNS server can be turned off ([task 697](docs/spec/tasks/697-ru-direct-dns-servers-off.md), issue #183).**
  Next to «UDP server IP» there are «DoT server IP» and «DoH server IP»,
  and each of the three lists has «Off»: that server is not used and leaves
  the group. The address chooses the Yandex profile (Base, Safe or Family)
  for DoT and DoH as for UDP; before, both were fixed to Safe. With all
  three Off the preset's DNS works as with its DNS switch off. Defaults are
  unchanged.
- **Full-screen node filter picker in the Direction editor ([task 702](docs/spec/tasks/702-direction-node-filter-picker.md)).**
  A button to the right of Node filter opens a full screen: the regex field
  with `!`, the emoji found in node names with a count for each (a tap adds
  the emoji to the pattern, a second tap removes it), and the whole node list
  with matched nodes on top marked ✓ and the rest marked ✗. ✓ in the top bar
  puts the pattern back into the editor.
- **Debug API: the selected node of every group.** `GET /state` gets
  `group_selected`: group tag → the node the core has selected, for every
  selector and urltest group, not only for the Direction open on the home
  screen.

## 🔄 Changed

- **Template DNS servers and groups are editable ([task 695](docs/spec/tasks/695-dns-disabled-group-holds.md), issue #182).**
  The editor shows the same form as for your own servers below the
  variables; a changed server is saved as your copy under the same tag,
  marked «Overridden», and «Reset to template» in the ⋮ menu brings the
  template version back. DNS Final, Default Domain Resolver, a server's
  domain resolver and a group's members offer only enabled servers. A
  server that something refers to stays on and locked. Adding a server from
  the catalog also adds the servers it needs: the members of a group and its
  domain resolver. A disabled group with no enabled members cannot be
  switched on.

## 🐛 Fixed

- **A WireGuard/AWG peer showed «connected» when the server did not answer ([task 613](docs/spec/tasks/613-wg-peers-tailscale-path-health.md)).**
  The peer was green while its last handshake was under three minutes old,
  so a new server in the group the node goes through that passes no traffic,
  and a node just turned off and on, looked alive. Now a peer that sends but
  gets nothing back for about 8 seconds is orange, «no response». After the
  node is turned on or wakes up, the peer shows «never connected» until a new
  handshake, and ↓/↑ count only the current session.
- **Stopping the VPN hung on a MASQUE node with a detour.** When such a node
  (WARP over vless+ws, for example) was being pinged or connecting at that
  moment, the stop waited for it; the pending connection is now cancelled.
- **Start failed with `initialize cache-file: timeout` after a stop that hung ([task 703](docs/spec/tasks/703-cache-db-lock-timeout-retry.md)).**
  The new core instance now takes `cache.db` over by itself and keeps the
  group selection, FakeIP assignments and rule-set cache. If that still fails,
  the app deletes the file and retries the start once; force-stopping the app
  or clearing the DNS cache by hand is no longer needed.
- **The WARP endpoint picked in the wizard was replaced ([task 386](docs/spec/tasks/386-warp-endpoint-preset-combobox.md)).**
  A picked `engage.cloudflareclient.com:2408` no longer gets replaced by a
  random IP when obfuscation is on, by the address from Cloudflare's reply, or
  by the endpoint of a cached registration.
- **Route on the node screen did not follow the selector.** When the selected
  node of a group on the path changed elsewhere (home screen, Debug API, a
  urltest reselect), Route kept the old pick until the screen was reopened.
  Route and the checkmark in a group's member list now follow the core.
- **Servers could not be removed from Shield DNS.** After 2.25.17 the
  members of Shield DNS stayed locked «used by Shield DNS», and the group
  itself could not be edited (see Changed above).
- **A node row jumped in height while nodes were pinged.** The row of a node
  without a subtitle (`direct`, for example) collapsed and expanded with the
  ping badge; it now keeps its height.

## 🔧 Under the hood

- Core `v1.14.4-lx.25` → `v1.14.4-lx.28`: the `hosts` key of a DNS group
  (Leadaxe/sing-box-lx#60); MTU alignment: a proxy node inside a group no
  longer lowers the MTU of a tunnel above the group, tunnels carrying IPv6
  are never set below 1280; WireGuard/AWG peer status per session; a MASQUE
  dial with a detour is cancelled on stop; `cache.db` is taken over from a
  previous instance that hung while stopping.
- Contract 1.1.140 → 1.1.145: `trusttunnel` outbounds are judged by the
  registry (a node without `username`, `password` or `tls` is dropped at
  parse time, as in the launcher); backup import merges template and user
  DNS servers by tag; `tcp_multi_path` in a pasted sing-box node is kept as a
  known dialer field.

</details>

<details open>
<summary><h2>🇷🇺 Русский</h2></summary>

## ⚠️ Прочтите до обновления

- **MTU tun по умолчанию 9000 вместо 1492 ([задача 700](docs/spec/tasks/700-tun-mtu-default-9000.md)).**
  9000 — значение sing-box. Интерфейс туннеля виртуальный, ядро пересылает
  TCP по MTU настоящей сети, и малое значение только добавляло пакетов и
  работы процессору. Где MTU не меняли, 9000 встанет со следующей сборкой
  конфига; заданное вручную значение остаётся.
- **DNS-серверы, на которые есть ссылка, включаются.** Состояние из старых
  версий, где выключен DNS-сервер, на который ссылаются (член группы,
  резолвер домена, DNS Final, Default Domain Resolver), исправляется при
  запуске: сервер включается, причина пишется в лог приложения.

## ✨ Новое

- **Сервер Hosts и Hosts у DNS-группы ([задача 699](docs/spec/tasks/699-dns-hosts-server-and-group-overlay.md), issue #185).**
  В редакторе DNS-сервера есть тип Hosts: имена с заданными адресами
  IPv4/IPv6, строка на имя, правка в диалоге. У DNS-группы под Members
  появился блок Hosts: имена, которые знают эти серверы, отвечаются сразу,
  остальные уходят участникам, как раньше. Такая группа в Default Domain
  Resolver даёт узлу с адресом `wg.home` ваши адреса, семейство выбирает
  `strategy`. Сервер hosts, на который ссылается группа, нельзя выключить и
  удалить. Переименование DNS-сервера теперь переписывает членов и Hosts
  групп; раньше переименованный член выпадал из группы.
- **Правила по типу сети и лимитным сетям ([задача 694](docs/spec/tasks/694-rule-network-type-metered.md), issue #178).**
  Секция Wi-Fi в редакторе правила стала «NETWORK»: Any / Wi-Fi / Cellular /
  Ethernet и флажок «Metered networks only» (мобильные данные и Wi-Fi,
  отмеченные в Android как лимитные). Ни то, ни другое не требует
  разрешения на геолокацию, как условие по SSID; список SSID виден только
  при Wi-Fi. Правило проверяется при открытии соединения: при переходе
  между Wi-Fi и мобильной сетью приложение сбрасывает соединения, новые
  идут по новой сети; если Android только меняет флаг лимитности, открытые
  соединения живут со старым решением.
- **UID в пикере приложений ([задача 693](docs/spec/tasks/693-app-picker-shared-uid-hint.md), issue #180).**
  Android разрешает нескольким пакетам делить один UID (на Samsung под UID
  1000 живут десятки системных приложений), а ядро и системный per-app VPN
  различают приложения по UID, поэтому правило или запись Tunnel apps на
  один пакет действует на всю группу. Строки пикера и Tunnel apps
  показывают «пакет · UID n»; у общего UID строка «Shared with N other apps —
  they are routed together» открывает список. Правила и Tunnel apps работают
  как раньше.
- **Ru internet segment: любой DNS-сервер Яндекса можно выключить ([задача 697](docs/spec/tasks/697-ru-direct-dns-servers-off.md), issue #183).**
  Рядом с «UDP server IP» появились «DoT server IP» и «DoH server IP», в
  каждом из трёх списков есть «Off»: этот сервер не используется и выходит
  из группы. Адрес задаёт профиль Яндекса (Базовый, Безопасный или
  Семейный) у DoT и DoH так же, как у UDP; раньше оба были закреплены за
  Безопасным. Если выключены все три, DNS пресета работает как при
  выключенном тумблере DNS. Значения по умолчанию прежние.
- **Полноэкранный подбор фильтра узлов в редакторе Направления ([задача 702](docs/spec/tasks/702-direction-node-filter-picker.md)).**
  Кнопка справа от Node filter открывает экран: поле regex с `!`, эмодзи из
  имён узлов с числом узлов у каждого (тап добавляет эмодзи в паттерн,
  повторный убирает) и полный список узлов: совпавшие сверху с ✓,
  остальные с ✗. ✓ в верхней панели возвращает паттерн в редактор.
- **Debug API: выбранный узел каждой группы.** В `GET /state` добавлено поле
  `group_selected`: тег группы → узел, выбранный ядром, для каждой selector-
  и urltest-группы, а не только для Направления, открытого на главной.

## 🔄 Изменено

- **Шаблонные DNS-серверы и группы редактируются ([задача 695](docs/spec/tasks/695-dns-disabled-group-holds.md), issue #182).**
  В редакторе под переменными та же форма, что у своих серверов;
  изменённый сервер сохраняется своей копией под тем же тегом с пометкой
  «Overridden», «Reset to template» в меню ⋮ возвращает шаблонную версию.
  DNS Final, Default Domain Resolver, резолвер домена сервера и состав
  группы предлагают только включённые серверы. Сервер, на который есть
  ссылка, остаётся включённым и под замком. Добавление сервера из каталога
  добавляет и нужные ему серверы: участников группы и резолвер домена.
  Выключенную группу без включённых участников включить нельзя.

## 🐛 Исправлено

- **Пир WireGuard/AWG показывал «connected», когда сервер не отвечал ([задача 613](docs/spec/tasks/613-wg-peers-tailscale-path-health.md)).**
  Пир был зелёным, пока последнему хендшейку меньше трёх минут, поэтому
  живыми выглядели новый сервер в группе, через которую идёт узел, не
  пропускающий трафик, и узел, который только что выключили и включили.
  Теперь пир, который шлёт, но около 8 секунд ничего не получает в ответ,
  оранжевый — «no response». После включения или пробуждения узла пир
  показывает «never connected» до нового хендшейка, а ↓/↑ считают только
  текущую сессию.
- **Остановка VPN зависала на узле MASQUE с detour.** Если такой узел
  (например, WARP поверх vless+ws) в этот момент пинговался или
  подключался, остановка его ждала; теперь незавершённое подключение
  отменяется.
- **Запуск падал с `initialize cache-file: timeout` после зависшей остановки ([задача 703](docs/spec/tasks/703-cache-db-lock-timeout-retry.md)).**
  Новое ядро само забирает `cache.db`, сохраняя выбор узлов в группах,
  FakeIP и кеш rule-set. Если и это не удалось, приложение удаляет файл и
  повторяет запуск один раз; force stop приложения и ручной сброс DNS-кэша
  больше не нужны.
- **Выбранный в мастере endpoint WARP подменялся ([задача 386](docs/spec/tasks/386-warp-endpoint-preset-combobox.md)).**
  Выбранный `engage.cloudflareclient.com:2408` больше не заменяется ни
  случайным IP при обфускации, ни адресом из ответа Cloudflare, ни
  endpoint'ом закешированной регистрации.
- **Route на экране узла не следил за селектором.** Если выбор группы на
  пути менялся не с этого экрана (на главной, через Debug API, после
  переселекта urltest), Route показывал старый выбор, пока экран не открыть
  заново. Теперь Route и галка в списке участников группы следуют за ядром.
- **Из Shield DNS нельзя было убрать сервер.** После 2.25.17 участники
  Shield DNS оставались под замком «used by Shield DNS», а саму группу
  нельзя было изменить (см. «Изменено» выше).
- **Строка узла прыгала по высоте во время пинга.** Строка узла без
  подзаголовка (например, `direct`) схлопывалась и раскрывалась вместе с
  бейджем пинга; теперь высота держится.

## 🔧 Под капотом

- Ядро `v1.14.4-lx.25` → `v1.14.4-lx.28`: ключ `hosts` у DNS-группы
  (Leadaxe/sing-box-lx#60); выравнивание MTU: прокси-узел в группе больше не
  занижает MTU туннеля над группой, туннели с IPv6 не опускаются ниже 1280;
  статус пира WireGuard/AWG по сессиям; подключение MASQUE с detour
  отменяется при остановке; `cache.db` забирается у прежнего экземпляра,
  зависшего на остановке.
- Контракт 1.1.140 → 1.1.145: узлы `trusttunnel` судит реестр (узел без
  `username`, `password` или `tls` снимается при разборе, как у лаунчера);
  импорт бэкапа сливает шаблонные и пользовательские DNS-серверы по тегу;
  `tcp_multi_path` во вставленном sing-box узле сохраняется как известное
  поле диалера.

</details>

---

## Install / Установка

```bash
adb install -r LxBox-v2.25.19-rc.1-arm64-v8a.apk
```

Без uninstall! Поверх существующей установки. Настройки и подписки сохранятся.

No uninstall needed — install over the existing one. Settings and subscriptions
are preserved.

---

Previous release / Предыдущий релиз: [v2.25.18](docs/releases/v2.25.18.md).
