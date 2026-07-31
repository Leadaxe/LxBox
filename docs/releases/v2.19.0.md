# L×Box v2.19.0

Subscriptions that pack a whole pool into a single entry now arrive as a
single node instead of a dozen look-alike rows — and you can build your own
such node inside a folder. Plus Xray subscriptions stopped losing everything
that isn't VLESS.

Подписки, упаковывающие целый пул в один пункт, теперь приезжают одним узлом,
а не десятком похожих строк — и такой узел можно собрать самому внутри папки.
Плюс Xray-подписки перестали терять всё, что не VLESS.

Core / Ядро: **sing-box-lx `v1.14.0-lx.17-rc.3`** (unchanged / без изменений).

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

## ⚙️ Changed

### 🔄 Subscriptions decide what happens after an auto-update

A new **"On update"** setting per subscription: *Rebuild config* (the old
behaviour — you apply it), *Rebuild and reload core* (applied at once, the
connection drops for a few seconds) or *Do nothing* (nodes refresh in the list
only). Manual ⟳ still leaves the decision to you.

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

## ⚙️ Изменено

### 🔄 Подписка решает, что делать после автообновления

Новая настройка **«При обновлении»** у каждой подписки: *Пересобрать конфиг*
(как было — применяете вы), *Пересобрать и перезагрузить ядро* (применяется
сразу, соединение обрывается на несколько секунд) или *Ничего не делать*
(узлы обновляются только в списке). Ручное ⟳ по-прежнему оставляет решение
за вами.

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
