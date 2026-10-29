# L×Box v2.25.18

**A patch on top of [v2.25.17](https://github.com/Leadaxe/LxBox/releases/tag/v2.25.17).**

A new **Diagnostics** section with **URL Check**: the core makes a real
request to a site through your routing and shows every step as a tree, from
the app's DNS query to the HTTP response, with the step where the path broke
and findings about the config. Speed Test moved there as the second tab.
Chosen address ranges can bypass the tunnel entirely (a home NAS, a printer).
FakeIP pools can be changed. WireGuard and AmneziaWG nodes get an INI tab,
and an INI with several `[Peer]` sections keeps them all. A subscription's
update interval can follow the server, and the server no longer overwrites
an interval you chose. Core `v1.14.4-lx.25` on the upstream sing-box 1.14.4
base, with faster XHTTP uploads. Contract 1.1.140.

**Патч поверх [v2.25.17](https://github.com/Leadaxe/LxBox/releases/tag/v2.25.17).**

Новый раздел **Diagnostics** с **URL Check**: ядро делает настоящий запрос к
сайту через вашу маршрутизацию и показывает каждый шаг деревом — от
DNS-запроса приложения до HTTP-ответа, с шагом, где путь оборвался, и
находками о конфиге. Speed Test переехал туда второй вкладкой. Выбранные
диапазоны адресов могут идти мимо туннеля целиком (домашний NAS, принтер).
Пулы FakeIP можно менять. У узлов WireGuard и AmneziaWG появилась вкладка
INI, а INI с несколькими секциями `[Peer]` сохраняет их все. Интервал
обновления подписки может следовать за сервером, и сервер больше не
перезаписывает выбранный вами интервал. Ядро `v1.14.4-lx.25` на базе
апстримного sing-box 1.14.4, с более быстрой выгрузкой по XHTTP. Контракт
1.1.140.

---

<details open>
<summary><h2>🇬🇧 English</h2></summary>

## ⚠️ Read before updating

- **New upstream base.** The core moves to upstream sing-box 1.14.4.
  Upstream changed how groups are resolved; Auto (`urltest`) groups still
  pick a node per connection as before. If a group or a WireGuard node
  behaves differently after the update, report it.
- **XHTTP nodes send more like Xray.** `packet-up` uploads (and `auto`
  without REALITY, most nodes behind a CDN) are batched and no longer wait
  for each POST's reply. Requests without your own `User-Agent` carry the
  browser headers Xray sends, and HTTP/2 keep-alive pings are on by default
  (45 s). If an XHTTP node stops working after the update, report it.
- **Ru internet segment: Yandex UDP DNS follows the preset's Outbound again
  ([task 684](docs/spec/tasks/684-dns-defaults-plain-tunnel-encrypted-direct.md)).**
  In v2.25.17 the preset's `yandex_udp` went through `vpn-1`; now it goes
  the preset's Outbound (direct by default), so Russian domains no longer
  resolve through the tunnel. The «UDP DNS outbound» setting is removed;
  «Encrypted DNS outbound» became the checkbox «Encrypted DNS via
  Outbound»: off (default) — DoT and DoH go direct, on — through the
  preset's Outbound. «UDP through the tunnel» stays for the shared DNS
  servers.
- **Subscription update interval.** Existing subscriptions keep their
  current interval as a manual choice; pick «As subscription» to follow the
  server again. «Never (respect server)» is removed.

## ✨ New

- **Diagnostics → URL Check ([task 687](docs/spec/tasks/687-diagnostics-url-check.md), issue #176).**
  Enter a site and the core makes a real request to it through your
  routing, showing every step as a tree as it happens: the app's DNS
  queries (A, AAAA, HTTPS) and the server that answered, the matched rule,
  the group choice, the node and its detours, the node's own address
  lookup, TCP, TLS, the response. Each step has its time and result; a step
  the protocol does not confirm (VLESS, Trojan, Shadowsocks header) is
  marked as sent, a cached or reused step as reused. The step where the path
  broke is highlighted and named above the tree. Options: the app the
  request is made for (rules by app apply), depth (Full, Connect, Route —
  no connection is opened, DNS) and From scratch (bypass the DNS cache, open
  new connections). Copy puts the trace on the clipboard. Needs a running
  VPN.
- **URL Check: step details and the DNS answer ([task 688](docs/spec/tasks/688-url-check-stage-details.md)).**
  Every step expands: what the step is, why it was skipped or reused, its
  attributes. The app's DNS query shows the answer record by record with
  TTL (CNAME chain, addresses, HTTPS record parameters such as ALPN and
  ECH), the SOA on NXDOMAIN or an empty answer, and where the answer came
  from: the network, the cache with its age, or a local answer (fake IP,
  hosts). When a DNS rule or the domain strategy answered without asking a
  server, the step says so. The failed step and an empty or failed DNS
  answer open by themselves.
- **URL Check: findings.** Under the result the core lists what it noticed
  about the config, at three levels: a cause of the failure, a risk, a fact.
  For example: a package excluded from the VPN, a node that depends on a DNS
  server's detour outside the route, fake IP records lost after a restart,
  REALITY not recognizing the client. A tap on a finding highlights its
  steps.
- **URL Check: DNS groups.** Every server a DNS group asked has its own
  step with its tag. A server that lost the race to another member's answer
  is shown as skipped, with the winner it lost to, instead of as a broken
  DoT or DoH server.
- **Bypass the tunnel ([task 691](docs/spec/tasks/691-tun-route-exclude.md)).**
  VPN Settings → TUN → «Bypass the tunnel»: CIDR ranges that skip the
  tunnel and the core entirely, so large transfers to a home NAS no longer
  go through the core. Type one range per line or pick from the list
  (home LAN, private and link-local networks). Traffic to these addresses
  is not seen by rules, DNS interception or statistics. An entry that is not
  a CIDR or covers the tunnel's own address is dropped with a warning in the
  log. Applies after a full VPN restart.
- **FakeIP: your own address pools ([task 690](docs/spec/tasks/690-fakeip-custom-ranges.md)).**
  The FakeIP preset gets «IPv4 pool» and «IPv6 pool» (defaults
  198.18.0.0/15 and fc00::/18, as before), for networks where the default
  range is in use. An empty IPv6 pool turns off fake AAAA answers.
- **INI tab for WireGuard / AmneziaWG nodes ([task 686](docs/spec/tasks/686-folder-auto-node-source-tab.md)).**
  Node Settings shows the node as a `.conf`, whatever it was added from
  (link, INI or JSON): all peers, masquerade and AmneziaWG fields, with
  Copy, Share .conf and Edit INI. Keys INI cannot express are listed under
  «Not in INI».
- **Several `[Peer]` sections in a WireGuard INI.** Each becomes its own
  peer of the node; before, everything after the first was dropped. A peer
  without a public key or endpoint is dropped with a warning naming it.
- **Subscription update interval «As subscription» ([task 685](docs/spec/tasks/685-subscription-interval-as-subscription.md)).**
  The interval comes from the server's `profile-update-interval` header
  (24 h when the server sends none). A manually chosen interval stays as
  chosen; before, every update replaced it with the server's value. New
  subscriptions start in «As subscription».

## 🔄 Changed

- **Speed Test is a tab of Diagnostics.** The side menu item Speed Test is
  replaced by Diagnostics with two tabs, URL Check and Speed Test. A running
  speed test is not interrupted when switching tabs.
- **Auto node in a folder is edited in Node Settings.** A tap opens the
  group form on the Settings tab (name, servers in the pool, mode,
  advanced); Source shows the stored record; the JSON tab says «Members are
  resolved at build time» instead of an empty `outbounds`. The pool preview
  no longer counts disabled servers and marks them with ⏻.
- **Long-press menu** no longer offers «Edit…» of a folder member and «Edit
  source…» / «Update» of a standalone server; a tap opens the same screen.
- **Text fields with suggestions are comboboxes.** A list with suggestions
  (Bypass the tunnel, list parameters of presets) is a field with an arrow
  at the end; picking a suggestion adds the line, picking it again removes
  it.
- **«Custom tunnel routes» is renamed «Split default route»** and explained:
  it sends the same traffic to the tunnel as two half-ranges, it never added
  routes of its own.
- **`#` comments** in a pasted node JSON and on the Config screen are
  accepted and stripped, as the core does, next to `//` and `/* */`.
- Direction editor: a caption under «Replace groups» says what the checkbox
  does.

## 🐛 Fixed

- **VPN would not start after a rule made of IP ranges got a DNS option ([task 692](docs/spec/tasks/692-rule-dns-option-needs-dns-visible-conditions.md)).**
  The core stopped with «Legacy Address Filter Fields in DNS rules is
  deprecated…» once FakeIP or Force IPv4 was present. The DNS section of a
  rule now appears only when the rule has a condition the DNS layer can
  check (a domain, an app, a source address, a Wi-Fi network or an
  inbound), and an IP-only rule no longer produces a DNS rule. Existing
  rules keep their DNS settings; they come back once a domain or app is
  added.
- **URL Check: no false success.** A Full check that ends without an HTTP
  response and without a failed step shows a yellow «No HTTP response»; a
  site that answers `301`/`302` shows that status and its `location`
  instead of a green «HTTP 0». Changing the URL, the app, the depth or From
  scratch clears the previous result.
- **XHTTP:** single-stream upload speed in `packet-up` was capped at one
  write per round trip (Leadaxe/sing-box-lx#58); a `stream-up` write could
  hang after the server refused the upload; a `path` without a trailing
  slash could get 404 with the session outside the path.
- Subscription filter rule editor showed «Совпадений: из узлов» without the
  numbers; the «Applied — …» message after saving filters lost them too.
- Node delay is shown as `120ms` instead of `120MS`.

## 🔧 Under the hood

- Core `v1.14.3-lx.23` → `v1.14.4-lx.25`: SPEC 139 (connection test), the
  upstream sing-box 1.14.4 base with Go 1.26.10, SPEC 141/142 (XHTTP), a
  data race in the Auto group's selection fixed.
- Below Android 10 the owner of a connection (per-app rules) is looked up in
  `/proc/net` through a call from the app.
- Contract 1.1.140: WireGuard INI with several peers.
- DNS server descriptions are no longer translated, as with node names.

</details>

<details open>
<summary><h2>🇷🇺 Русский</h2></summary>

## ⚠️ Прочтите до обновления

- **Новая база апстрима.** Ядро переходит на апстримный sing-box 1.14.4.
  Апстрим изменил разбор групп; группы Auto (`urltest`) по-прежнему выбирают
  узел на каждое соединение. Если группа или WireGuard-узел после обновления
  ведут себя иначе — сообщите.
- **Узлы XHTTP шлют ближе к Xray.** Выгрузка `packet-up` (и `auto` без
  REALITY — большинство узлов за CDN) склеивается и не ждёт ответа на
  каждый POST. Запросы без вашего `User-Agent` несут браузерные заголовки,
  как у Xray, пинги HTTP/2 включены по умолчанию (45 с). Если узел XHTTP
  после обновления перестал работать — сообщите.
- **Ru internet segment: Yandex UDP DNS снова идёт по Outbound пресета
  ([задача 684](docs/spec/tasks/684-dns-defaults-plain-tunnel-encrypted-direct.md)).**
  В v2.25.17 `yandex_udp` пресета ходил через `vpn-1`; теперь — по Outbound
  пресета (по умолчанию напрямую), и российские домены больше не резолвятся
  через туннель. Настройка «UDP DNS outbound» снята; «Encrypted DNS
  outbound» стала галочкой «Encrypted DNS via Outbound»: выключена (по
  умолчанию) — DoT и DoH напрямую, включена — через Outbound пресета.
  «UDP через туннель» остаётся для общих DNS-серверов.
- **Интервал обновления подписки.** У существующих подписок текущий
  интервал сохраняется как выбранный вручную; чтобы снова следовать за
  сервером, выберите «As subscription». Пункт «Never (respect server)»
  снят.

## ✨ Новое

- **Diagnostics → URL Check ([задача 687](docs/spec/tasks/687-diagnostics-url-check.md), issue #176).**
  Введите сайт, и ядро сделает к нему настоящий запрос через вашу
  маршрутизацию, показывая каждый шаг деревом по ходу дела: DNS-запросы
  приложения (A, AAAA, HTTPS) и ответивший сервер, сработавшее правило,
  выбор группы, узел и его detour'ы, резолв адреса самого узла, TCP, TLS,
  ответ. У каждого шага время и результат; шаг, который протокол не
  подтверждает (VLESS, Trojan, заголовок Shadowsocks), помечен как
  отправленный, взятый из кэша или переиспользованный — как
  переиспользованный. Шаг, на котором путь оборвался, подсвечен и назван над
  деревом. Параметры: приложение, от имени которого идёт запрос (правила по
  приложениям применяются), глубина (Full, Connect, Route — без соединений,
  DNS) и From scratch (мимо кэша DNS, новые соединения). Copy кладёт трассу
  в буфер обмена. Нужен запущенный VPN.
- **URL Check: подробности шагов и ответ DNS ([задача 688](docs/spec/tasks/688-url-check-stage-details.md)).**
  Каждый шаг раскрывается: что это за шаг, почему пропущен или
  переиспользован, его атрибуты. DNS-запрос приложения показывает ответ по
  записям с TTL (цепочка CNAME, адреса, параметры HTTPS-записи вроде ALPN и
  ECH), SOA при NXDOMAIN или пустом ответе и откуда пришёл ответ: из сети,
  из кэша с возрастом или локально (fake IP, hosts). Когда ответило правило
  DNS или стратегия домена, не спрашивая сервер, шаг говорит об этом. Шаг
  обрыва и пустой или ошибочный ответ DNS раскрыты сразу.
- **URL Check: находки.** Под результатом ядро перечисляет, что заметило в
  конфиге, на трёх уровнях: причина сбоя, риск, факт. Например: пакет
  исключён из VPN, узел зависит от detour'а DNS-сервера вне маршрута, записи
  fake IP теряются после перезапуска, REALITY не узнал клиента. Тап по
  находке подсвечивает её шаги.
- **URL Check: DNS-группы.** У каждого сервера, которого спросила
  DNS-группа, свой шаг с его тегом. Сервер, проигравший гонку ответу другого
  участника, показан пропущенным, с победителем, а не сломанным DoT- или
  DoH-сервером.
- **Мимо туннеля ([задача 691](docs/spec/tasks/691-tun-route-exclude.md)).**
  VPN Settings → TUN → «Bypass the tunnel»: CIDR-диапазоны, которые идут
  мимо туннеля и мимо ядра целиком — большие передачи на домашний NAS
  больше не проходят через ядро. По диапазону на строку или выбор из списка
  (домашняя сеть, частные и link-local сети). Трафик к этим адресам не видят
  правила, DNS-перехват и статистика. Строка не в формате CIDR или
  накрывающая адрес самого туннеля снимается с предупреждением в журнале.
  Применяется после полного перезапуска VPN.
- **FakeIP: свои пулы адресов ([задача 690](docs/spec/tasks/690-fakeip-custom-ranges.md)).**
  У пресета FakeIP появились «IPv4 pool» и «IPv6 pool» (по умолчанию
  198.18.0.0/15 и fc00::/18, как раньше) — для сетей, где стандартный
  диапазон занят. Пустой IPv6-пул выключает фейковые ответы на AAAA.
- **Вкладка INI у узлов WireGuard / AmneziaWG ([задача 686](docs/spec/tasks/686-folder-auto-node-source-tab.md)).**
  Node Settings показывает узел как `.conf`, откуда бы он ни был добавлен
  (ссылка, INI или JSON): все пиры, маскарад и поля AmneziaWG, с Copy,
  Share .conf и Edit INI. Ключи, которые INI не выражает, перечислены под
  «Not in INI».
- **Несколько секций `[Peer]` в INI WireGuard.** Каждая становится своим
  пиром узла; раньше всё после первой отбрасывалось. Пир без публичного
  ключа или endpoint снимается с предупреждением, где он назван.
- **Интервал обновления подписки «As subscription» ([задача 685](docs/spec/tasks/685-subscription-interval-as-subscription.md)).**
  Интервал берётся из заголовка сервера `profile-update-interval` (24 ч,
  если сервер его не шлёт). Интервал, выбранный вручную, остаётся как
  выбран; раньше каждое обновление заменяло его значением сервера. Новые
  подписки начинают в режиме «As subscription».

## 🔄 Изменено

- **Speed Test — вкладка Diagnostics.** Пункт бокового меню Speed Test
  заменён пунктом Diagnostics с двумя вкладками, URL Check и Speed Test.
  Идущий замер не прерывается при переключении вкладок.
- **Auto-узел в папке редактируется в Node Settings.** Тап открывает форму
  группы на вкладке Settings (имя, серверы в пуле, режим, дополнительно);
  Source показывает сохранённую запись; вкладка JSON пишет «Members are
  resolved at build time» вместо пустого `outbounds`. Превью пула больше не
  считает выключенные серверы и помечает их ⏻.
- **Меню по долгому тапу** больше не предлагает «Edit…» у члена папки и
  «Edit source…» / «Update» у одиночного сервера; тап открывает тот же
  экран.
- **Текстовые поля с подсказками — комбобоксы.** Список с подсказками
  (Bypass the tunnel, списковые параметры пресетов) — поле со стрелкой в
  конце строки; выбор подсказки добавляет строку, повторный — убирает.
- **«Custom tunnel routes» переименована в «Split default route»** и
  объяснена: она шлёт тот же трафик в туннель двумя полудиапазонами, своих
  маршрутов не добавляла никогда.
- **Комментарии `#`** во вставленном JSON узла и на экране Config
  принимаются и вырезаются, как в ядре, наряду с `//` и `/* */`.
- Редактор Направления: подпись под «Replace groups» объясняет, что делает
  галочка.

## 🐛 Исправлено

- **VPN не стартовал после того, как правило из одних IP-диапазонов
  получало DNS-опцию ([задача 692](docs/spec/tasks/692-rule-dns-option-needs-dns-visible-conditions.md)).**
  Ядро останавливалось с «Legacy Address Filter Fields in DNS rules is
  deprecated…», если в конфиге был FakeIP или Force IPv4. Секция DNS у
  правила теперь показывается только при условии, которое DNS-слой может
  проверить (домен, приложение, адрес источника, Wi-Fi-сеть или inbound), и
  правило из одних IP больше не даёт DNS-правила. Настройки DNS у
  существующих правил сохраняются и вернутся, когда в правило добавят домен
  или приложение.
- **URL Check: без ложного успеха.** Полная проверка, закончившаяся без
  HTTP-ответа и без упавшего шага, показывает жёлтое «No HTTP response»;
  сайт, ответивший `301`/`302`, показывает этот статус и `location`, а не
  зелёное «HTTP 0». Смена URL, приложения, глубины или From scratch стирает
  прошлый результат.
- **XHTTP:** скорость выгрузки одного потока в `packet-up` упиралась в одну
  запись за круговой путь (Leadaxe/sing-box-lx#58); запись `stream-up` могла
  зависнуть после отказа сервера; `path` без слэша на конце мог получать 404
  при сессии вне пути.
- Редактор правила фильтра подписки показывал «Совпадений: из узлов» без
  чисел; сообщение «Applied — …» после сохранения фильтров тоже их теряло.
- Задержка узла показывается как `120ms`, а не `120MS`.

## 🔧 Под капотом

- Ядро `v1.14.3-lx.23` → `v1.14.4-lx.25`: SPEC 139 (проверка соединения),
  база апстримного sing-box 1.14.4 с Go 1.26.10, SPEC 141/142 (XHTTP),
  исправлена гонка данных при выборе узла в группе Auto.
- Ниже Android 10 владельца соединения (правила по приложениям) ищут в
  `/proc/net` по вызову из приложения.
- Контракт 1.1.140: INI WireGuard с несколькими пирами.
- Описания DNS-серверов больше не переводятся, как и имена узлов.

</details>

---

## Install / Установка

```bash
adb install -r LxBox-v2.25.18-arm64-v8a.apk
```

Без uninstall! Поверх существующей установки. Настройки и подписки сохранятся.

No uninstall needed — install over the existing one. Settings and subscriptions
are preserved.

---

Previous release / Предыдущий релиз: [v2.25.17](docs/releases/v2.25.17.md).
