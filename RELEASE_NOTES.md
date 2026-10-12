# L×Box v2.25.13

**A patch on top of [v2.25.12](https://github.com/Leadaxe/LxBox/releases/tag/v2.25.12).**

The VPN can announce a system HTTP proxy to Android 10+, so Chrome and Play go
through the core over TCP. The Unknown traffic preset is on for new installs
and sends ownerless traffic direct. Merge on backup import now really merges.
Speed Test measures Upload only where the server accepts it and shows the
route the core used. A config over 1 MB can be replaced from a file. Setting
hints, the Statistics hint and JSON views match the app. The user guide is
rewritten in both languages. Core `v1.14.3-lx.15` and contract 1.1.115 are
unchanged.

**Патч поверх [v2.25.12](https://github.com/Leadaxe/LxBox/releases/tag/v2.25.12).**

VPN умеет объявить Android 10+ системный HTTP-прокси: Chrome и Play идут через
ядро по TCP. Пресет Unknown traffic на новой установке включён и отправляет
бесхозный трафик напрямую. Merge при импорте бэкапа теперь действительно
сливает. Speed Test меряет Upload только там, где сервер его принимает, и
показывает маршрут, который выбрало ядро. Конфиг больше 1 МБ можно заменить
из файла. Подсказки настроек, подсказка в Statistics и просмотр JSON
приведены к приложению. Руководство пользователя переписано на обоих языках.
Ядро `v1.14.3-lx.15` и контракт 1.1.115 без изменений.

---

<details open>
<summary><h2>🇬🇧 English</h2></summary>

## ⚠️ Read before updating

- **Unknown traffic with Reject switches to Direct.**
  If the preset was on with outbound `reject`, it now uses the new default
  `direct-out`: ownerless traffic leaves past the tunnel instead of being
  dropped. Reject was the default before, and the default is not saved with
  the rule, so the rule follows the new one. To keep it strict, pick Reject
  in the preset's outbound again after updating. A rule with a node or
  another outbound keeps it.

## ✨ Added

- **System HTTP proxy for the VPN network, Android 10+ ([task 629](docs/spec/tasks/629-system-http-proxy-android.md), #165).**
  VPN Settings → Mode → Tunnel options has a new switch, System HTTP proxy,
  off by default. When it is on, the VPN announces a local HTTP proxy
  (`127.0.0.1:2081`, or 2082 if the local proxy already uses 2081) on the VPN
  network. Apps that honor the system proxy (Chrome, Play) connect over TCP
  through the core without their own DNS and QUIC; in Connections they show
  up as inbound `sysproxy-in` with the domain name. UDP and other apps keep
  going through the tunnel. The proxy listens only on loopback and has no
  password: Android cannot pass one. In Proxy mode the switch is hidden.

## 🔄 Changed

- **Unknown traffic is on by default and sends ownerless traffic direct.**
  This changes default behavior. On a new install the preset is on and its
  outbound is `direct-out`. A process that binds to the tunnel interface
  from outside the VPN (`curl --interface tun0` from an excluded app) used
  to reach the server and learn its address; now such traffic leaves
  through the direct outbound and learns nothing new. `reject` stays as the
  strict option. The rule now applies only to the tunnel inbound `tun-in`:
  in Proxy mode it no longer rejects every connection through the local
  proxy, and in VPN+Proxy mode connections to the local proxy (including LAN
  clients) are not judged by it.
- **Speed Test: Upload only where the server accepts it, Via shows the real route ([task 634](docs/spec/tasks/634-speed-test-upload-honest.md)).**
  Upload is measured only for servers with an upload address: Cloudflare,
  Tele2 and four Hostkey servers (Moscow, Frankfurt, Helsinki, New York).
  Other servers show `n/a` on the gauge and in Session History. Only
  requests the server answers below 400 count; a server that accepts nothing
  shows `Failed`. Before, a server without an upload address got the body
  sent to its download address, and a refusal counted as 5 MB sent. Via
  now shows the outbound the core reported for the test connection (a node
  or `direct-out`), `Direct (no VPN)` without VPN, and "Route depends on
  your rules" before the test or when the core reported nothing. Before, it
  showed the node selected on the home screen, although the Ru internet
  segment preset sends Russian test servers to `direct-out`.

## 🩹 Fixed

- **Merge on backup import merges ([task 633](docs/spec/tasks/633-backup-merge-is-merge.md)).**
  Merge promised to add new items and keep existing ones, but only Server
  lists sources were merged. Rules, Directions, chains, DNS, Tunnel apps
  and settings came from the file whole and replaced what the device had.
  Now Merge adds what the device lacks and changes nothing it has. Rules
  match by preset, `id` or content; Directions and chains by tag; DNS
  servers and DNS rules by tag, name or content. Tunnel apps packages are
  joined. A setting already on the device keeps its value; a missing one
  comes from the file. VPN toggles take only keys the device does not have.
  The import dialog shows "new: N, already here: M" under each category,
  and the result reads "Merged: N added, M already here". Debug API
  `POST /backup/import?merge=true` merges the same way. Replace all is
  unchanged.
- **Config Editor: a config over 1 MB can be replaced from a file ([task 635](docs/spec/tasks/635-config-editor-large-file.md)).**
  Such a config opens read-only. The screen suggested editing it elsewhere
  and loading it back, but Load from file only put the text into the
  editor: Save stayed disabled and Back dropped the text. In read-only mode
  Load from file and Paste from clipboard now save the text at once, with
  the same JSON check as Save; a file with broken JSON leaves the config as
  it was. The hint under the editor says the file is saved right away.
- **Setting hints match the app ([task 632](docs/spec/tasks/632-settings-hints-mismatch.md)).**
  Six hints named screens, buttons or behavior that do not exist. Forward
  sing-box logs points to Debug → Log, filter Core. Aggressive battery
  saving says sync resumes when the screen turns on, not on unlock.
  Home-screen shortcut names Connect and Disconnect and says Android 11 and
  newer. Check for updates describes tapping the message, Later and Ignore.
  Auto-record Wi-Fi names the ✕ button (Remove from history). Debug API
  says the token is stored in app settings and left out of Backup by
  default.
- **The Statistics hint leads to Allow VPN bypass ([task 630](docs/spec/tasks/630-stats-bypass-hint-path.md)).**
  The warning icon in the Statistics header pointed to VPN Settings →
  System, which has no such switch. It now points to VPN Settings → Mode →
  Tunnel options → Allow VPN bypass and names the apps that leave the tunnel
  (banking apps, WhatsApp, system services).
- **JSON on the rule's View tab and in the DNS server preview is highlighted ([task 631](docs/spec/tasks/631-rule-view-tab-json-highlight.md)).**
  The storage record and the sing-box preview use the same viewer as the
  other JSON fields: syntax colors, the caption and Copy above the frame.
- **Selection handles in the JSON editor no longer move the tab or the page ([task 628](docs/spec/tasks/628-editor-selection-handles-gestures.md), #167).**
  Dragging a selection handle in a short JSON field, such as a node's
  Source, used to swipe the tab or scroll the page. Now it moves the
  selection. Without a selection a vertical swipe still scrolls the page. A
  field that grew past its line limit after opening scrolls its own text.

## 📚 Documentation

- **The user guide is rewritten ([EN](docs/USER_GUIDE.md), [RU](docs/USER_GUIDE.ru.md)).**
  Both versions follow one structure, paragraph for paragraph, and were
  checked against the app: names, paths and limits are as on screen. New
  sections cover VPN Settings, App Settings, Presets, Speed Test, Config
  Editor, Backup, the node's Dependents and Diagnostics tabs and Replace
  with a group. Setting up from scratch moved near the start.
- **Three "Interrupt connections on switch" options (#166).**
  The guide explains which of the three options reacts to which event: the
  VPN Settings switch to a node tapped on the home screen, the Direction
  editor's switch to any change of the Direction's choice, the auto group's
  switch to the group changing node by itself.
- **Checking the tun0 leak ([SECURITY.md](docs/SECURITY.md) §2.4).**
  How to run the `curl --interface tun0` probe from Termux and what each
  Unknown traffic setting returns.
- **Editorial policy** (`docs/EDITORIAL_POLICY.ru.md`): internal rules for
  user-facing texts.

## 🔧 Under the hood

- Core `v1.14.3-lx.15` (unchanged).
- Contract 1.1.115 (unchanged).

</details>

<details open>
<summary><h2>🇷🇺 Русский</h2></summary>

## ⚠️ Прочтите до обновления

- **Unknown traffic с Reject переходит на Direct.**
  Если пресет был включён с outbound `reject`, теперь он использует новое
  умолчание `direct-out`: бесхозный трафик уходит мимо туннеля, а не
  отбрасывается. Reject раньше был умолчанием, а умолчание с правилом не
  сохраняется, поэтому правило следует новому. Чтобы оставить строгий режим,
  после обновления снова выберите Reject в outbound пресета. Правило с узлом
  или другим outbound сохраняет его.

## ✨ Добавлено

- **Системный HTTP-прокси для VPN-сети, Android 10+ ([задача 629](docs/spec/tasks/629-system-http-proxy-android.md), #165).**
  В VPN Settings → Mode → Tunnel options появился тумблер System HTTP proxy,
  по умолчанию выключен. Когда он включён, VPN объявляет на VPN-сети
  локальный HTTP-прокси (`127.0.0.1:2081`, или 2082, если 2081 уже занят
  локальным прокси). Приложения, уважающие системный прокси (Chrome, Play),
  ходят через ядро по TCP, без своего DNS и QUIC; в Connections они видны
  как inbound `sysproxy-in` с именем домена. UDP и остальные приложения
  по-прежнему идут через туннель. Прокси слушает только loopback и без
  пароля: Android не умеет его передать. В режиме Proxy тумблер скрыт.

## 🔄 Изменено

- **Unknown traffic включён по умолчанию и отправляет бесхозный трафик напрямую.**
  Это меняет поведение по умолчанию. На новой установке пресет включён, его
  outbound — `direct-out`. Процесс, который привязывается к интерфейсу
  туннеля снаружи VPN (`curl --interface tun0` из исключённого приложения),
  раньше доходил до сервера и узнавал его адрес; теперь такой трафик уходит
  через прямой выход и ничего нового не узнаёт. `reject` остаётся строгим
  вариантом. Правило теперь действует только на inbound туннеля `tun-in`: в
  режиме Proxy оно больше не отвергает все соединения через локальный
  прокси, а в режиме VPN+Proxy не судит соединения к локальному прокси (в
  том числе клиентов из LAN).
- **Speed Test: Upload только там, где сервер его принимает, Via показывает настоящий маршрут ([задача 634](docs/spec/tasks/634-speed-test-upload-honest.md)).**
  Upload меряется только у серверов с адресом отправки: Cloudflare, Tele2 и
  четыре сервера Hostkey (Moscow, Frankfurt, Helsinki, New York). У
  остальных на шкале и в Session History — `n/a`. Засчитываются только
  запросы, на которые сервер ответил кодом ниже 400; если сервер не принял
  ничего — `Failed`. Раньше сервер без адреса отправки получал тело на адрес
  скачивания, а отказ засчитывался как отправленные 5 МБ. Via теперь
  показывает outbound, который ядро сообщило для соединения теста (узел или
  `direct-out`), `Direct (no VPN)` без VPN и «Route depends on your rules»
  до теста или если ядро ничего не сообщило. Раньше там стоял узел с
  главного экрана, хотя пресет Ru internet segment отправляет российские
  тестовые серверы в `direct-out`.

## 🩹 Исправлено

- **Merge при импорте бэкапа сливает ([задача 633](docs/spec/tasks/633-backup-merge-is-merge.md)).**
  Merge обещал добавить новое и сохранить имеющееся, но сливались только
  источники Server lists. Правила, Направления, цепочки, DNS, Tunnel apps и
  настройки приходили из файла целиком и заменяли то, что было на
  устройстве. Теперь Merge добавляет то, чего на устройстве нет, и не меняет
  то, что есть. Правила сопоставляются по пресету, `id` или содержимому;
  Направления и цепочки — по тегу; DNS-серверы и DNS-правила — по тегу,
  имени или содержимому. Пакеты Tunnel apps объединяются. Настройка, которая
  уже есть на устройстве, сохраняет своё значение; отсутствующая берётся из
  файла. Из VPN toggles берутся только ключи, которых на устройстве нет. Окно
  импорта показывает «new: N, already here: M» под каждой категорией, итог —
  «Merged: N added, M already here». Debug API
  `POST /backup/import?merge=true` сливает так же. Replace all не изменился.
- **Редактор конфига: конфиг больше 1 МБ можно заменить из файла ([задача 635](docs/spec/tasks/635-config-editor-large-file.md)).**
  Такой конфиг открывается только для чтения. Экран советовал править его
  вне устройства и загрузить обратно, но Load from file только клал текст в
  редактор: Save оставалась неактивной, а Back терял текст. В режиме только
  для чтения Load from file и Paste from clipboard теперь сразу сохраняют
  текст, с той же проверкой JSON, что Save; файл с битым JSON оставляет
  конфиг прежним. Подсказка под редактором говорит, что файл сохраняется
  сразу.
- **Подсказки настроек соответствуют приложению ([задача 632](docs/spec/tasks/632-settings-hints-mismatch.md)).**
  Шесть подсказок называли экраны, кнопки или поведение, которых нет.
  Forward sing-box logs ведёт в Debug → Log, фильтр Core. Aggressive battery
  saving говорит, что синхронизация возобновляется при включении экрана, а
  не при разблокировке. Home-screen shortcut называет Connect и Disconnect и
  указывает Android 11 и новее. Check for updates описывает тап по
  сообщению, Later и Ignore. Auto-record Wi-Fi называет кнопку ✕ (Remove
  from history). Debug API говорит, что токен хранится в настройках
  приложения и по умолчанию не входит в Backup.
- **Подсказка в Statistics ведёт к Allow VPN bypass ([задача 630](docs/spec/tasks/630-stats-bypass-hint-path.md)).**
  Значок-предупреждение в шапке Statistics отправлял в VPN Settings →
  System, где такого тумблера нет. Теперь он ведёт в VPN Settings → Mode →
  Tunnel options → Allow VPN bypass и называет приложения, которые уходят
  мимо туннеля (банковские приложения, WhatsApp, системные службы).
- **JSON на вкладке View правила и в превью DNS-сервера подсвечен ([задача 631](docs/spec/tasks/631-rule-view-tab-json-highlight.md)).**
  Запись хранилища и превью sing-box показываются тем же просмотрщиком, что
  остальные JSON-поля: подсветка синтаксиса, подпись и Copy над рамкой.
- **Ручки выделения в JSON-редакторе больше не двигают вкладку и страницу ([задача 628](docs/spec/tasks/628-editor-selection-handles-gestures.md), #167).**
  Ручка выделения в коротком JSON-поле, например в Source узла, листала
  вкладку или прокручивала страницу. Теперь она двигает выделение. Без
  выделения вертикальный свайп, как и раньше, прокручивает страницу. Поле,
  которое после открытия выросло за предел строк, прокручивает свой текст.

## 📚 Документация

- **Руководство пользователя переписано ([EN](docs/USER_GUIDE.md), [RU](docs/USER_GUIDE.ru.md)).**
  Обе версии идут по одной структуре, абзац в абзац, и сверены с
  приложением: названия, пути и ограничения — как на экране. Новые разделы:
  VPN Settings, App Settings, Presets, Speed Test, Config Editor, Backup,
  вкладки узла Dependents и Diagnostics, Replace with a group. «Порядок
  настройки с нуля» поднят к началу.
- **Три настройки «Interrupt connections on switch» (#166).**
  Руководство объясняет, какая из трёх настроек отвечает на какое событие:
  тумблер в VPN Settings — на тап по узлу на главном экране, тумблер в
  редакторе Направления — на любую смену выбора Направления, тумблер
  авто-группы — на смену узла самой группой.
- **Проверка утечки через tun0 ([SECURITY.ru.md](docs/SECURITY.ru.md) §2.4).**
  Как запустить проверку `curl --interface tun0` из Termux и что она
  возвращает при каждом варианте Unknown traffic.
- **Редакционная политика** (`docs/EDITORIAL_POLICY.ru.md`): внутренние
  правила для текстов, которые читает пользователь.

## 🔧 Под капотом

- Ядро `v1.14.3-lx.15` (без изменений).
- Контракт 1.1.115 (без изменений).

</details>

---

## Install / Установка

```bash
adb install -r LxBox-v2.25.13-arm64-v8a.apk
```

Без uninstall! Поверх существующей установки. Настройки и подписки сохранятся.

No uninstall needed — install over the existing one. Settings and subscriptions
are preserved.

---

Previous release / Предыдущий релиз: [v2.25.12](docs/releases/v2.25.12.md).
