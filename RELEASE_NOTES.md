# L×Box v2.19.0

Subscriptions that pack a whole pool into a single entry now arrive as a
single node instead of a dozen look-alike rows — and you can build your own
such node inside a folder. Subscription rules learned to switch nodes back
**on**, not only off. Xray subscriptions stopped losing everything that
isn't VLESS. And the config editor stopped choking — and crashing — on
1000-node configs.

Подписки, упаковывающие целый пул в один пункт, теперь приезжают одним узлом,
а не десятком похожих строк — и такой узел можно собрать самому внутри папки.
Правила подписок научились **включать** узлы обратно, а не только выключать.
Xray-подписки перестали терять всё, что не VLESS. А редактор конфига
перестал давиться — и падать — на конфигах в тысячу узлов.

Core / Ядро: **sing-box-lx `v1.14.0-lx.17-rc.5`**.

---

<details open>
<summary><h2>🇬🇧 English</h2></summary>

## ✨ Added

### 🎯 Auto-select node: a pool as one row

Providers often pack a whole pool into a single subscription entry. Liberty's
"🇪🇺 Авто | Лучший сервер ⚡⚡" holds **15 servers** and picks between them
itself — but the client only saw the servers, so the entry unfolded into 15
near-identical rows and the selection logic was lost.

Now such an entry becomes **one node** with a `urltest` inside. The row shows
what it actually does:

```
🇪🇺 Авто | Лучший сервер ⚡⚡
🔀 [15/7] 🇩🇪, 🇳🇱[2], 🇫🇮
```

- `🔀` — load balance, `🎯` — single fastest server;
- `[15/7]` — 15 servers in the pool, 7 kept in rotation;
- flags — the members the **core is actually using right now**, asked from it
  directly, not read off the config. Repeats are collapsed with a count.

The badge is a regex you can change (it defaults to "first flag emoji in the
name"), or turn off entirely.

### 📁 Build your own inside a folder

Folder menu → **"Add auto node…"**. Three ways to fill the pool:

| mode | what it does |
|---|---|
| **All** | every server in the folder |
| **Rule** | include/exclude regex, with a live "12 of 37" preview |
| **Pick** | check the members by hand |

Under **Advanced**: test URL, interval, idle timeout, switch tolerance, pool
size, session stickiness, and whether switching should cut live connections.

### 🔌 Xray subscriptions: every protocol, not just VLESS

An entry containing trojan, vmess, shadowsocks or hysteria2 was dropped
whole — silently. Liberty lost three paid GAMING servers this way.

### ✅ Subscription rules can now enable nodes, not just disable them

A rule could only ever switch nodes off. Change the criterion — the filter said
"FI", now it says "NL" — and the old marks stayed: FI and NL both ended up off,
with nothing to switch them back on.

Rules now have a third action, **Enable**, which clears the disable mark —
including one you set by hand. Rules run in order and the last one to match
wins, so two idioms fall out of it:

| first rule | then | result |
|---|---|---|
| Enable everything | Disable "FI" | old marks reset, only FI off |
| Disable everything | Enable "NL" | allow-list: only NL stays on |

"Everything" is a condition with an empty path, `matches`, `.*`.

The Nodes tab also gained an **Enable all / Disable all** button — a way out of
any accumulated state without touching the rules at all.

### 🧹 Duplicate servers are folded together

The same server listed under several entries becomes one node. The key is
protocol + address + port + credentials, so a provider renaming it doesn't
create a twin. On Liberty 64 records fold into 43 nodes.

## 🐛 Fixed

### 🗒️ The config editor survives huge configs

With ~1000 nodes the editor burned 100% CPU on every keystroke, and
eventually the system killed the app — leaving an empty crash report. The
whole config lived in one text field: each keystroke re-laid-out hundreds of
kilobytes and synced all of them to the keyboard app. The editor is now
line-based: only visible lines get laid out, only the line under the cursor
talks to the keyboard — and it gained line numbers along the way. JSON
parsing and formatting moved off the UI thread, so opening the screen,
saving, and subscription refreshes no longer stutter. Configs over 1 MB open
read-only with a hint: Share → edit externally → Load from file.

The same line-based scheme now renders the subscription **Source** tab and
the crash/OOM report viewers — a multi-hundred-KB body is no longer glued
into a single text block — and reports got a **Copy** button. The paste
fields in the add-server wizard switched over too.

Two bonus fixes while there: a JSON5 syntax error on Save now shows up with
its line and column (it used to disappear silently), and loading a file with
non-Latin characters in comments no longer garbles them.

### 📶 Ping testing no longer wipes the other channels

Latency was kept in one map shared by the whole app, while a mass test only
walks the nodes of the **selected** channel — so it cleared everything and
refilled its own part. Test one channel, and the rest went blank; do it after
every switch, forever.

Each channel now keeps **its own** measurements and never touches anyone
else's. This isn't only about the wipe: the test URL and timeout are set per
channel, so "180 ms" from two different probes are two different quantities
and don't belong in one place.

If a node has no measurement in the current channel, the last one from
another channel is shown — marked `~` ("approximately") and dimmed, so it
reads as what it is: a figure from a different probe.

```
120MS     measured here
~120MS    carried over from another channel
```

The list never goes blank after a switch, and no foreign reading is passed
off as your own. Sorting by latency uses the same number you see in the row.

### 🏷️ An entry's name no longer goes to a random server

`remarks` belongs to exactly one thing: the auto-select node if the entry has
one, otherwise the single server. When there are several servers, each gets
the provider's tag appended.

Before, the first server took the bare name — and fought the auto-select node
for it. The list showed **two "Лучший сервер" rows**: the real group, and an
ordinary server wearing its name.

### 🔔 The "restart to apply" banner stopped crying wolf

It was set whenever the config changed while the tunnel was up, and it was
sticky: a rebuild producing a config identical to the running one didn't clear
it. An hourly subscription returning the same list showed the banner every
hour for nothing. A successful "Reload core" now clears it too.

Refreshing a subscription no longer raises it either. Any settings write used
to set the flag, and a refresh always writes something — at minimum the time of
the last attempt. So the banner appeared both when a subscription returned the
very same list and when the refresh failed outright (provider down, airplane
mode) — every hour, over a config nobody had touched. Now the node composition
is compared instead, and bookkeeping writes don't touch the flag at all. Real
unsaved changes are kept, including ones made during the refresh itself.

The banner also stopped guessing. Comparing two *saved* configs answers "did
the file change", while the banner claims "the running core is out of date" —
and there were plenty of false reasons for the first: the provider reordering
nodes, suffixes of same-named entries shifting, and with mixed-case SNI enabled
every rebuild produced different text, so the banner never cleared at all. The
app now asks the core: the saved and the running config are reduced to one
canonical form **inside the core** — same parser, same serializer — and those
are compared. Differences in field order and other formatting stop counting as
a change. The verdict can only remove a needless banner, never raise one; if
the core can't answer, the banner stays, as before.

A subscription whose composition really did change still gets you the banner —
and with "On update" set to reload, it applies straight away.

### 📁 Test results in a folder no longer shift when a server is deleted

Measurements inside a folder were tied to the row number rather than the
server. As long as the list stayed put everything lined up; delete one server
from the middle and every value below it moved up a row, showing figures that
belonged to someone else. It showed most after testing a large folder from the
WARP generator, where dead nodes get deleted one at a time — reordering
(dragging, sorting by latency) accounted for the shift, deleting didn't.

The measurement now belongs to the server itself: delete, drag and sort in any
order, the numbers stay with their rows. Editing a server (port, address, keys)
clears its measurement — that's a different server now. Two identical servers
in one folder are counted independently.

### 🛑 A stuck stop no longer leaves the port occupied

When the tunnel hung on shutdown the app force-kills it — and after that the
local control port stayed busy for another 8–15 seconds, well after the screen
said "disconnected". Nothing else could open it, starting the VPN in that
window failed, and a second start-stop was the cure.

It was an ordering problem: the port was only released **after** the core shut
down, and on configs with many WireGuard nodes that shutdown takes 10–17
seconds. The force-stop waits 2 seconds and moves on — so releasing the port
never happened at all. The port is now handed back first and the core shuts
down after it, at its own pace.

### 🏠 With zero servers, the home screen points to Servers again

The "Add a server" guide only showed while no config file existed. But a config
gets created without a single server: a subscription returning an empty list,
Apply in settings, or deleting all servers is enough — after which the guide
was gone for good, the screen looked functional, and the VPN would even start
with nothing to connect through.

The guide is now tied to what actually matters: no servers means a full-screen
guide with a link to Servers and restore-from-backup, and no Start button. Add
one server — including by importing a ready config — and the screen goes back
to normal. States with the VPN running are untouched; they have their own
messages.

## ⚙️ Changed

### 🔄 Subscriptions decide what happens after an update

A new **"On update"** setting per subscription: *Rebuild config* (the old
behaviour — you apply it), *Rebuild and reload core* (applied at once, the
connection drops for a few seconds) or *Do nothing* (nodes refresh in the list
only).

The setting is called "On update", not "On auto-update" — and now it behaves
that way: manual ⟳ obeys it too. It used to fire only on the timer, so
"Rebuild and reload" did nothing at all when you pressed the button yourself.

Either way the reaction only fires if the node list really changed. Pressing ⟳
on an unchanged subscription doesn't cost you a few seconds of connection, and
neither does the hourly timer on a provider that keeps returning the same list.
Several subscriptions refreshing in one pass share a single reload rather than
taking one each.

## 🧩 Core

Kernel bumped to **`v1.14.0-lx.17-rc.5`**, which brings two self-healing fixes
plus an upstream sync: a DNS race where a finished rule was held up by an
earlier pending one, a WireGuard interface DNS fix, and a naiveproxy update.

### 💤 WireGuard endpoints recover on their own after the phone sleeps

While the phone sleeps, the tunnel's UDP flow dies on the path — the NAT
mapping expires, or a DPI flow entry goes stale. The upstream implementation
then retried handshakes into that same dead socket forever: same source port,
same dead flow, no replies. Reconnecting "fixed" it only because it opened a
new socket with a fresh port.

The core now does that itself: when a peer's handshake retries run out
(~90 seconds of silence, and only under actual traffic demand), it reopens the
socket on a fresh port and starts a new handshake. Masquerade profiles send
their decoy along with it, re-opening the flow on the DPI. If you pinned
`listen_port` yourself it is preserved, and self-healing by port change is then
unavailable by design. Costs nothing while healthy or asleep — no timers, no
traffic — so it doesn't fight idle-suspend.

### 🔌 System stack: TCP no longer dies until a restart

With the system TCP stack every new connection out of the tunnel is routed
through a local forwarder. Its accept loop treated **any** error as terminal
and quietly gave up — so if something else in the shared Android process closed
that socket, the stack kept routing every new connection to a dead port. The
system answered each with an instant refusal: every app got "connection
refused" in about 16 ms until the VPN was restarted, while UDP, QUIC and DNS
went on working. On a device it reproduced about once in 8–36 rapid VPN
restarts, which is why it stayed uncaught for months.

The loop now logs the error with the system code that names the culprit,
recreates the listener on the same address, republishes the port atomically and
keeps serving. A deliberate shutdown stays silent as before.

</details>

<details>
<summary><h2>🇷🇺 Русский</h2></summary>

## ✨ Добавлено

### 🎯 Узел автовыбора: пул одной строкой

Провайдеры часто упаковывают целый пул в один пункт подписки. У Liberty
«🇪🇺 Авто | Лучший сервер ⚡⚡» держит **15 серверов** и сам выбирает между
ними — но клиент видел только серверы, поэтому пункт разворачивался в 15
почти одинаковых строк, а логика выбора терялась.

Теперь такой пункт становится **одним узлом**, внутри которого `urltest`.
В строке видно, что он на самом деле делает:

```
🇪🇺 Авто | Лучший сервер ⚡⚡
🔀 [15/7] 🇩🇪, 🇳🇱[2], 🇫🇮
```

- `🔀` — раскладка по пулу, `🎯` — один быстрейший;
- `[15/7]` — 15 серверов в пуле, 7 держатся в работе;
- флаги — те участники, которых **ядро использует прямо сейчас**: спрошены у
  него напрямую, а не вычитаны из конфига. Повторы схлопываются с числом.

Значок задаётся regex'ом, который можно переписать (по умолчанию — «первый
флаг-эмодзи в имени») или убрать совсем.

### 📁 Собрать свой внутри папки

Меню папки → **«Add auto node…»**. Три способа набрать пул:

| режим | что делает |
|---|---|
| **Все** | все серверы папки |
| **Правило** | include/exclude regex с живым превью «12 of 37» |
| **Выбор** | отметить участников галочками |

В разделе **Advanced**: URL проверки, интервал, время простоя, порог
переключения, размер пула, липкость сессии и рвать ли живые соединения при
смене узла.

### 🔌 Xray-подписки: все протоколы, а не только VLESS

Пункт с trojan, vmess, shadowsocks или hysteria2 отбрасывался целиком — и
молча. У Liberty так терялись три платных GAMING-сервера.

### ✅ Правила подписки научились включать узлы, а не только выключать

Правило умело одно — выключать. Сменил критерий (был фильтр «FI», стал «NL») —
старые отметки остались: выключенными оказывались и FI, и NL, а включить
обратно было нечем.

Теперь у правила есть третье действие — **Enable**: оно снимает отметку
выключения, в том числе поставленную вручную. Правила применяются по порядку,
последнее сработавшее побеждает, отсюда две связки:

| первое правило | дальше | что выйдет |
|---|---|---|
| Включить всё | Выключить «FI» | старые отметки сброшены, выключены только FI |
| Выключить всё | Включить «NL» | белый список: включены только NL |

«Всё» — это условие с пустым путём, `matches`, `.*`.

На вкладке Nodes появилась кнопка **«Включить все / Выключить все»** — выход из
любого накопившегося состояния, не трогая правила вовсе.

### 🧹 Дубли серверов схлопываются

Один сервер, перечисленный в нескольких пунктах, становится одним узлом. Ключ
— протокол + адрес + порт + учётные данные, поэтому переименование у
провайдера не плодит близнеца. На Liberty 64 записи сворачиваются в 43 узла.

## 🐛 Исправлено

### 🗒️ Редактор конфига переваривает огромные конфиги

При ~1000 узлов редактор съедал 100% CPU на каждое нажатие клавиши, а затем
система убивала приложение — с пустым краш-репортом. Весь конфиг лежал в
одном текстовом поле: каждое нажатие заново размечало сотни килобайт и
целиком синхронизировало их с клавиатурой. Теперь редактор построчный:
размечаются только видимые строки, с клавиатурой общается только строка под
курсором — заодно появились номера строк. Разбор и форматирование JSON ушли
с UI-потока: открытие экрана, сохранение и обновления подписок больше не
подтормаживают. Конфиги больше 1 МБ открываются только для чтения с
подсказкой: Поделиться → править во внешнем редакторе → Загрузить из файла.

Та же построчная схема теперь рисует вкладку **Source** у подписки и
просмотр краш/OOM-репортов — тело на сотни килобайт больше не склеивается в
один текстовый блок, а у репортов появилась кнопка **Копировать**. Поля
вставки в мастере добавления сервера тоже переехали.

Два фикса по пути: синтаксическая ошибка JSON5 при сохранении теперь
показывается со строкой и колонкой (раньше молча исчезала), а загрузка
файла с кириллицей в комментариях больше не превращает её в кракозябры.

### 📶 Тест пинга больше не стирает результаты остальных каналов

Задержки хранились одной картой на всё приложение, а массовый тест перебирает
узлы только **выбранного** канала — то есть чистил всё, а заполнял свою часть.
Пропинговал один канал — в остальных пусто, и так после каждого переключения.

Теперь каждый канал ведёт **свои** замеры и чужих не касается. Дело не только
в очистке: адрес и таймаут проверки задаются отдельно для каждого канала,
поэтому «180 мс» от разных проверок — разные величины, и лежать в одном месте
они не должны.

Если в текущем канале узел ещё не проверяли, показывается последний замер из
другого — со значком `~` («приблизительно») и приглушённым цветом, чтобы было
видно, что это такое: число от другой проверки.

```
120MS     измерено здесь
~120MS    перенесено из другого канала
```

Список не пустеет после переключения, и чужой замер не выдаётся за свой.
Сортировка по задержке считает по тому же числу, что видно в строке.

### 🏷️ Имя пункта больше не достаётся случайному серверу

`remarks` принадлежит ровно одной сущности: узлу автовыбора, если он в пункте
есть, иначе — единственному серверу. Когда серверов несколько, к каждому
имени добавляется тег провайдера.

Раньше чистое имя брал первый сервер — и дрался за него с узлом автовыбора.
В списке появлялись **два «Лучших сервера»**: настоящая группа и обычный
сервер, носящий её имя.

### 🔔 Плашка «перезапустите VPN» перестала кричать без повода

Она ставилась по факту «конфиг изменился при живом туннеле» и была sticky:
пересборка, давшая конфиг, идентичный работающему, прежнюю плашку не гасила.
Подписка с интервалом в час, отдающая один и тот же список, показывала её
каждый час без причины. Успешный «Reload core» теперь тоже её снимает.

Обновление подписки её тоже больше не поднимает. Флаг вставал на любую запись
настроек, а обновление пишет их всегда — хотя бы отметку времени последней
попытки. Поэтому плашка вылезала и когда подписка вернула ровно тот же список,
и когда обновление вообще не удалось (провайдер недоступен, авиарежим) — раз в
час, на конфиге, который никто не трогал. Теперь сравнивается состав узлов, а
служебные записи флаг не трогают вовсе. Настоящие несохранённые изменения
сохраняются, в том числе сделанные прямо во время обновления.

И она перестала гадать. Сравнение двух **сохранённых** конфигов отвечает на
вопрос «изменился ли файл», тогда как плашка утверждает «работающее ядро
устарело» — а ложных поводов для первого хватало: провайдер переставил узлы,
сместились суффиксы одинаковых имён, а при включённой маскировке SNI каждая
пересборка вообще давала другой текст, и плашка не гасла никогда. Теперь
приложение спрашивает ядро: сохранённый и работающий конфиги приводятся к одной
канонической форме **внутри ядра** — один парсер, один сериализатор, — и
сравниваются уже они. Различия в порядке полей и прочем оформлении перестают
считаться изменением. Вердикт умеет только убрать лишнюю плашку, показать её он
не может; если ядро ответить не смогло, плашка остаётся, как и прежде.

Подписка, у которой состав действительно изменился, плашку по-прежнему даёт — а
с настройкой «При обновлении» в режиме перезагрузки применяет сразу.

### 📁 В папке результаты теста больше не съезжают при удалении сервера

Замеры внутри папки привязывались к номеру строки, а не к самому серверу. Пока
список не менялся, всё сходилось; стоило удалить один сервер из середины — и
все значения ниже поднимались на строку вверх, показывая чужие числа. Заметнее
всего это было после теста большой папки от генератора WARP, где мёртвые узлы
удаляют по одному: перестановки (перетаскивание, сортировка по задержке) сдвиг
учитывали, а удаление — нет.

Теперь замер привязан к самому серверу: удаляйте, перетаскивайте и сортируйте
в любом порядке — числа остаются при своих строках. Правка сервера (порт,
адрес, ключи) сбрасывает его замер: это уже другой сервер. Два одинаковых
сервера в одной папке считаются независимо.

### 🛑 После зависшей остановки порт больше не остаётся занятым

Когда туннель завис на остановке, приложение прибивает его принудительно — и
после этого локальный управляющий порт оставался занят ещё 8–15 секунд, уже
когда на экране написано «отключено». Другая программа его открыть не могла,
запуск VPN в этом окне падал, помогал повторный старт-стоп.

Дело в порядке действий: порт освобождался только **после** выключения ядра, а
на конфигах с большим числом WireGuard-узлов оно занимает 10–17 секунд.
Принудительная остановка ждёт 2 секунды и идёт дальше — то есть до
освобождения порта дело не доходило вовсе. Теперь порт отдаётся первым, ядро
выключается после него и в своём темпе.

### 🏠 При нуле серверов главный экран снова зовёт в Servers

Подсказка «Add a server» показывалась, только пока не существует файл конфига.
Но конфиг создаётся и без единого сервера: достаточно подписки, отдавшей
пустой список, нажатия Apply в настройках или удаления всех серверов — после
этого подсказка пропадала навсегда, экран выглядел рабочим, и VPN даже
запускался, хотя подключаться не через что.

Теперь подсказка привязана к сути: серверов нет — полноэкранный гайд со
ссылкой в Servers и восстановлением из бэкапа, кнопка Start не рисуется.
Появился хотя бы один сервер (в том числе импортом готового конфига) — экран
возвращается к обычному виду. Состояния при работающем VPN не тронуты: у них
свои сообщения.

## ⚙️ Изменено

### 🔄 Подписка решает, что делать после обновления

Новая настройка **«При обновлении»** у каждой подписки: *Пересобрать конфиг*
(как было — применяете вы), *Пересобрать и перезагрузить ядро* (применяется
сразу, соединение обрывается на несколько секунд) или *Ничего не делать*
(узлы обновляются только в списке).

Настройка называется «При обновлении», а не «При автообновлении» — теперь так
и работает: ручное ⟳ ей тоже подчиняется. Раньше она срабатывала только по
таймеру, и режим «Пересобрать и перезагрузить» на нажатие кнопки не делал
ничего.

В любом случае реакция срабатывает, только если состав узлов действительно
изменился. Жать ⟳ на неизменившейся подписке больше не значит потерять
несколько секунд соединения — как и часовой таймер на провайдере, который
отдаёт один и тот же список. Несколько подписок, обновившихся за один проход,
делят одну перезагрузку, а не берут по своей.

## 🧩 Ядро

Ядро обновлено до **`v1.14.0-lx.17-rc.5`** — два самолечащихся фикса плюс
синхронизация с апстримом: гонка в DNS (готовый ответ ждал зависший),
исправление DNS у WireGuard-интерфейса и обновление naiveproxy.

### 💤 WireGuard-узлы сами восстанавливаются после сна телефона

Пока телефон спит, UDP-поток туннеля умирает по дороге: истекает NAT-запись
или протухает запись потока у DPI. Дальше реализация бесконечно повторяла
рукопожатия в тот же мёртвый сокет — тот же исходящий порт, тот же мёртвый
поток, ноль ответов. Переподключение «чинило» это ровно потому, что открывало
новый сокет со свежим портом.

Теперь ядро делает это само: когда попытки рукопожатия у пира заканчиваются
(~90 секунд молчания, и только если есть что передавать), сокет открывается
заново на свежем порту и рукопожатие начинается сразу. Профили с маскировкой
отправляют вместе с ним свой decoy, заново открывая поток на DPI. Если
`listen_port` задан вручную, он сохраняется — самолечение сменой порта тогда
недоступно, так задумано. В исправном состоянии и во сне не стоит ничего: ни
таймеров, ни трафика, поэтому с idle-suspend оно не конфликтует.

### 🔌 Системный стек: TCP больше не умирает до перезапуска

При системном TCP-стеке каждое новое соединение из туннеля идёт через
локальный форвардер. Его цикл приёма считал **любую** ошибку фатальной и тихо
завершался — и если что-то ещё в общем процессе Android закрывало этот сокет,
стек продолжал работать и отправлять каждое новое соединение на мёртвый порт.
Система мгновенно отвечала отказом: любое приложение получало «connection
refused» примерно за 16 мс, пока VPN не перезапустят, — при этом UDP, QUIC и
DNS работали. На устройстве воспроизводилось примерно раз на 8–36 быстрых
перезапусков VPN, поэтому месяцами оставалось незамеченным.

Теперь цикл пишет в лог ошибку с системным кодом, который называет виновника,
пересоздаёт слушателя на том же адресе, атомарно переопубликовывает порт и
продолжает работать. Намеренное выключение по-прежнему проходит молча.

</details>

---

## ⚠️ Note / Оговорка

All four Xray balancer strategies are handled (`random`, `roundRobin`,
`leastPing`, `leastLoad`), and malformed fields no longer break anything: a
shape we can't read means no auto-select node for that entry, while its
servers arrive as usual. Only Liberty was verified on a device, though — if
another provider's pool behaves oddly, the report is worth sending.

Обработаны все четыре стратегии балансировщика Xray (`random`, `roundRobin`,
`leastPing`, `leastLoad`), а битые поля больше ничего не ломают: непонятная
форма означает, что у пункта не будет узла автовыбора, а его серверы приедут
как обычно. На устройстве проверена только Liberty — если у другого
провайдера пул поведёт себя странно, сообщение будет кстати.
