# L×Box v2.19.2

Hysteria2, TUIC and MASQUE-h3 are alive again on the devices where they were
silently dead. A single broken node from a subscription no longer stops the
whole VPN from starting. Xray subscriptions keep the order their author
intended. Settings changes can now apply themselves to a live tunnel, leaving
no banners behind. Subscriptions got their own Test servers button, and
disabled ones can now be kept fresh instead of going stale.

Hysteria2, TUIC и MASQUE-h3 снова работают на устройствах, где были молча
мертвы. Одна битая нода из подписки больше не мешает запуску всего VPN.
Xray-подписки сохраняют порядок, задуманный автором. Изменения настроек умеют
применяться к живому туннелю сами, не оставляя плашек. У подписок появилась
своя кнопка Test servers, а выключенные больше не обязаны протухать.

Core / Ядро: **sing-box-lx `v1.14.0-lx.19-rc.3`** (было `v1.14.0-lx.18`).

---

<details open>
<summary><h2>🇬🇧 English</h2></summary>

## 🆕 What's new

### 🧪 Test servers on the subscription screen

The test button, already familiar from folders, is now on the subscription's
Nodes tab: a summary bar with `N ok · N err`, latency badges on the rows
coloured by threshold, and a tap on a failure showing its text. Disabled nodes
are tested too — the test answers "is the server alive", not "is it in the
config" — and auto-select nodes get a neutral "auto" badge instead of an
error. Works for single servers as well. As before, the test needs the VPN
switched off; with an active tunnel it offers to stop it.

### ♻️ "Auto-restart VPN on settings change"

Settings → General → Behavior: a checkbox that makes the app apply any config
change to the live tunnel by itself — and then no banners are left at all,
neither the blue "Settings changed" nor the pink "Config changed — restart
VPN".

A subscription update could already do this on its own, but the config is also
changed from 25+ other places — editing a node, a detour, DNS, routing,
per-app, the settings toggles — and there a banner was the only way forward.
The restart only fires when there is something to apply, and only from a
single place where every rebuild path converges, so a burst of edits doesn't
turn into a burst of restarts. Off by default.

### 🔄 "Update disabled subscriptions"

Settings → Subscriptions: a checkbox that lifts the ban on auto-updating
disabled subscriptions. A disabled subscription used to never update at all,
so its node list went stale — you enable it a month later and get dead
addresses. Now the snapshot can be kept fresh, while the nodes of a disabled
subscription still don't reach the config and its update doesn't restart the
tunnel. Off by default; it overrides neither the subscription's own "don't
update automatically", nor the min-retry interval, nor the freeze after five
failures.

## 🔧 Changed

### ⏰ WARP nodes recover right after you unlock the screen

Reported on 4PDA again: "WARPs go stale over time". After the device sleeps,
the network state of every WG/AWG node dies. The core heals this on its own,
but ping measurements taken 5–35 seconds after unlocking still showed errors.

Unlocking the screen now serves as a "the device woke up" signal: the core
walks the nodes and re-establishes only the provably dead sessions, leaving
live ones alone — the error window should shrink to a single handshake. If
WARP still errors out right after unlocking, a report is worth sending: this
one is hard to reproduce on demand, and field measurements help.

### 🧭 Node details tell a pool apart from a single fastest server

An auto-select node comes in two flavours that behave in opposite ways: pick
the one fastest server, or spread the traffic across a pool of several. The
details screen showed both as a plain `urltest` and drew a single "current
pick" — which for a pool does not exist at all, so the row came out empty.

Now the screen states the mode (Fastest / Load balance), the pool size and its
tolerance, and `Members` opens into the actual list — with a tick and a latency
next to the ones the core is really using right now. In the route, a pool is a
single hop that unfolds into its slots, and it sits where the packet actually
meets it: phone → group → pool → internet.

### 🔗 "Share URL" without the intermediate dialog

Long-press a subscription → "Share URL…" now opens the system share sheet
straight away with the full URL. There used to be a dialog offering "masked /
full" first, which read as a pointless message — and the masked variant
(`https://host/***`) was useless to the recipient anyway. For a subscription
loaded from a local file the item is hidden: a file subscription has no URL to
share.

## 🐛 Fixed

### 📌 The blue "Settings changed" banner could stick around with an up-to-date config

A bug older than this release: the DNS/routing/per-app/vpn-mode screens write
settings lazily, and a "safety-net" re-write on screen close re-raised the
change flag after a fast rebuild on return-to-home had already cleared it. It
raced the screen exit animation (~300ms) — hence "sometimes": a slow rebuild
would luckily wipe the re-raise. As a side effect the flag also came back
after an app restart (the settings file ended up written later than the
config). The extra banner used to be silently tapped away; the new
"auto-restart" checkbox, promising no banners at all, exposed it. The
post-rebuild snackbar also stopped asking to "restart VPN" when the rebuilt
config is identical to the running one and there is nothing to apply.

### 🎯 An auto-select node blocked Test servers for a folder or subscription

Reported on 4PDA (#1406/#1407): after adding an "auto server" the ping test
failed with an error on every attempt, without checking a single node, and
disabling that node didn't help — only deleting it or moving it out of the
folder did. The reason: the group travelled into the probe config as a
placeholder with an empty member list (the pool is filled in by the main
builder only), and the core rejected the whole config (`missing tags`). Group
nodes are no longer emitted into the probe at all: a group needs no
measurement of its own — its members sit in the same folder and are tested
one by one — and the row gets a neutral "auto" badge instead of an error.
"Disable unreachable" leaves such a node alone, and sorting by ping keeps it
with the untested ones rather than the failed ones.

### 🚀 Hysteria2, TUIC and MASQUE-h3 dead on some devices

Reported on 4PDA: "hysteria2 doesn't work in 2.19.0" — while the same server
was alive in other clients, on the same phone and the same network. It
reproduced on devices with vendor kernels (repro: OnePlus Nord CE 2, Android
15): every connection over these protocols hung until timeout, and the ping
test showed `-1` forever. TCP protocols, WARP AWG and MASQUE-h2 worked fine,
and emulators never reproduced it — which is why the bug looked environmental
on the reporter's side for a long time.

The cause turned out to be the core's build environment: built with Go 1.24 it
had the defect, the same source with Go 1.25 works. The app and its config
pipeline were clean — the hysteria2 outbound was compared byte for byte, and a
minimal config died just the same. Fixed by changing the core's build
toolchain.

### 🔑 One broken REALITY node stopped the whole VPN from starting

A field crash: startup aborted with `decode short_id: encoding/hex: odd length
hex string` and the tunnel never came up — because of one node out of
hundreds.

The core reads `short_id` as a hex number of fixed length: an odd number of
characters, or more than 16, is rejected — and the whole config goes with it.
The app used to let such values through: it stripped foreign characters but
never checked the length, and silently truncated anything too long, producing
a well-formed but *different* identifier.

Now a broken value is discarded outright — an empty `short_id` is legal in the
protocol, so the node stays usable and the config stays alive. The build
warnings name the node that was broken. The same safety net was added at the
config output, for nodes that arrive bypassing the importer (raw JSON,
subscription rules).

### 🔢 Xray subscriptions arrived shuffled

Measured on a real subscription of 37 entries: all 37 positions shifted. The
node `🇪🇺 🚀Авто | Лучший сервер` travelled from first place to the very end,
and a random country took its place at the top.

The order in a subscription is meaningful — authors put the recommended node
first and group the rest by region — and the "as in subscription" sort mode
was showing the result of our own internal sorting instead. Nodes now arrive
in the author's order, and node names are unchanged: the sorting existed for
the names, not for the order, and those two jobs are now separated.

### 📶 Trojan and VLESS nodes with TLS off broke the ping test

The core failed with an internal error when URL-testing such nodes.

## 🧰 Tools

### 🔬 Debug API `/action/quic-knobs`

A diagnostic knob that toggles quic-go offload mechanics (GSO, ECN) directly
on the device with no rebuild — an A/B check takes two requests instead of
half an hour. It was built to investigate the hysteria2 case above and stays
for future field diagnostics of that class. Development-only; it does not
affect normal operation.

### 🔊 Verbose core logs

A sub-toggle under "Forward sing-box logs": it lifts the TRACE/DEBUG filter
live, with no VPN restart. The filter itself is right — on real traffic a
trace stream is a line per packet — but it used to be unconditional, which
made any device check against the core's debug lines impossible. The default
is unchanged; keep it off unless you are chasing something specific.

</details>

<details open>
<summary><h2>🇷🇺 Русский</h2></summary>

## 🆕 Что нового

### 🧪 Test servers на экране подписки

Кнопка теста, знакомая по папкам, появилась на вкладке Nodes подписки: полоса
со сводкой `N ok · N err`, бейджи задержки у строк с цветом по порогам шкалы,
тап по ошибке показывает её текст. Тестируются и выключенные узлы — тест
отвечает «жив ли сервер», а не «в конфиге ли он», — а узлы автовыбора получают
нейтральный бейдж «auto» вместо ошибки. Работает и для одиночных серверов. Как
и раньше, тест требует выключенного VPN: при активном туннеле предложит его
остановить.

### ♻️ «Автоперезапуск VPN при смене настроек»

Настройки → General → Behavior: галка, после которой приложение само применяет
любое изменение конфига к живому туннелю — и плашек не остаётся вовсе: ни
синей «Settings changed», ни розовой «Config changed — restart VPN».

Обновление подписки так умело и раньше, но конфиг меняют и 25+ других мест:
правка узла, detour, DNS, routing, per-app, тумблеры в настройках — там плашка
оставалась единственным путём. Перезапуск срабатывает только когда есть что
применять, и только в одной точке, где сходятся все пути пересборки, — так
серия правок не превращается в серию перезапусков. Выключено по умолчанию.

### 🔄 «Обновлять выключенные подписки»

Настройки → Подписки: галка, снимающая запрет на авто-обновление выключенных
подписок. Раньше выключенная подписка не обновлялась вовсе, и её список узлов
тух — включаешь через месяц и получаешь мёртвые адреса. Теперь снапшот можно
держать свежим, при этом узлы выключенной подписки в конфиг по-прежнему не
попадают, а туннель из-за её обновления не перезагружается. Выключено по
умолчанию; не отменяет ни «не обновлять автоматически» у самой подписки, ни
min-retry, ни заморозку после пяти фейлов.

## 🔧 Изменено

### ⏰ Узлы WARP оживают сразу после разблокировки экрана

Снова жалоба с 4PDA: «варпы протухают со временем». После сна устройства
сетевое состояние всех WG/AWG-узлов умирает. Ядро лечит это само, но замеры
пинга в первые 5–35 секунд после разблокировки всё равно показывали ошибку.

Теперь разблокировка экрана служит сигналом «устройство проснулось»: ядро
проходит по узлам и переустанавливает только доказуемо мёртвые сессии, живые не
трогает — окно ошибок должно сжаться до одного рукопожатия. Если WARP всё ещё
отдаёт ошибку сразу после разблокировки, сообщение будет кстати: воспроизвести
это по заказу тяжело, полевые замеры помогают.

### 🧭 Детали узла отличают пул от одного быстрейшего сервера

Узел автовыбора бывает двух видов, ведущих себя противоположно: выбрать один
самый быстрый сервер или размазать трафик по пулу из нескольких. Экран деталей
показывал оба одинаково — просто `urltest` — и рисовал единственный «current
pick», которого у пула нет в принципе, отчего строка выходила пустой.

Теперь экран называет режим (Fastest / Load balance), размер пула и его допуск,
а `Members` раскрывается в список участников — с галкой и задержкой у тех, кого
ядро реально держит в работе. В маршруте пул стал одним звеном, которое
разворачивается в слоты, и стоит там, где его встречает пакет: телефон →
группа → пул → интернет.

### 🔗 «Поделиться URL» без промежуточного диалога

Long-press на подписке → «Поделиться URL…» теперь сразу открывает системное
окно шаринга с полным URL. Раньше сначала показывался диалог с выбором
«маскированный / полный», который читался как бессмысленное сообщение, а
маскированный вариант (`https://host/***`) получателю всё равно был бесполезен.
Для подписки из локального файла пункт скрыт — файловой подписке нечем
делиться.

## 🐛 Исправлено

### 📌 Синяя плашка «Настройки изменились» могла залипнуть при актуальном конфиге

Баг старше этого релиза: экраны DNS/routing/per-app/vpn-mode пишут настройки
отложенно, и «страховочная» повторная запись при закрытии экрана переподнимала
флаг изменений уже после того, как быстрая пересборка на возврате его
погасила. Гонка с exit-анимацией экрана (~300мс) — потому «иногда»: медленная
пересборка везуче затирала ре-подъём. Побочный эффект — флаг воскресал и после
перезапуска приложения (файл настроек оказывался записан позже конфига).
Раньше лишнюю плашку молча гасили тапом; новая галка автоперезапуска,
обещающая «плашек не будет вовсе», её высветила. Заодно всплывашка после
пересборки перестала просить «перезапустите VPN», когда пересобранный конфиг
совпал с работающим и применять нечего.

### 🎯 Узел автовыбора блокировал Test servers папки и подписки

Жалобы 4PDA (#1406/#1407): после добавления «автосервера» тест пинга падал с
ошибкой при каждой попытке, не проверив ни одной ноды; выключение узла не
помогало — только удалить или вынести из папки. Причина: в probe-конфиг группа
уезжала заготовкой с пустым списком членов (состав пула дописывает только
боевой билдер), и ядро отвергало весь конфиг (`missing tags`). Теперь
узлы-группы в probe не эмитятся вовсе: свой замер группе не нужен — её члены
лежат в той же папке и тестируются поштучно, — а строка получает нейтральный
бейдж «auto» вместо ошибки. «Disable unreachable» такой узел не трогает,
сортировка по пингу держит его с нетестированными, а не с упавшими.

### 🚀 Hysteria2, TUIC и MASQUE-h3 были мертвы на части устройств

Жалоба на 4PDA: «hysteria2 не работает в 2.19.0» — при том что тот же сервер
жив в других клиентах, на том же телефоне и в той же сети. Воспроизводилось на
устройствах с вендорским ядром (репро: OnePlus Nord CE 2, Android 15): каждое
соединение по этим протоколам висело до таймаута, а тест пинга вечно показывал
`-1`. TCP-протоколы, WARP AWG и MASQUE-h2 работали нормально, а эмуляторы
дефект не воспроизводили — поэтому баг долго выглядел средовым у репортёра.

Причина оказалась в среде сборки ядра: собранное Go 1.24, оно давало этот
дефект; тот же исходник на Go 1.25 — работает. Приложение и его конфиг-пайплайн
были чисты: эмиссия hysteria2-аутбаунда сверена байт в байт, минимальный
конфиг умирал точно так же. Исправлено сменой тулчейна сборки ядра.

### 🔑 Одна битая нода REALITY не давала запустить VPN

Полевой краш: старт обрывался с `decode short_id: encoding/hex: odd length hex
string`, туннель не поднимался вовсе — из-за одной ноды из сотен.

Ядро читает `short_id` как шестнадцатеричное число фиксированной длины:
нечётное количество символов или больше 16 оно отвергает, а вместе с ними — и
весь конфиг. Приложение такие значения пропускало: чистило посторонние символы,
но не проверяло длину, а слишком длинные молча обрезало — получался формально
правильный, но *чужой* идентификатор.

Теперь битое значение отбрасывается целиком — пустой `short_id` протокол
допускает, поэтому нода остаётся рабочей, а конфиг живым. В предупреждениях
сборки видно, какая именно нода была битой. Та же страховка добавлена на выходе
конфига — для узлов, приходящих в обход импорта (сырой JSON, правила подписок).

### 🔢 Xray-подписки приезжали перетасованными

Замер на боевой подписке из 37 пунктов: смещались все 37 позиций. Узел
`🇪🇺 🚀Авто | Лучший сервер` уезжал с первого места в самый конец, а первой
оказывалась случайная страна.

Порядок в подписке осмыслен — автор ставит рекомендуемый узел первым и
группирует остальные по регионам, — а режим сортировки «как в подписке»
показывал вместо него результат нашей внутренней сортировки. Теперь узлы идут
в авторском порядке, имена узлов при этом прежние: сортировка была нужна именно
им, а не порядку, и эти две задачи разведены.

### 📶 Узлы Trojan и VLESS с выключенным TLS роняли тест пинга

Ядро падало с внутренней ошибкой при URL-тесте таких узлов.

## 🧰 Инструменты

### 🔬 Debug API `/action/quic-knobs`

Диагностическая ручка: включает и выключает offload-механики quic-go (GSO,
ECN) прямо на устройстве, без пересборки — A/B-проверка занимает два запроса
вместо получаса. Сделана для расследования истории с hysteria2 выше и остаётся
для будущих полевых диагнозов этого класса. Ручка для разработки, на обычную
работу приложения не влияет.

### 🔊 Подробные логи ядра

Суб-тумблер под «Forward sing-box logs»: снимает фильтр TRACE/DEBUG на лету,
без перезапуска VPN. Сам фильтр правильный — на живом трафике trace-поток это
строка на пакет, — но был невыключаемым, и любая проверка на устройстве по
debug-строкам ядра оказывалась невозможна. Дефолт не изменился; включать стоит
только под конкретную задачу.

</details>

---

## 📲 Install

```bash
adb install -r LxBox-v2.19.2-arm64-v8a.apk
```

Без uninstall! Поверх существующей установки. Настройки и подписки сохранятся.

No uninstall needed — install over the existing one. Settings and
subscriptions are preserved.

---

Previous release / Предыдущий релиз: [v2.19.1](docs/releases/v2.19.1.md).
