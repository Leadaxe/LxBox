# L×Box v2.25.17

**A patch on top of [v2.25.16](https://github.com/Leadaxe/LxBox/releases/tag/v2.25.16).**

DNS servers get new defaults: plain UDP servers go through the tunnel, DoT and
DoH go direct, and the Shield group is now direct as a whole. The DNS server
list is filled from the template once; template servers can be deleted, and
new ones are added from a catalog under (+). A template or preset server can be
duplicated into your own. A routing rule can answer its domains with a fixed IP
address, like a hosts entry, and everything about resolving now sits in one
**DNS & Resolve** section of the rule editor. Directions can be reordered,
**Default traffic** moved to the bottom of the Rules tab, and on Android TV the
app fills the screen. Stopping the VPN no longer hangs. Core
`v1.14.3-lx.23`, contract 1.1.139.

**Патч поверх [v2.25.16](https://github.com/Leadaxe/LxBox/releases/tag/v2.25.16).**

У DNS-серверов новые умолчания: нешифрованные UDP-серверы ходят через туннель,
DoT и DoH — напрямую, группа Shield теперь целиком прямая. Список DNS-серверов
заполняется из шаблона один раз; шаблонные серверы можно удалять, новые
добавляются из каталога по (+). Шаблонный или пресетный сервер можно
продублировать в свой. Правило маршрутизации может отвечать на свои домены
фиксированным IP-адресом, как запись hosts, а всё про резолв собрано в одну
секцию **DNS & Resolve** редактора правила. Направления можно переставлять,
**Default traffic** переехал в конец вкладки Rules, на Android TV приложение
занимает весь экран. Остановка VPN больше не зависает. Ядро
`v1.14.3-lx.23`, контракт 1.1.139.

---

<details open>
<summary><h2>🇬🇧 English</h2></summary>

## ⚠️ Read before updating

- **DNS servers: plain UDP through the tunnel, DoT and DoH direct ([task 684](docs/spec/tasks/684-dns-defaults-plain-tunnel-encrypted-direct.md)).**
  Template servers take their Outbound from the template on every build, so
  the config changes for everyone who has not changed it by hand:
  - `google_udp`, `cloudflare_udp`, `opendns_udp` — `direct-out` → `vpn-1`;
  - `google_dot`, `cloudflare_dot`, `quad9_doh` — `vpn-1` → `direct-out`;
  - `google_doh`, `opendns_doh`, `yandex_dot`, `safe_dns_dot` — direct, as
    before.

  The **Shield** group (`dns_shield`, six encrypted providers) is now direct
  as a whole. `safe_dns_dot` resolves its own name through `google_doh`
  instead of `google_udp`. Descriptions no longer name the path: "Google
  UDP", "OpenDNS UDP", "Quad9 DoH (anti-malware)", "Yandex DoT"; the path is
  the Outbound field in the editor.
- **Ru internet segment: separate Outbound for its UDP and encrypted DNS (task 684).**
  Two new preset settings: **UDP DNS outbound** (default `vpn-1`, for
  `yandex_udp`) and **Encrypted DNS outbound** (default `direct-out`, for
  Yandex DoT and DoH). `yandex_udp` no longer follows the preset's
  **Outbound**, and Yandex DoT is direct by default.
- **The DNS server list is filled from the template once ([task 680](docs/spec/tasks/680-dns-servers-catalog-seed-once.md)).**
  An existing install keeps its list as it is. Servers that a newer template
  brings appear in the catalog under (+) next to **DNS Servers**, not in the
  list.

## ✨ New

- **Fixed IP answer in a rule ([task 683](docs/spec/tasks/683-rule-dns-and-resolve-section-fixed-ip.md)).**
  Rule editor → **DNS & Resolve** → Answer → **Fixed IP** answers the rule's
  domains with the given IPv4 or IPv6 addresses, like a hosts entry: for
  example `nas.home` → `192.168.1.10`. "+" turns the field into a list, one
  address per line; pasting several lines does the same. A line that is not
  an IP address marks the field and blocks Save. With addresses of one family
  only, queries of the other type get an empty answer. Traffic to the address
  follows the rule's Action. On the DNS tab such a rule shows as
  `action: predefined · answer: …` under "From routing rules", and ✕ there
  returns it to Default.
- **"Add DNS server" catalog (task 680).** The (+) next to **DNS Servers**
  opens **Add DNS server**: **Custom server** and the template's servers with
  **Add** / **Added**, and ⋮ → **Add all defaults**. A template server can be
  deleted: long-press → **Delete** on the DNS tab, or the trash icon in the
  editor; a preset's server cannot. A server the list depends on (a group
  member, the DNS Final or Default Domain Resolver choice, another server's
  name resolver) is locked and shows "used by …"; tapping its switch shows
  "Locked: used by …". The rule editor offers only servers from the list.
- **Duplicate a template or preset DNS server ([task 682](docs/spec/tasks/682-dns-catalog-revision-and-copy.md)).**
  ⋮ → **Duplicate** in the server editor, or **Duplicate** in the tile's
  long-press menu, opens a new custom server with the original's body (with
  its current settings), tag `<tag>_copy` and description
  `<description> (copy)`. Nothing is saved until **Save**. The editor of a
  template or preset server now shows the **Tag** field: changing it turns
  Save into **Save as copy**, and the original stays in the list. Groups, DNS
  Final and rules keep pointing to the original.
- **Outbound and address for OpenDNS UDP, OpenDNS DoH, Quad9 DoH and Yandex DoT (task 682).**
  These four servers had a fixed body. Now their editor has **Outbound** and
  a choice of the server address: primary or secondary, IPv4 or IPv6.
- **Warning when Default Domain Resolver goes through a tunnel (task 682).**
  This resolver looks up server addresses while the connection is being set
  up, before the tunnel exists. When the selected server goes through a
  Direction, or every member of the selected group does, an orange ⚠ appears
  at the right of the **Default Domain Resolver** header; tapping it explains
  the risk ("Resolver goes through a tunnel"). The choice is not changed. With
  the default Shield the ⚠ does not appear.
- **Reorder Directions ([task 673](docs/spec/tasks/673-directions-reorder-in-ui.md), issue #171).**
  Each row on the **Directions** tab has a drag handle, `vpn-1` included.
  While dragging, the rows a Direction cannot pass are tinted red: a
  Direction that includes others must stay below them. A drop there leaves
  the list as it was and says why.

## 🔄 Changed

- **Rule editor: one "DNS & Resolve" section (task 683).**
  The "Action & Resolve" sheet and the ⚙ next to Action are gone. Action only
  chooses where the traffic goes; **Resolve only** is now an item of its
  list, after Reject (for rules with domains). The section at the bottom
  holds:
  - **Answer**: Default (queries go to DNS Final), **Dedicated server**, or
    **Fixed IP**;
  - **Force IPv4 (drop AAAA)**;
  - **Resolve before routing** (formerly Resolve first) with Strategy;
  - **Advanced**, collapsed: the DNS server for the lookup, Disable cache,
    Disable optimistic cache, Rewrite TTL, Query timeout, Client subnet.

  Existing rules build the same config. The **View** tab now shows the rule's
  DNS rules too.
- **DNS hints (task 684).** The ℹ next to **DNS Final** and **Default Domain
  Resolver** opens a popup. It recommends `google_doh` or `cloudflare_dot` and
  says that UDP servers are fine for DNS Final but not for Default Domain
  Resolver. The `local_dns_resolver` banner offers **Switch to google_doh**.
- **Default traffic is at the bottom of the Rules tab ([task 676](docs/spec/tasks/676-route-final-on-rules-tab.md)).**
  The `route.final` picker sits after the rule list and **Add rule**, labelled
  **Default traffic (no rule matched)**. The Directions tab no longer shows
  it. What is written is the same.
- **A Direction is shown by its title everywhere ([task 672](docs/spec/tasks/672-direction-label-vs-tag-consistency.md)).**
  The notification, a home row whose member is another Direction, the
  Direction editor header, and the route, Chain and Detour lines in Stats →
  Connections and Live show the title, with the tag next to it, for example
  `Germany (vpn-1)`. Renaming still does not change the tag.
- **The Direction node filter preview works with the VPN off ([task 674](docs/spec/tasks/674-direction-filter-preview-without-tunnel.md)).**
  The editor and the node count on the Directions tab take nodes from the
  config build, so they match the built config whether the tunnel is up or
  not. An empty result reads "No nodes match".
- **On Android TV the app fills the screen ([task 679](docs/spec/tasks/679-tv-no-portrait-lock.md), issue #163).**
  On a TV the orientation is never locked, and **Allow rotation** is hidden
  there. The stored value is kept, so a backup from a TV does not turn
  rotation on for a phone.
- **Auto-ping after connect runs the group test only for Fastest groups ([task 677](docs/spec/tasks/677-autoping-tail-skips-round-robin-groups.md)).**
  Load balance groups no longer have their pool rebuilt, and Hold until
  failure groups no longer drop the held node after a ping. Latencies of all
  nodes still come from the ping; **Run URLTest** in the group menu works as
  before.

## 🩹 Fixed

- **Stopping the VPN no longer hangs ([task 668](docs/spec/tasks/668-stop-teardown-trace-and-timeouts.md)).**
  With many WireGuard, AmneziaWG or WARP nodes the stop is fast again: the
  core waited for each endpoint's receive worker one after another. Each stop
  step also has a real time limit (core shutdown 20 s, other steps 3 s), so
  the service reaches Stopped even when a step does not return. A step stuck
  longer than 5 s writes `stuck at <step>` and a goroutine dump to the app
  log, and the dump goes into the support pack.
- **Test servers with the VPN off: Stop stops, Start starts again ([task 669](docs/spec/tasks/669-probe-session-cancel-stop-timeout-race.md), issue #171).**
  **Stop** aborts the measurements already sent instead of waiting for their
  timeout; the bar shows `Stopping…` meanwhile. A stuck test session no
  longer blocks the next test or the VPN start.
- **Load balance skips a node that failed its check.** A `round_robin` group
  no longer sends new connections to a node that failed its last check while
  a live node is available; a failed manual ping also takes the node out of
  the rotation until the next group check.
- **"Register detour in auto group" works ([task 670](docs/spec/tasks/670-register-detour-in-auto-group-dead-toggle.md)).**
  Chain links get into a Direction's auto group only with this switch on.
  It is disabled while **Register detour servers** is off, and a folder shows
  both switches only when it has chain links.
- **An auto node in a folder no longer disappears silently ([task 675](docs/spec/tasks/675-folder-auto-node-silent-drop-and-pool-gates.md)).**
  An auto node with no members is named in the build report, and its editor
  says it stays out of the config. Its pool follows the same rules as a
  Direction's: Tailscale without an exit node is never in it, chain links only
  with **Register detour servers**.
- **The JSON preview of a DNS group skips disabled members ([task 671](docs/spec/tasks/671-dns-group-json-preview-disabled-members.md)).**
  As the build does; a line under the preview names them: "Disabled, skipped
  at build: …".
- **Android TV: receiving settings with the remote ([task 622](docs/spec/tasks/622-device-transfer-phone-to-tv.md)).**
  The receive screen fits without scrolling, the arrows move between choices
  in the import preview, and the focus returns to the transfer card after it.
- **Start no longer waits 10–16 s for an unrelated mux handshake**, and a
  MASQUE node with `vhttp: auto` no longer keeps the previous core instance
  in memory after each Stop/Start or profile switch.

## 🔧 Under the hood

- Core `v1.14.3-lx.21` → `v1.14.3-lx.23` ([docs/KERNEL.md](docs/KERNEL.md)):
  the stop, start, MASQUE and Load balance fixes above; a stop that hangs
  longer than 20 s writes a goroutine dump to the core log. The Java surface
  is the same as in lx.21.
- Launcher contract 1.1.132 → 1.1.139: the source's template catalog in LX
  Backup (`dns.template_catalog`) with one rule for removing template DNS
  servers on import ([task 681](docs/spec/tasks/681-dns-servers-uniform-backup-catalog.md));
  `rules[].dns.fixedIps` for both sides.
- LX Backup and the phone → TV transfer carry the list of template DNS
  servers as is: a server deleted on the source is removed on the receiver,
  unless something still refers to it (then it stays, with a warning). A DNS
  Final or default resolver pointing to a missing server is reset to the
  template default, and a group with no known member comes in turned off.
  Older backups lose nothing.
- Debug API: `POST /directions/reorder` and `include` in `POST`/`PATCH
  /directions` that would put a Direction above one it includes get 409 with
  the pairs in `conflicts`; rules read and write `dns.fixed_ips`.
- The template formatter (`app/scripts/format_wizard_template.py`) accepts
  the current template language and checks the meaning before writing;
  `wizard_template.json` is reformatted, 2367 → 760 lines, contents
  unchanged ([task 678](docs/spec/tasks/678-format-wizard-template-new-dialect.md)).
- New tests: Fixed IP emission and storage, the DNS & Resolve section, DNS
  server copy, the tunnel resolver warning, DNS defaults of the whole catalog
  and Ru internet segment, Directions reorder zones, the filter preview pool,
  the probe session stop, TV receive layout and D-pad focus, the `rule_dns`
  contract corpus.

</details>

<details open>
<summary><h2>🇷🇺 Русский</h2></summary>

## ⚠️ Прочтите до обновления

- **DNS-серверы: UDP через туннель, DoT и DoH напрямую ([задача 684](docs/spec/tasks/684-dns-defaults-plain-tunnel-encrypted-direct.md)).**
  Шаблонные серверы берут Outbound из шаблона на каждой сборке, поэтому
  конфиг меняется у всех, кто не менял его руками:
  - `google_udp`, `cloudflare_udp`, `opendns_udp` — `direct-out` → `vpn-1`;
  - `google_dot`, `cloudflare_dot`, `quad9_doh` — `vpn-1` → `direct-out`;
  - `google_doh`, `opendns_doh`, `yandex_dot`, `safe_dns_dot` — напрямую, как
    и раньше.

  Группа **Shield** (`dns_shield`, шесть шифрованных провайдеров) теперь
  целиком прямая. `safe_dns_dot` резолвит своё имя через `google_doh` вместо
  `google_udp`. В описаниях больше нет пути: «Google UDP», «OpenDNS UDP»,
  «Quad9 DoH (anti-malware)», «Yandex DoT»; путь — поле Outbound в
  редакторе.
- **Ru internet segment: отдельный Outbound для UDP и шифрованного DNS (задача 684).**
  Две новые настройки пресета: **UDP DNS outbound** (по умолчанию `vpn-1`,
  для `yandex_udp`) и **Encrypted DNS outbound** (по умолчанию `direct-out`,
  для Yandex DoT и DoH). `yandex_udp` больше не следует **Outbound** пресета,
  Yandex DoT по умолчанию напрямую.
- **Список DNS-серверов заполняется из шаблона один раз ([задача 680](docs/spec/tasks/680-dns-servers-catalog-seed-once.md)).**
  У существующей установки список остаётся как есть. Серверы, которые
  приносит новый шаблон, появляются в каталоге по (+) рядом с **DNS
  Servers**, а не в списке.

## ✨ Новое

- **Ответ фиксированным IP у правила ([задача 683](docs/spec/tasks/683-rule-dns-and-resolve-section-fixed-ip.md)).**
  Редактор правила → **DNS & Resolve** → Answer → **Fixed IP** отвечает на
  домены правила заданными адресами IPv4 или IPv6, как запись hosts:
  например, `nas.home` → `192.168.1.10`. «+» делает поле списком, по адресу
  на строку; вставка нескольких строк делает то же. Строка, которая не
  является IP-адресом, подсвечивает поле и блокирует Save. Если заданы адреса
  только одного семейства, запросы другого типа получают пустой ответ. Трафик
  к адресу идёт по Action правила. На вкладке DNS такое правило видно в «From
  routing rules» строкой `action: predefined · answer: …`, ✕ там возвращает
  его в Default.
- **Каталог «Add DNS server» (задача 680).** (+) рядом с **DNS Servers**
  открывает **Add DNS server**: **Custom server** и серверы шаблона с
  **Add** / **Added**, ⋮ → **Add all defaults**. Шаблонный сервер можно
  удалить: долгое нажатие → **Delete** на вкладке DNS или корзина в
  редакторе; сервер пресета — нельзя. Сервер, от которого зависит список
  (член группы, выбор DNS Final или Default Domain Resolver, резолвер имени
  другого сервера), залочен с подписью «used by …»; тап по его переключателю
  показывает «Locked: used by …». Редактор правила предлагает только серверы
  из списка.
- **Дубликат шаблонного или пресетного DNS-сервера ([задача 682](docs/spec/tasks/682-dns-catalog-revision-and-copy.md)).**
  ⋮ → **Duplicate** в редакторе сервера или **Duplicate** в меню долгого
  нажатия на плитке открывает новый свой сервер с телом оригинала (с его
  текущими настройками), тегом `<tag>_copy` и описанием
  `<description> (copy)`. До **Save** ничего не сохраняется. В редакторе
  шаблонного или пресетного сервера теперь есть поле **Tag**: его правка
  превращает Save в **Save as copy**, оригинал остаётся в списке. Группы,
  DNS Final и правила по-прежнему указывают на оригинал.
- **Outbound и адрес у OpenDNS UDP, OpenDNS DoH, Quad9 DoH и Yandex DoT (задача 682).**
  У этих четырёх серверов тело было зашито. Теперь в редакторе есть
  **Outbound** и выбор адреса сервера: основной или запасной, IPv4 или IPv6.
- **Предупреждение, когда Default Domain Resolver ходит через туннель (задача 682).**
  Этот резолвер ищет адреса серверов при установке соединения, когда туннеля
  ещё нет. Если выбранный сервер ходит через Направление или через него ходят
  все члены выбранной группы, у правого края заголовка **Default Domain
  Resolver** появляется оранжевый ⚠; тап объясняет риск («Resolver goes
  through a tunnel»). Выбор не меняется. У Shield по умолчанию ⚠ нет.
- **Перестановка Направлений ([задача 673](docs/spec/tasks/673-directions-reorder-in-ui.md), issue #171).**
  У каждой строки на вкладке **Directions** есть ручка перетаскивания,
  включая `vpn-1`. Во время перетаскивания строки, за которые Направление
  заходить не может, подсвечены красным: Направление, включающее другие,
  должно оставаться ниже них. Сброс туда оставляет список как был и
  объясняет причину.

## 🔄 Изменено

- **Редактор правила: одна секция «DNS & Resolve» (задача 683).**
  Окна «Action & Resolve» и ⚙ рядом с Action больше нет. Action выбирает
  только, куда идёт трафик; **Resolve only** теперь пункт его списка, после
  Reject (у правил с доменами). Секция внизу содержит:
  - **Answer**: Default (запросы идут в DNS Final), **Dedicated server** или
    **Fixed IP**;
  - **Force IPv4 (drop AAAA)**;
  - **Resolve before routing** (бывший Resolve first) со Strategy;
  - **Advanced**, свёрнутый: DNS-сервер для резолва, Disable cache, Disable
    optimistic cache, Rewrite TTL, Query timeout, Client subnet.

  Существующие правила собираются в тот же конфиг. Вкладка **View** теперь
  показывает и DNS-правила правила.
- **Подсказки DNS (задача 684).** ℹ рядом с **DNS Final** и **Default Domain
  Resolver** открывает попап. Он рекомендует `google_doh` или
  `cloudflare_dot` и говорит, что UDP-серверы годятся для DNS Final, но не
  для Default Domain Resolver. Баннер `local_dns_resolver` предлагает
  **Switch to google_doh**.
- **Default traffic — в конце вкладки Rules ([задача 676](docs/spec/tasks/676-route-final-on-rules-tab.md)).**
  Выбор `route.final` стоит после списка правил и **Add rule**, с подписью
  **Default traffic (no rule matched)**. На вкладке Directions его больше
  нет. Записывается то же самое.
- **Направление везде показано своим названием ([задача 672](docs/spec/tasks/672-direction-label-vs-tag-consistency.md)).**
  Уведомление, строка на главном экране, членом которой является другое
  Направление, заголовок редактора Направления, строки маршрута, Chain и
  Detour в Stats → Connections и Live показывают название и рядом тег,
  например `Germany (vpn-1)`. Переименование по-прежнему не меняет тег.
- **Превью фильтра узлов Направления работает с выключенным VPN ([задача 674](docs/spec/tasks/674-direction-filter-preview-without-tunnel.md)).**
  Редактор и счётчик узлов на вкладке Directions берут узлы из сборки
  конфига, поэтому совпадают с собранным конфигом при поднятом туннеле и без
  него. Пустой результат — «No nodes match».
- **На Android TV приложение занимает весь экран ([задача 679](docs/spec/tasks/679-tv-no-portrait-lock.md), issue #163).**
  На TV ориентация не фиксируется, **Allow rotation** там скрыт. Сохранённое
  значение не меняется, поэтому бэкап с TV не включает поворот на телефоне.
- **Автопинг после подключения запускает тест группы только у групп Fastest ([задача 677](docs/spec/tasks/677-autoping-tail-skips-round-robin-groups.md)).**
  У групп Load balance пул больше не пересобирается, группы Hold until
  failure больше не бросают удерживаемый узел после пинга. Задержки всех
  узлов по-прежнему даёт пинг; **Run URLTest** в меню группы работает как
  раньше.

## 🩹 Исправлено

- **Остановка VPN больше не зависает ([задача 668](docs/spec/tasks/668-stop-teardown-trace-and-timeouts.md)).**
  С многими узлами WireGuard, AmneziaWG или WARP остановка снова быстрая:
  ядро ждало приёмный воркер каждого endpoint'а по очереди. У каждого шага
  остановки теперь настоящий предел времени (остановка ядра 20 с, остальные
  шаги 3 с), и служба доходит до Stopped, даже если шаг не вернулся. Шаг,
  зависший дольше 5 с, пишет `stuck at <step>` и дамп горутин в журнал
  приложения, дамп попадает в пакет для поддержки.
- **Test servers при выключенном VPN: Stop останавливает, Start снова запускает ([задача 669](docs/spec/tasks/669-probe-session-cancel-stop-timeout-race.md), issue #171).**
  **Stop** обрывает уже отправленные замеры, а не ждёт их таймаута; в это
  время полоса показывает `Stopping…`. Зависшая тестовая сессия больше не
  блокирует следующий тест и старт VPN.
- **Load balance пропускает узел, проваливший проверку.** Группа
  `round_robin` больше не отправляет новые соединения узлу, провалившему
  последнюю проверку, пока есть живой; неудачный ручной пинг тоже выводит
  узел из ротации до следующей проверки группы.
- **«Register detour in auto group» работает ([задача 670](docs/spec/tasks/670-register-detour-in-auto-group-dead-toggle.md)).**
  Звенья цепочек попадают в авто-группу Направления только при включённом
  переключателе. Он неактивен, пока выключен **Register detour servers**, а
  папка показывает оба переключателя, только если в ней есть звенья цепочек.
- **Авто-узел в папке больше не пропадает молча ([задача 675](docs/spec/tasks/675-folder-auto-node-silent-drop-and-pool-gates.md)).**
  Авто-узел без членов назван в отчёте сборки, а его редактор говорит, что
  узел не попадает в конфиг. Пул следует тем же правилам, что у Направления:
  Tailscale без exit node в него не входит, звенья цепочек — только с
  **Register detour servers**.
- **JSON-превью DNS-группы пропускает выключенных членов ([задача 671](docs/spec/tasks/671-dns-group-json-preview-disabled-members.md)).**
  Как это делает сборка; строка под превью их перечисляет: «Disabled,
  skipped at build: …».
- **Android TV: приём настроек с пульта ([задача 622](docs/spec/tasks/622-device-transfer-phone-to-tv.md)).**
  Экран приёма помещается без прокрутки, стрелки переключают варианты в
  предпросмотре импорта, после него фокус возвращается на карточку передачи.
- **Старт больше не ждёт 10–16 с чужого mux-handshake**, а MASQUE-узел с
  `vhttp: auto` больше не держит в памяти прошлый экземпляр ядра после
  каждого Stop/Start или смены профиля.

## 🔧 Под капотом

- Ядро `v1.14.3-lx.21` → `v1.14.3-lx.23` ([docs/KERNEL.md](docs/KERNEL.md)):
  исправления остановки, старта, MASQUE и Load balance выше; остановка,
  зависшая дольше 20 с, пишет дамп горутин в лог ядра. Java-поверхность та
  же, что в lx.21.
- Контракт с лаунчером 1.1.132 → 1.1.139: каталог шаблона источника в LX
  Backup (`dns.template_catalog`) и одно правило снятия шаблонных
  DNS-серверов при импорте ([задача 681](docs/spec/tasks/681-dns-servers-uniform-backup-catalog.md));
  `rules[].dns.fixedIps` для обеих сторон.
- LX Backup и передача телефон → TV переносят список шаблонных DNS-серверов
  как есть: сервер, удалённый у источника, снимается у приёмника, если на
  него ничего не ссылается (иначе остаётся, с предупреждением). DNS Final или
  резолвер по умолчанию, указывающий на отсутствующий сервер, сбрасывается
  на умолчание шаблона, а группа без известных членов приезжает выключенной.
  Старые бэкапы ничего не теряют.
- Debug API: `POST /directions/reorder` и `include` в `POST`/`PATCH
  /directions`, ставящие Направление выше включаемого им, получают 409 с
  парами в `conflicts`; правила читают и пишут `dns.fixed_ips`.
- Форматтер шаблона (`app/scripts/format_wizard_template.py`) понимает
  текущий язык шаблона и проверяет смысл перед записью; `wizard_template.json`
  переформатирован, 2367 → 760 строк, содержание то же ([задача 678](docs/spec/tasks/678-format-wizard-template-new-dialect.md)).
- Новые тесты: эмиссия и хранение Fixed IP, секция DNS & Resolve, копия
  DNS-сервера, предупреждение о резолвере через туннель, умолчания DNS всего
  каталога и Ru internet segment, запретные зоны перестановки Направлений,
  пул превью фильтра, остановка пробной сессии, раскладка приёма на TV и
  фокус D-pad, корпус контракта `rule_dns`.

</details>

---

## Install / Установка

```bash
adb install -r LxBox-v2.25.17-arm64-v8a.apk
```

Без uninstall! Поверх существующей установки. Настройки и подписки сохранятся.

No uninstall needed — install over the existing one. Settings and subscriptions
are preserved.

---

Previous release / Предыдущий релиз: [v2.25.16](docs/releases/v2.25.16.md).
