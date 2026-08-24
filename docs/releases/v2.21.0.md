# L×Box v2.21.0

**Channels are now Directions** — the rename runs through every screen, and
through the Debug API path. Chains of hops arrive on mobile: build a route
through two or more servers, drag the order, see the price of every hop in a
layered probe — and watch a broken layer get named instead of guessing.
Directions grow custom tags and composition; backups now carry directions and
chains between the launcher and L×Box; edits apply to a live tunnel on their
own.

**Каналы стали Направлениями** — переименование прошло по всем экранам и по
пути Debug API. На мобиле появились цепочки хопов: маршрут через два и более
серверов, порядок перетаскиванием, цена каждого хопа в послойной пробе — и
сломанный слой называется по имени, а не угадывается. У Направлений —
произвольные теги и состав; бэкап переносит Направления и цепочки между
лаунчером и L×Box; правки применяются к живому туннелю сами.

<details open>
<summary><h2>🇬🇧 English</h2></summary>

## 🏷 Channels are now Directions

The routing entity you pick a route with is renamed **Channel → Direction**
everywhere it is visible: the routing screen and its tab, the rule editor's
target picker, the servers filter, menus, hints, empty states and error
messages. “Channel” is a networking word with other jobs; “Direction” says
what the thing actually is — a named choice of where traffic goes.

**Your data migrates itself.** The storage key moves `channels` → `directions`
in a one-shot migration on first launch — directions, their filters, auto
twins and every rule pointing at them come across as they were. Nothing to
export, re-create or re-point; backups made by older versions still import.

**The Debug API path changed: `/channels` → `/directions`, with no alias.**
The old path is gone rather than deprecated, so scripts and automation calling
it need a one-line edit. `/directions` takes and returns the same shape under
the new name; `/help` lists the current set.

Tags keep working: `vpn-1 … vpn-10` are ordinary tags now, not a fixed
vocabulary — existing ones stay valid and referenced. The 10-direction cap
that came with them is lifted, and new directions can be named anything (see
below).

## 🔗 Chains of hops

A chain is a **third kind of source**, next to subscriptions and servers: an
explicit route `you → hop 1 → hop 2 → destination`. Positions are nodes,
groups or Directions; a Direction as a hop makes that step switchable on the
fly. Chains live in the common source list as equal rows — toggled, dragged
and filtered like everything else, measured by a Direction's auto-twin.

The editor holds the core's start-time invariants — the exact class of errors
`sing-box check` passes and `run` dies on: at least two positions, no
duplicates or self-references, nested chains only at position 0,
reality+strip conflicts, references only to chains above. Positions reorder
by drag; the target picker caps at ¾ of the screen.

Deleting a source cleans its **positions** out of chains (with a visible
counter — a shortened route must be noticed); a chain that drops below two
positions stops being emitted until repaired. A subscription refresh never
touches chain positions.

## 📊 Layered diagnostics

Open a chain's node → Diagnostics: every hop with cumulative latency and its
own price — `67 ms → 91 ms (+24) → 96 ms (+5)`. A dead layer shows the core's
error text and marks the rest “not reached”, so “where does the route break?”
takes one look. “Probe again” re-measures. The layer tag scheme
(`chain-1#0…`) is the core's documented contract, shared with the launcher.

Practical notes from live runs: MASQUE placed after a TCP hop needs
`vhttp: auto` (see below); WireGuard behind a TCP hop requires a server that
actually proxies UDP.

## 🧭 Directions, reworked

- **Custom tags** — `ru-exit` instead of the next `vpn-N`; the 10-direction
  cap is gone. Tags are validated against duplicates, service names and
  auto-twin collisions, with machine-readable reasons.
- **Composition** — a Direction can include `direct-out`, `block` and other
  Directions listed above it; the selector order follows the config canon
  (options first, then nodes — the first entry is the core's implicit
  default).
- The edit form is grouped into “What goes into this direction” and
  “Behavior”; changing a subscription's tag prefix now rewrites the literal
  prefix inside Direction filters (ambiguous patterns get a warning instead
  of a guess).

## ♻️ Edits apply themselves

Editing sources while the tunnel is up no longer ends with a “restart VPN”
banner: the config regenerates **and applies** via an in-place reload — the
tunnel survives, the snackbar says so, and a 3-second cooldown keeps a burst
of edits from stampeding the core.

## 💾 Backup that carries the whole model

The LX Backup exchange with the launcher (contract 0.7.1) now moves:

- **`directions[]`** — targets travel with the rules, parsed first, so a rule
  whose Direction arrived in the same file lands *enabled*, not dead;
- **`chains[]`** — a root section instead of a launcher-private blob; merge
  by tag, your local chain wins over an arriving namesake (with a warning);
- **WARP accounts and DNS** — both directions; a merge never overwrites a
  live registration;
- vars, route target and subscriptions are now *applied* on import, not just
  shown; the other app's private data survives a round-trip untouched.

## 🛡 One broken element no longer takes the VPN down

A final graph sanitizer walks every edge of the outbound graph (members,
detours, includes, chain positions) to a fixpoint: dangling references,
cross-edge cycles, emptying groups and out-of-composition defaults degrade
that one element with a warning — instead of the core rejecting the whole
config. An empty Direction still blocks traffic rather than leaking it past
the VPN.

## ⚙️ WARP: `vhttp: auto`

The MASQUE wizard offers **Auto (h3 → h2)** and defaults to it for new
endpoints: HTTP/3 gets a 3-second budget, then the tunnel falls back to
HTTP/2 over TCP — the winner is remembered. This is what makes MASQUE work
behind TCP hops in chains and on networks where QUIC/UDP is cut.

## 🧰 Core and internals

- Core pinned to **sing-box-lx v1.14.0-lx.28-rc.1**: `type: chain`, the
  layer-tag contract anchored in the core, `masque: tunnel died` warnings
  naming the guilty layer, and `vhttp` defaulting to `auto`.
- Debug API: full `/chains` CRUD with the same validation the form enforces,
  `GET /chains/{tag}/probe` for scripted layer probes; `/help` refreshed.
- Template loading now validates `#enable` bodies and all template sections —
  a typo fails loudly at load instead of a node silently vanishing.
- The Servers menu is regrouped: create / get ready-made / import /
  subscriptions.

## 🧪 Tests

`flutter analyze`, **3 968 tests** and all six checkers pass. The shared
contract corpus is green on both sides at 0.7.1. Verified live on an
emulator: chain traffic end-to-end through three hops, cross-app backup
round-trips, layered probes on a running core.

</details>

<details open>
<summary><h2>🇷🇺 Русский</h2></summary>

## 🏷 Каналы стали Направлениями

Сущность, которой выбирают маршрут, переименована **Канал → Направление**
везде, где она видна: экран роутинга и его вкладка, выбор цели в редакторе
правил, фильтр на экране серверов, меню, подсказки, пустые состояния и тексты
ошибок. «Канал» в сетевой терминологии занят другими смыслами; «Направление»
называет вещь тем, чем она является, — именованным выбором, куда идёт трафик.

**Данные переезжают сами.** Ключ хранилища меняется `channels` → `directions`
одноразовой миграцией на первом запуске — Направления, их фильтры,
авто-двойники и все правила, которые на них ссылаются, приходят как были.
Ничего выгружать, пересоздавать и перенаправлять не нужно; бэкапы старых
версий по-прежнему импортируются.

**Путь Debug API сменился: `/channels` → `/directions`, без алиасов.** Старый
путь именно убран, а не объявлен устаревшим, — скриптам и автоматизации,
которые в него ходят, нужна правка в одну строку. `/directions` принимает и
отдаёт то же самое под новым именем; актуальный набор — в `/help`.

Теги продолжают работать: `vpn-1 … vpn-10` теперь обычные теги, а не
фиксированный словарь, — существующие остаются валидными, и ссылки на них
живы. Потолок в 10 Направлений, который шёл с этим словарём, снят, а новые
Направления можно называть как угодно (ниже).

## 🔗 Цепочки хопов

Цепочка — **третий вид источника**, рядом с подписками и серверами: явный
маршрут «вы → хоп 1 → хоп 2 → цель». Позиция — узел, группа или Направление;
Направление-хоп делает эту ступень переключаемой на лету. Цепочки живут в
общем списке источников равноправными строками — включаются, перетаскиваются
и ловятся фильтрами как всё остальное, меряются авто-двойником Направления.

Редактор держит инварианты старта ядра — ровно тот класс ошибок, который
`sing-box check` пропускает, а `run` роняет: минимум две позиции, без дублей
и самоссылок, вложенная цепочка только первой позицией, конфликты
reality+strip, ссылки только на цепочки выше. Позиции переставляются
перетаскиванием; пикер целей не выше ¾ экрана.

Удаление источника вычищает из цепочек его **позиции** (со счётчиком на
виду — укороченный маршрут обязан быть замечен); цепочка, упавшая ниже двух
позиций, не собирается до починки. Обновление подписки позиции не трогает.

## 📊 Послойная диагностика

Узел цепочки → «Диагностика»: каждый хоп с накопленной задержкой и своей
ценой — `67 ms → 91 ms (+24) → 96 ms (+5)`. Мёртвый слой показывает текст
ошибки ядра и помечает остаток «не достигнут» — вопрос «где рвётся маршрут?»
решается одним взглядом. «Замерить снова» повторяет прогон. Схема тегов
слоёв (`chain-1#0…`) — документированный контракт ядра, общий с лаунчером.

Полевые заметки живых прогонов: MASQUE позади TCP-хопа требует
`vhttp: auto` (ниже); WireGuard за TCP-хопом — сервера, реально
проксирующего UDP.

## 🧭 Направления, переработанные

- **Произвольные теги** — `ru-exit` вместо очередного `vpn-N`; потолок в 10
  Направлений снят. Теги проверяются на дубли, служебные имена и коллизии с
  авто-двойниками, с машинными кодами причин.
- **Состав** — Направление может включать `direct-out`, `block` и другие
  Направления, стоящие выше; порядок селектора следует канону конфига
  (опции первыми, затем узлы — первая запись это неявный default ядра).
- Форма сгруппирована в «Что входит в Направление» и «Поведение»; смена
  префикса тегов подписки теперь переписывает литеральный префикс в фильтрах
  Направлений (неоднозначные паттерны получают предупреждение, а не догадку).

## ♻️ Правки применяются сами

Правка источников при живом туннеле больше не заканчивается баннером
«перезапустите VPN»: конфиг пересобирается **и применяется** через
in-place reload — туннель переживает, снекбар говорит об этом, а кулдаун в
3 секунды не даёт серии правок устроить шторм перезагрузок.

## 💾 Бэкап, который возит всю модель

Обмен LX Backup с лаунчером (контракт 0.7.1) теперь переносит:

- **`directions[]`** — цели едут вместе с правилами и разбираются первыми:
  правило, чьё Направление приехало в том же файле, приходит *рабочим*, а не
  мёртвым;
- **`chains[]`** — корневая секция вместо приватного блоба лаунчера; merge
  по тегу, своя одноимённая цепочка сильнее приехавшей (с предупреждением);
- **аккаунты WARP и DNS** — в обе стороны; merge не перетирает живую
  регистрацию;
- переменные, цель маршрута и подписки на импорте теперь *применяются*, а не
  только показываются; приватные данные другого приложения переживают круг
  нетронутыми.

## 🛡 Один битый элемент больше не роняет VPN

Финальный санитайзер графа проходит все рёбра outbound-графа (члены, detour,
include, позиции цепочек) до фикспойнта: висячие ссылки, кросс-рёберные
кольца, пустеющие группы и default вне состава деградируют один элемент с
предупреждением — вместо отказа ядра от всего конфига. Пустое Направление
по-прежнему блокирует трафик, а не выпускает его мимо VPN.

## ⚙️ WARP: `vhttp: auto`

Визард MASQUE предлагает **Auto (h3 → h2)** и ставит его по умолчанию для
новых endpoint'ов: HTTP/3 получает бюджет в 3 секунды, затем туннель
откатывается на HTTP/2 поверх TCP — победитель запоминается. Именно это
заставляет MASQUE работать за TCP-хопами в цепочках и в сетях, где QUIC/UDP
зарезан.

## 🧰 Ядро и внутренности

- Ядро запинено на **sing-box-lx v1.14.0-lx.28-rc.1**: `type: chain`,
  контракт тегов слоёв закреплён в ядре, предупреждения `masque: tunnel
  died` называют слой-виновник, а `vhttp` по умолчанию — `auto`.
- Debug API: полный CRUD `/chains` с той же валидацией, что в форме,
  `GET /chains/{tag}/probe` для скриптовых послойных проб; `/help` обновлён.
- Загрузка шаблона теперь валидирует тела `#enable` и все секции шаблона —
  опечатка падает громко на загрузке, а не узел молча исчезает.
- Меню экрана «Серверы» перегруппировано: создать / получить готовое /
  импорт / подписки.

## 🧪 Тесты

`flutter analyze`, **3 968 тестов** и все шесть чекеров проходят. Общий
контрактный корпус зелёный с обеих сторон на 0.7.1. Проверено вживую на
эмуляторе: сквозной трафик цепочки через три хопа, круговой перенос бэкапа
между приложениями, послойные пробы на работающем ядре.

</details>

---

## Install / Установка

```bash
adb install -r LxBox-v2.21.0-arm64-v8a.apk
```

Без uninstall! Поверх существующей установки. Настройки и подписки сохранятся.

No uninstall needed — install over the existing one. Settings and
subscriptions are preserved.

---

Previous release / Предыдущий релиз: [v2.20.12](docs/releases/v2.20.12.md).
