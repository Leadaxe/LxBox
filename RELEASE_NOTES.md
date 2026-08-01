# L×Box v2.19.0

Subscriptions that pack a whole pool into a single entry now arrive as a
single node instead of a dozen look-alike rows — and you can build your own
such node inside a folder. Plus Xray subscriptions stopped losing everything
that isn't VLESS.

Подписки, упаковывающие целый пул в один пункт, теперь приезжают одним узлом,
а не десятком похожих строк — и такой узел можно собрать самому внутри папки.
Плюс Xray-подписки перестали терять всё, что не VLESS.

Core / Ядро: **sing-box-lx `v1.14.0-lx.17-rc.4`** — two self-healing fixes,
see the Core section / два самолечащихся фикса, см. секцию «Ядро».

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

### 🧹 Duplicate servers are folded together

The same server listed under several entries becomes one node. The key is
protocol + address + port + credentials, so a provider renaming it doesn't
create a twin. On Liberty 64 records fold into 43 nodes.

## 🐛 Fixed

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

### 🔌 A stuck "Stopping" no longer leaves the port occupied

After the tunnel hung on stopping and the app force-stopped it, the local
control port stayed taken for another 8–15 seconds — long after the screen
already said "disconnected". Another program couldn't open it, and starting
the VPN again in that window failed; a second stop-start fixed it.

The teardown released the port only **after** shutting the core down, and on
configs with many WireGuard nodes that shutdown takes 10–17 seconds. The
force-stop path gives up waiting after 2 — so the release never happened. Now
the port is freed first and the core shuts down after it, at its own pace.

## ⚙️ Changed

### 🔄 Subscriptions decide what happens after an auto-update

A new **"On update"** setting per subscription: *Rebuild config* (the old
behaviour — you apply it), *Rebuild and reload core* (applied at once, the
connection drops for a few seconds) or *Do nothing* (nodes refresh in the list
only). Manual ⟳ still leaves the decision to you.

## 🧬 Core — sing-box-lx `v1.14.0-lx.17-rc.4`

### 🌐 "Browser dead, YouTube alive" is fixed — new TCP connections can no longer die forever

A rare floating race (it had been haunting us since spring as §047): something
in the shared Android process could close a file descriptor right out from
under the core's internal TCP forwarder. The forwarder's accept loop treated
that as fatal and silently gave up — from that moment **every new TCP
connection got an instant "connection refused"**, while UDP, QUIC and DNS kept
working. That's exactly the "YouTube and Instagram work, but the browser won't
open anything" state, curable only by restarting the VPN. Reproduced roughly
once per 8–36 fast VPN restarts.

The core now notices the death, logs the errno (which names the killer path —
the hunt for the trigger continues with fdsan instrumentation on the app
side), recreates the listener on the same address within milliseconds and
keeps serving. A deliberate shutdown stays silent; a recovery counter is kept
as telemetry.

### 📡 WG/AWG nodes heal themselves after device sleep

While the phone sleeps, the tunnel's UDP path state dies (the NAT mapping
expires, a DPI flow entry goes stale). Upstream WireGuard would retry
handshakes into the same dead socket forever — the node sat in ERR until you
reconnected manually. Now, when a full handshake cycle gives up, the core
recreates the socket binding once — with a fresh source port when
`listen_port` isn't pinned — and retries immediately. Zero cost when healthy,
asleep or closed.

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

### 🧹 Дубли серверов схлопываются

Один сервер, перечисленный в нескольких пунктах, становится одним узлом. Ключ
— протокол + адрес + порт + учётные данные, поэтому переименование у
провайдера не плодит близнеца. На Liberty 64 записи сворачиваются в 43 узла.

## 🐛 Исправлено

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

### 🔌 Зависшая остановка больше не оставляет порт занятым

После того как туннель завис на остановке и приложение прибило его принудительно,
локальный управляющий порт оставался занят ещё 8–15 секунд — уже после того, как
на экране написано «отключено». Другая программа его открыть не могла, а запуск
VPN в этом окне падал; помогал повторный старт-стоп.

Порт освобождался только **после** выключения ядра, а на конфигах с большим
числом WireGuard-узлов это выключение занимает 10–17 секунд. Принудительная
остановка ждёт его 2 секунды — до освобождения дело не доходило вовсе. Теперь
порт отдаётся первым, а ядро выключается после него, в своём темпе.

## ⚙️ Изменено

### 🔄 Подписка решает, что делать после автообновления

Новая настройка **«При обновлении»** у каждой подписки: *Пересобрать конфиг*
(как было — применяете вы), *Пересобрать и перезагрузить ядро* (применяется
сразу, соединение обрывается на несколько секунд) или *Ничего не делать*
(узлы обновляются только в списке). Ручное ⟳ по-прежнему оставляет решение
за вами.

## 🧬 Ядро — sing-box-lx `v1.14.0-lx.17-rc.4`

### 🌐 «Браузер мёртв, YouTube жив» исправлен — новые TCP-соединения больше не умирают навсегда

Редкая плавающая гонка (преследовала нас с весны как §047): кто-то в общем
Android-процессе мог закрыть файловый дескриптор прямо из-под внутреннего
TCP-форвардера ядра. Его accept-петля считала это фатальным и молча
сдавалась — с этого момента **каждое новое TCP-соединение получало мгновенный
«connection refused»**, при живых UDP, QUIC и DNS. Это ровно то состояние
«YouTube и Instagram работают, а браузер ничего не открывает», лечившееся
только рестартом VPN. Воспроизводилось примерно раз на 8–36 быстрых
рестартов VPN.

Теперь ядро замечает смерть петли, пишет в лог errno (он называет путь
убийства — охота на сам триггер продолжается fdsan-инструментировкой на
стороне приложения), за миллисекунды пересоздаёт listener на том же адресе
и продолжает работать. Штатная остановка остаётся тихой; счётчик
восстановлений сохраняется как телеметрия.

### 📡 WG/AWG-узлы сами лечатся после сна устройства

Пока телефон спит, состояние UDP-пути туннеля умирает (истекает NAT-маппинг,
протухает запись DPI). Апстримный WireGuard вечно ретраил рукопожатия в тот
же мёртвый сокет — узел висел в ERR до ручного реконнекта. Теперь по провалу
полного цикла рукопожатий ядро один раз пересоздаёт сокет — со свежим
исходящим портом, если `listen_port` не пинован, — и сразу повторяет
рукопожатие. В здоровом, спящем и закрытом состоянии цена нулевая.

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
