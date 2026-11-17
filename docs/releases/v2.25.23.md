# L×Box v2.25.23

**A patch on top of [v2.25.22](https://github.com/Leadaxe/LxBox/releases/tag/v2.25.22).**

**An imported backup is no longer lost**: it shows up at once, without a
restart. **Android TV remote**: the arrow keys no longer get stuck in option lists
(theme, language and others) or in text fields of forms. **Comments in a
server's JSON are kept** on the Source tab and in backups. Greyed-out
dependent settings no longer look enabled. Inside a folder, a server whose
detour is unavailable gets its own ⚠. Core `v1.14.4-lx.35` (unchanged),
contract 1.1.172.

**Патч поверх [v2.25.22](https://github.com/Leadaxe/LxBox/releases/tag/v2.25.22).**

**Импортированный бэкап больше не теряется**: он виден сразу, без
перезапуска. **Пульт Android TV**: стрелки больше не застревают в списках-переключателях
(тема, язык и другие) и в текстовых полях форм. **Комментарии в JSON
сервера сохраняются** — на вкладке Source и в бэкапе. Серые зависимые
настройки больше не выглядят включёнными. В папке сервер с недоступным
detour получает свой ⚠. Ядро `v1.14.4-lx.35` (без изменений), контракт
1.1.172.

---

<details open>
<summary><h2>🇬🇧 English</h2></summary>

## ⚠️ Changed

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
- Shared contract 1.1.172 (comments in a JSON node source).
- Core `v1.14.4-lx.35`, unchanged.

</details>

<details open>
<summary><h2>🇷🇺 Русский</h2></summary>

## ⚠️ Изменено

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
- Общий контракт 1.1.172 (комментарии в JSON-исходнике узла).
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
