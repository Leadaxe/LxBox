# L×Box v2.25.23-rc.2

**The second release candidate on top of [v2.25.22](https://github.com/Leadaxe/LxBox/releases/tag/v2.25.22).** Everything from rc.1 stays; new since rc.1: Block HTTPS/SVCB records, DNS options of a rule with port and protocol filters, the «Errors (N)» row above the navigation bar, and assistant checks while the core is not up yet.

This is a pre-release on GitHub; in Google Play it goes to Open testing. It is
not offered to users of the stable release. It is a candidate because the app
was split into two processes and this was checked on emulators only.

**Domain rules no longer miss sites with ECH** ([#227](https://github.com/Leadaxe/LxBox/issues/227)):
a rule's DNS & Resolve section gets **Block HTTPS/SVCB records**, and a preset
of the same name does it for every site. **DNS options of a rule work with
port and protocol filters.** **The app now runs as two processes**: the VPN tunnel and the window live apart, so closing the window frees its memory while the VPN keeps working, and with the VPN off and the window closed nothing stays in memory. **An AI assistant** (Android 16+) can diagnose and manage the network. **An imported backup is no longer lost**: it shows up at once, without a
restart. **Android TV remote**: the arrow keys no longer get stuck in option lists
(theme, language and others) or in text fields of forms. **Comments in a
server's JSON are kept** on the Source tab and in backups. Greyed-out
dependent settings no longer look enabled. Inside a folder, a server whose
detour is unavailable gets its own ⚠. Core `v1.14.4-lx.35` (unchanged),
contract 1.1.173.

**Второй релиз-кандидат поверх [v2.25.22](https://github.com/Leadaxe/LxBox/releases/tag/v2.25.22).** Всё из rc.1 остаётся; нового с rc.1: Block HTTPS/SVCB records, DNS-опции правила с фильтрами по портам и протоколам, строка «Errors (N)» над панелью навигации и проверки ассистента, пока ядро ещё не поднялось.

На GitHub это pre-release; в Google Play он уходит в открытое тестирование.
Пользователям стабильной версии не предлагается. Кандидат — потому что
приложение разделено на два процесса, а проверено это только на эмуляторах.

**Правила по домену больше не пропускают сайты с ECH** ([#227](https://github.com/Leadaxe/LxBox/issues/227)):
в секции DNS & Resolve правила — **Block HTTPS/SVCB records**, а одноимённый
пресет делает то же для всех сайтов. **DNS-опции правила работают с фильтрами
по портам и протоколам.** **Приложение теперь работает в двух процессах**: туннель VPN и окно живут раздельно — закрыли окно, его память освободилась, а VPN работает; при выключенном VPN и закрытом окне в памяти не остаётся ничего. **ИИ-ассистент** (Android 16+) может диагностировать сеть и управлять ей. **Импортированный бэкап больше не теряется**: он виден сразу, без
перезапуска. **Пульт Android TV**: стрелки больше не застревают в списках-переключателях
(тема, язык и другие) и в текстовых полях форм. **Комментарии в JSON
сервера сохраняются** — на вкладке Source и в бэкапе. Серые зависимые
настройки больше не выглядят включёнными. В папке сервер с недоступным
detour получает свой ⚠. Ядро `v1.14.4-lx.35` (без изменений), контракт
1.1.173.

---

<details open>
<summary><h2>🇬🇧 English</h2></summary>

## ⚠️ Changed

- **Block HTTPS/SVCB records: domain rules see sites behind ECH ([task 755](docs/spec/tasks/755-block-https-svcb-records.md), [#227](https://github.com/Leadaxe/LxBox/issues/227)).** New since rc.1.
  Without FakeIP, Chrome took the ECH key from the site's HTTPS DNS record and
  hid the real name behind a shared one such as `cloudflare-ech.com`. A rule
  like `rutracker.org → vpn-1` then never matched, and the traffic silently
  left by the default route. A rule's DNS & Resolve section now has **Block
  HTTPS/SVCB records**: HTTPS and SVCB queries for the rule's domains get an
  empty answer, the browser sends the name in the clear, and the rule
  matches. Defaults: the box ticks itself when you fill in domains in a new
  or edited rule; it is unavailable without a domain condition; **saved rules
  are not changed** — open the rule and tick it. A new preset of the same name
  (Routing → Rules → +) does it for every site and is **off by default**.
  Apps with their own DNS-over-HTTPS (a fixed Secure DNS provider in Chrome,
  DoH in Firefox) are not affected. **Not checked on a device.**
- **DNS options of a rule work with port and protocol filters ([task 755](docs/spec/tasks/755-block-https-svcb-records.md)).** New since rc.1.
  Dedicated server, Fixed IP, Force IPv4 and Block HTTPS were greyed out once
  a rule had a port, protocol or network filter. They now apply to the rule's
  domains on any port and protocol; a custom rule's ports moved from its
  rule-set to the routing rule, the match is the same. **Note:** a Force IPv4
  box or a DNS option that was set on such a rule and silently did nothing
  now takes effect.

- **Two processes: the tunnel and the window ([task 747](docs/spec/tasks/747-two-processes-ui-bg.md)).**
  The VPN service with the core runs in its own process, the window with the
  interface in another. Closing the window (swiping the app away) ends its
  process: with the VPN on, memory drops from about 240 MB to about 110 MB
  (emulator); with the VPN off and the window closed the app leaves nothing in
  memory. With the VPN off and the window open the core is unloaded too. While
  the VPN is on and the window is only minimised, everything works as before:
  subscription updates, automation, the Debug API. Opening the app after the
  window was closed is a cold start (about 1.5 s on the emulator). The tile,
  auto-start, automation and the assistant bring the tunnel process up by
  themselves. **Checked on Android 14 and 16 emulators only, not on phones —
  this is why it ships as a release candidate.** One unexplained case in about
  a hundred attempts: a start issued a few seconds after a stop under heavy
  host load did not bring the tunnel up; it was not reproduced, and the start
  path now writes a trace into the log. If a start does nothing, press Start
  again and send the debug dump.
- **An AI assistant can diagnose and manage the network ([task 750](docs/spec/tasks/750-ai-assistant-network-control.md)).**
  On Android 16+ the functions for system assistants grow from three to ten;
  the Debug API gets `/assistant/*` routes. Off by default («AI assistant
  control» in App Settings). Not checked on a device.
- **Comments in a server's JSON are kept ([task 741](docs/spec/tasks/741-json-comments-kept-in-source.md), [#171](https://github.com/Leadaxe/LxBox/issues/171), contract 1.1.172).**
  A server pasted or edited as JSON keeps its `//`, `/* */` and `#`
  comments: the Source tab shows the text as typed after pasting, saving and
  restoring a backup, and the «Comments were removed.» message is gone.
  Comments are skipped only when the app reads the JSON; the same server with
  and without comments is still one server in a backup. Comments are still
  lost where the app rewrites the text itself: a pasted whole config (only
  its nodes are kept), the Format button, Edit JSON and the masquerade
  section.
- **A folder's server with an unavailable detour is marked in the list ([task 739](docs/spec/tasks/739-detour-unavailable-node-warning.md)).**
  Inside a folder, the server whose detour was removed at build now shows the
  ⚠ «Hop … unavailable: hop removed» line on its own row, not only on the
  folder and the server's card. Tap it to read what happened; it goes away
  after the next build once the target is back.

## 🐛 Fixed

- **The «Errors (N)» row no longer hides under the navigation bar ([task 754](docs/spec/tasks/754-errors-row-under-navigation-bar.md)).** New since rc.1.
  With three-button navigation the red row on the main screen was drawn
  under the system buttons, and a tap hit the system button instead of
  opening the error log. The row now sits above the bar.
- **Assistant URL and exit checks while the core is not up ([task 750](docs/spec/tasks/750-ai-assistant-network-control.md)).** New since rc.1.
  `checkUrl` and `checkExit` called before the core is reachable answer «The
  VPN core is not reachable yet», like `selectExit`, instead of a raw RPC
  error.

- **Imported backup shows up at once and is no longer lost ([task 748](docs/spec/tasks/748-backup-import-remounts-scene.md)).**
  After Settings → Backup → Transfer to desktop → Import, the imported
  servers did not appear until the app was restarted. Worse, changing
  anything in the server list before a restart, such as turning a server
  off, wrote the old list back and the imported servers were gone. The same
  happened after a regular restore if «Restart now» was not tapped. Now the
  app reloads its state right after the import and returns to the main
  screen: everything imported is visible at once and later changes keep it.
  The running VPN is not stopped; the config is rebuilt like after any
  settings change.
- **TV remote no longer gets stuck in option lists ([task 744](docs/spec/tasks/744-tv-dpad-radio-groups.md), [#222](https://github.com/Leadaxe/LxBox/issues/222)).**
  In lists of round options — theme and language in App Settings →
  Appearance, background mode, detour mode, rule type and others — the arrow
  keys used to pick the next option at once and loop inside the list, so on
  Android TV the theme changed while you just moved past it and there was no
  way out with the remote. Arrows now only move the focus and leave the list
  at its first and last option; OK, Enter, Space or a tap picks an option.
  Switching a tab with the mouse or by touch also takes the focus off the
  hidden tab, so the keys no longer change settings you cannot see.
- **TV remote leaves text fields ([task 746](docs/spec/tasks/746-tv-text-field-dpad-exit.md)).**
  On Android TV the remote got stuck in any text field of a form — a rule
  name, OpenConnect fields, a subscription URL: up and down only moved the
  cursor, so the buttons and switches below could not be reached. Now up and
  down leave a one-line field; in a multi-line field they leave from its
  first or last line. Left and right still move the cursor and leave the
  field at the start or end of the text. While the on-screen keyboard is
  open it keeps the arrows for itself — close it first.
- **Dependent settings no longer look enabled when they are not in effect ([task 743](docs/spec/tasks/743-disabled-vars-look-off.md), [#171](https://github.com/Leadaxe/LxBox/issues/171)).**
  In VPN Settings → Core → WireGuard, with «Suspend idle tunnels» off, «Lazy
  tunnel build» and «Built tunnels limit» are not passed to the core, but the
  greyed rows kept showing «on» and «12». A greyed row now shows a switch as
  off and a list as «Not in effect»; the saved value returns when the row
  becomes active again.

## 🔧 Under the hood

- Architecture pass ([task 740](docs/spec/tasks/740-architecture-revision-process-boundary.md),
  742, 745): the boundary between the VPN service and the UI is drawn in
  the code — one owner of the tunnel state, separate core command clients
  for the service and for the UI. Behaviour is unchanged; this prepares
  running the VPN in its own process.
- CI checks the architecture boundaries on every push.
- Shared contract 1.1.173: Block HTTPS/SVCB records — preset and rule field, DNS options without the port gate (since rc.1); 1.1.172 — comments in a JSON node source.
- Core `v1.14.4-lx.35`, unchanged.

</details>

<details open>
<summary><h2>🇷🇺 Русский</h2></summary>

## ⚠️ Изменено

- **Block HTTPS/SVCB records: правила по домену видят сайты за ECH ([задача 755](docs/spec/tasks/755-block-https-svcb-records.md), [#227](https://github.com/Leadaxe/LxBox/issues/227)).** Новое с rc.1.
  Без FakeIP Chrome брал ключ ECH из HTTPS-записи DNS сайта и прятал настоящее
  имя за общим вроде `cloudflare-ech.com`. Правило вида `rutracker.org → vpn-1`
  тогда не срабатывало, и трафик молча уходил маршрутом по умолчанию. В
  секции DNS & Resolve правила появилась галочка **Block HTTPS/SVCB records**:
  на HTTPS- и SVCB-запросы доменов правила — пустой ответ, браузер шлёт имя
  открыто, и правило срабатывает. По умолчанию: галочка ставится сама, когда
  вы заполняете домены в новом или редактируемом правиле; без условия по
  домену она недоступна; **сохранённые правила не меняются** — откройте
  правило и отметьте её. Новый одноимённый пресет (Routing → Rules → +)
  делает то же для всех сайтов и **по умолчанию выключен**. На приложения со
  своим DNS-over-HTTPS (заданный провайдер Secure DNS в Chrome, DoH в Firefox)
  это не действует. **На устройстве не проверено.**
- **DNS-опции правила работают с фильтрами по портам и протоколам ([задача 755](docs/spec/tasks/755-block-https-svcb-records.md)).** Новое с rc.1.
  Dedicated server, Fixed IP, Force IPv4 и Block HTTPS были серыми, как только
  у правила появлялся фильтр по порту, протоколу или сети. Теперь они
  действуют на домены правила на любом порту и протоколе; порты своего
  правила переехали из его набора на маршрутное правило, смысл тот же.
  **Внимание:** отмеченная у такого правила Force IPv4 или DNS-опция, которая
  раньше молча не действовала, теперь начнёт действовать.

- **Два процесса: туннель и окно ([задача 747](docs/spec/tasks/747-two-processes-ui-bg.md)).**
  Сервис VPN с ядром работает в своём процессе, окно с интерфейсом — в другом.
  Закрыли окно (смахнули приложение) — его процесс завершается: при включённом
  VPN память падает примерно с 240 до 110 МБ (эмулятор); при выключенном VPN и
  закрытом окне приложение не оставляет в памяти ничего. При выключенном VPN и
  открытом окне ядро тоже выгружается. Пока VPN включён, а окно только
  свёрнуто, всё работает как раньше: обновление подписок, автоматизация, Debug
  API. Открытие приложения после закрытия окна — холодный старт (около 1,5 с на
  эмуляторе). Плитка, автозапуск, автоматизация и ассистент поднимают процесс
  туннеля сами. **Проверено только на эмуляторах Android 14 и 16, на телефонах
  не проверялось — поэтому это релиз-кандидат.** Один необъяснённый случай
  примерно на сто попыток: старт через несколько секунд после остановки при
  сильной нагрузке хоста не поднял туннель; повторить не удалось, путь старта
  теперь пишет след в журнал. Если Start ничего не сделал — нажмите ещё раз и
  пришлите отладочный дамп.
- **ИИ-ассистент может диагностировать сеть и управлять ей ([задача 750](docs/spec/tasks/750-ai-assistant-network-control.md)).**
  На Android 16+ функций для системных ассистентов становится десять вместо
  трёх; в Debug API появляются маршруты `/assistant/*`. По умолчанию выключено
  («AI assistant control» в App Settings). На устройстве не проверялось.
- **Комментарии в JSON сервера сохраняются ([задача 741](docs/spec/tasks/741-json-comments-kept-in-source.md), [#171](https://github.com/Leadaxe/LxBox/issues/171), контракт 1.1.172).**
  Сервер, вставленный или отредактированный как JSON, сохраняет комментарии
  `//`, `/* */` и `#`: вкладка Source показывает текст как набран — после
  вставки, сохранения и восстановления из бэкапа; сообщение «Comments were
  removed.» убрано. Комментарии пропускаются только при чтении JSON; один и
  тот же сервер с комментариями и без — по-прежнему один сервер в бэкапе.
  Комментарии всё ещё теряются там, где приложение само переписывает текст:
  вставленный целый конфиг (из него берутся только узлы), кнопка Format,
  Edit JSON и секция маскировки.
- **В папке сервер с недоступным detour отмечен в списке ([задача 739](docs/spec/tasks/739-detour-unavailable-node-warning.md)).**
  В списке серверов папки строка ⚠ «Hop … unavailable: hop removed» теперь
  стоит у того сервера, у которого detour снят при сборке, а не только у
  папки и на карточке сервера. По нажатию — что случилось; строка пропадает
  после следующей сборки, когда цель снова доступна.

## 🐛 Исправлено

- **Строка «Errors (N)» больше не уходит под панель навигации ([задача 754](docs/spec/tasks/754-errors-row-under-navigation-bar.md)).** Новое с rc.1.
  При трёхкнопочной навигации красная строка на главном рисовалась под
  системными кнопками, и тап попадал в системную кнопку вместо журнала
  ошибок. Теперь строка стоит над панелью.
- **Проверки адреса и выхода у ассистента, пока ядро не поднялось ([задача 750](docs/spec/tasks/750-ai-assistant-network-control.md)).** Новое с rc.1.
  `checkUrl` и `checkExit`, вызванные до того, как ядро стало доступно,
  отвечают «The VPN core is not reachable yet», как `selectExit`, а не сырой
  ошибкой RPC.

- **Импортированный бэкап виден сразу и больше не теряется ([задача 748](docs/spec/tasks/748-backup-import-remounts-scene.md)).**
  После Settings → Backup → Transfer to desktop → Import импортированные
  серверы не появлялись до перезапуска приложения. Хуже того: любая правка
  списка серверов до перезапуска, например выключение сервера, записывала
  старый список, и импортированное пропадало. То же случалось после
  обычного восстановления, если не нажать «Restart now». Теперь приложение
  сразу перечитывает состояние после импорта и возвращается на главный
  экран: всё импортированное видно и сохраняется при дальнейших правках.
  Работающий VPN не останавливается; конфиг пересобирается, как после любой
  смены настроек.
- **Пульт TV не застревает в списках-переключателях ([задача 744](docs/spec/tasks/744-tv-dpad-radio-groups.md), [#222](https://github.com/Leadaxe/LxBox/issues/222)).**
  В списках-переключателях — тема и язык в App Settings → Appearance,
  фоновый режим, режим detour, тип правила и другие — стрелки сразу выбирали
  соседний пункт и крутились по кругу: на Android TV тема менялась при
  простом перемещении, а выйти из списка пультом было нельзя. Теперь стрелки
  только двигают фокус и выводят из списка на первом и последнем пункте;
  выбор — OK, Enter, Space или касание. При переключении вкладки мышью или
  касанием фокус уходит со скрытой вкладки, и клавиши больше не меняют
  настройки, которых не видно.
- **Пульт TV выходит из текстовых полей ([задача 746](docs/spec/tasks/746-tv-text-field-dpad-exit.md)).**
  На Android TV пульт застревал в любом текстовом поле формы — имя правила,
  поля OpenConnect, URL подписки: стрелки вверх и вниз двигали только
  курсор, и до кнопок и переключателей ниже было не добраться. Теперь вверх
  и вниз выводят из однострочного поля; из многострочного — с первой или
  последней строки. Влево и вправо по-прежнему двигают курсор и выводят из
  поля в начале или в конце текста. Пока открыта экранная клавиатура, стрелки
  принадлежат ей — сначала закройте её.
- **Зависимые настройки больше не выглядят включёнными, когда не действуют ([задача 743](docs/spec/tasks/743-disabled-vars-look-off.md), [#171](https://github.com/Leadaxe/LxBox/issues/171)).**
  В VPN Settings → Core → WireGuard при выключенном «Suspend idle tunnels»
  настройки «Lazy tunnel build» и «Built tunnels limit» ядру не передаются,
  но серые строки продолжали показывать «включено» и «12». Теперь в серой
  строке переключатель рисуется выключенным, список — «Не действует»;
  сохранённое значение возвращается, когда строка снова активна.

## 🔧 Под капотом

- Архитектурная ревизия ([задача 740](docs/spec/tasks/740-architecture-revision-process-boundary.md),
  742, 745): граница между сервисом VPN и интерфейсом проведена в коде —
  один владелец состояния туннеля, отдельные командные клиенты ядра у
  сервиса и у интерфейса. Поведение не менялось; это подготовка к запуску
  VPN в отдельном процессе.
- CI проверяет архитектурные границы на каждом push.
- Общий контракт 1.1.173: Block HTTPS/SVCB records — пресет и поле правила, DNS-опции без гейта портов (с rc.1); 1.1.172 — комментарии в JSON-исходнике узла.
- Ядро `v1.14.4-lx.35`, без изменений.

</details>

---

## Install / Установка

```bash
adb install -r LxBox-v2.25.23-arm64-v8a.apk
```

Без uninstall! Поверх существующей установки. Настройки и подписки сохранятся.

No uninstall needed — install over the existing one. Settings and subscriptions
are preserved.

---

Previous release / Предыдущий релиз: [v2.25.22](docs/releases/v2.25.22.md).
