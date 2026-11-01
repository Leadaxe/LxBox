# L×Box v2.25.19-rc.2

**The second release candidate on top of [v2.25.18](https://github.com/Leadaxe/LxBox/releases/tag/v2.25.18).**

This is a pre-release on GitHub; in Google Play it goes to Open testing. It is
not offered to users of the stable release. It contains everything from
[v2.25.19-rc.1](https://github.com/Leadaxe/LxBox/releases/tag/v2.25.19-rc.1);
below are the changes since rc.1.

**Mixins**: your own additions to the final core config that survive every
rebuild. The memory limit now applies to the core's own memory, and Auto sets
no cap. The «Interrupt connections on switch» switch is removed. Core
`v1.14.4-lx.29`.

**Второй релиз-кандидат поверх [v2.25.18](https://github.com/Leadaxe/LxBox/releases/tag/v2.25.18).**

На GitHub это pre-release, в Google Play сборка уходит в открытое
тестирование. Пользователям стабильного релиза она не предлагается. В нём
всё из [v2.25.19-rc.1](https://github.com/Leadaxe/LxBox/releases/tag/v2.25.19-rc.1);
ниже — изменения относительно rc.1.

**Mixins** — свои вставки в итоговый конфиг ядра, которые переживают любую
пересборку. Лимит памяти теперь действует на память самого ядра, Auto порога
не ставит. Тумблер «Interrupt connections on switch» убран. Ядро
`v1.14.4-lx.29`.

---

<details open>
<summary><h2>🇬🇧 English</h2></summary>

## ⚠️ Read before updating

- **Memory limit: Auto sets no cap, Off is folded into Auto ([task 705](docs/spec/tasks/705-memory-limit-auto-off.md)).**
  The limit is now compared with the core's own memory (its Go runtime), not
  with the whole app process it shares with the interface and libraries: a
  200 MB cap used to trip right at start and only made the garbage collector
  heat the phone. The core keeps watching the phone's free memory as before.
  The 200–768 MB presets stay for an explicit choice, and a value chosen
  earlier is kept.
- **«Interrupt connections on switch» is removed ([task 143](docs/spec/tasks/143-interrupt-connections-on-node-switch.md)).**
  The switch in VPN Settings → System only duplicated each Direction's own
  checkbox of the same name and could override it: the core has dropped a
  Direction's connections on any node switch since 2.20.9. If it was on, the
  update turns the checkbox on in every Direction where it was off. The Debug
  API route `/settings/interrupt_on_switch` is gone; an old backup with this
  setting still restores.

## ✨ New

- **Mixins ([task 704](docs/spec/tasks/704-config-mixins.md)).**
  Config → Mixins keeps operations applied at the end of every config build:
  a target path (`route.rules[action=hijack-dns]`, `inbounds[tag=dns-in]`), a
  verb (append, prepend, before, after, set, merge, remove) and a JSON value.
  The form shows whether the target matches and a preview of the result.
  Unlike a manual edit with Lock config, a mixin survives rebuilds; it travels
  in LX Backup and is available through the Debug API (`/mixins`). A mixin
  that does not apply or adds a duplicate tag stops the build with its name in
  the message. Example: a `direct` inbound on `127.0.0.1:5354` with a
  `hijack-dns` rule hands the core's DNS to another app.
- **Core memory in Statistics → Memory.** The core's figure is shown as «Core
  memory» next to the process RSS, with the limit beside it when a number is
  chosen.

## 🔧 Under the hood

- Core `v1.14.4-lx.28` → `v1.14.4-lx.29`: the memory limit can be compared
  with the core's Go runtime instead of the whole process, and the status
  reports that figure (Leadaxe/sing-box-lx#62).

</details>

<details open>
<summary><h2>🇷🇺 Русский</h2></summary>

## ⚠️ Прочтите до обновления

- **Memory limit: Auto порога не ставит, Off слит с Auto ([задача 705](docs/spec/tasks/705-memory-limit-auto-off.md)).**
  Лимит теперь сравнивается с памятью самого ядра (его Go-рантаймом), а не
  всего процесса приложения, который ядро делит с интерфейсом и
  библиотеками: порог 200 MB срабатывал сразу на старте и только заставлял
  сборщик мусора греть телефон. За свободной памятью телефона ядро следит
  по-прежнему. Пресеты 200–768 MB остаются для явного выбора, выбранное
  раньше значение сохраняется.
- **Тумблер «Interrupt connections on switch» убран ([задача 143](docs/spec/tasks/143-interrupt-connections-on-node-switch.md)).**
  Тумблер в VPN Settings → System только дублировал одноимённую галочку
  каждого Направления и мог её перекрыть: с 2.20.9 ядро само рвёт соединения
  Направления при любой смене узла. Если он был включён, при обновлении
  галочка включается во всех Направлениях, где была снята. Маршрут Debug API
  `/settings/interrupt_on_switch` убран; старый бэкап с этой настройкой
  восстанавливается.

## ✨ Новое

- **Mixins ([задача 704](docs/spec/tasks/704-config-mixins.md)).**
  Config → Mixins хранит операции, которые применяются в конце каждой сборки
  конфига: путь цели (`route.rules[action=hijack-dns]`, `inbounds[tag=dns-in]`),
  глагол (append, prepend, before, after, set, merge, remove) и JSON-значение.
  Форма показывает, находит ли путь цель, и предпросмотр результата. В
  отличие от ручной правки с Lock config, миксин переживает пересборки, едет
  в LX Backup и доступен через Debug API (`/mixins`). Миксин, который не
  применяется или вносит дубль тега, останавливает сборку с его именем в
  сообщении. Пример: inbound `direct` на `127.0.0.1:5354` с правилом
  `hijack-dns` отдаёт DNS ядра другому приложению.
- **Память ядра в Statistics → Memory.** Цифра ядра показана как «Core
  memory» рядом с RSS процесса, с лимитом рядом, если выбрано число.

## 🔧 Под капотом

- Ядро `v1.14.4-lx.28` → `v1.14.4-lx.29`: лимит памяти можно сравнивать с
  Go-рантаймом ядра, а не со всем процессом, и статус отдаёт эту цифру
  (Leadaxe/sing-box-lx#62).

</details>

---

## Install / Установка

```bash
adb install -r LxBox-v2.25.19-rc.2-arm64-v8a.apk
```

Без uninstall! Поверх существующей установки. Настройки и подписки сохранятся.

No uninstall needed — install over the existing one. Settings and subscriptions
are preserved.

---

Previous release / Предыдущий релиз: [v2.25.19-rc.1](https://github.com/Leadaxe/LxBox/releases/tag/v2.25.19-rc.1) · stable / стабильный: [v2.25.18](docs/releases/v2.25.18.md).
