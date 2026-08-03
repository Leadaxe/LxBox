# L×Box v2.19.3

One dead node used to be able to take the whole tunnel down with it — quietly,
with nothing on screen to say why. This release closes that off from three
sides: the core no longer lets a stalled DNS lookup freeze packet forwarding,
Russian domains now resolve over three independent paths instead of one, and a
node that others depend on gets a ⚠ marker so you can see the blast radius
without going hunting.

The rest of the release comes from a code revision of the last two months of
work: the whole diff was inspected, what turned up was fixed, and the
documentation and specs were brought back in line with the code. Three of those
fixes are about the app refusing to start at all — a copied JSON comment, a node
named like a channel, a malformed field in a subscription. The others are about
things quietly going missing: a node losing its encryption layer, hysteria nodes
falling out of auto-select pools, a setting not surviving a backup restore, a
group member with a comma in its password disappearing after a restart.

Одна мёртвая нода могла утащить за собой весь туннель — тихо, ничего не
показывая на экране. Этот релиз закрывает такое с трёх сторон: ядро больше не
даёт зависшему DNS-запросу заморозить пересылку пакетов, российские домены
резолвятся тремя независимыми путями вместо одного, а нода, от которой зависят
другие, получает ⚠-метку — видно радиус поражения, не разбираясь вручную.

Остальное в релизе — из ревизии кода за два последних месяца работ: осмотрен
весь дифф, найденное исправлено, документация и спеки приведены в соответствие
с кодом. Три исправления оттуда — про то, что приложение вовсе отказывалось
запускаться: скопированный комментарий в JSON, узел с именем канала, поле не
того типа в подписке. Остальные — про тихие пропажи: узел терял слой шифрования,
hysteria-узлы выпадали из пулов автовыбора, настройка не переживала
восстановление из бэкапа, член группы с запятой в пароле исчезал после
перезапуска.

Separately, for those who drive the app over the Debug API: a subscription can
now be configured in full from there — fetch identity (including the `x-hwid`
header some panels gate on), auto-update reaction, and import rules. /
Отдельно, для тех, кто управляет приложением через Debug API: подписка теперь
настраивается оттуда целиком — идентичность фетча (включая заголовок `x-hwid`,
по которому гейтят некоторые панели), реакция на автообновление и правила
импорта.

Core / Ядро: **sing-box-lx `v1.14.0-lx.20-rc.2`** (was / было
`v1.14.0-lx.19-rc.3`) — SPEC 046, the packet-loop fix described below, on top of
a build-environment release (`lx.20-rc.1`: a single Go 1.25.x toolchain pin
across every build job, no core code changes). Java surface unchanged. /
SPEC 046, фикс пакетной петли из описания ниже, поверх релиза про среду сборки
(`lx.20-rc.1`: единый пин тулчейна Go 1.25.x во всех сборочных джобах, без
изменений в коде ядра). Java-поверхность не изменилась.

---

<details open>
<summary><h2>🇬🇧 English</h2></summary>

## 🧊 Fixed — a dead DNS route froze the entire tunnel

**This is the big one, and it is a core fix.** Hijacked DNS queries were
resolved inline, right inside the tun stack's packet loop — and calling the
resolver blocks the caller for as long as the dial takes. So a DNS server whose
`detour` pointed at a black-holed node held the loop for the full DNS timeout,
and while it was held **nothing** went through the tunnel: not other DNS, not
ICMP, not new connections of any protocol.

A background trickle of queries was enough to keep the tunnel frozen almost
continuously. The symptom was maddening precisely because it looked like
nothing at all: zero connections, the core silent, no error anywhere.

DNS exchanges now run off the packet loop, with a ceiling of 256 concurrent
(beyond that the query is dropped and the client retries — normal for UDP). The
bug is older than this release and lived in both tun stacks.

## 🩹 Fixed — the app refused to start

### 💬 A copied JSON comment brought down the whole config

The core rejects a config with an unknown field outright, and a `//` key is
the usual way people comment JSON examples — so a rule copied from an example
meant the VPN would not start, with nothing pointing at the culprit. Raw-JSON
routing rules are now cleaned of such keys with a warning (a rule that is
nothing but comments is skipped), and an import rule whose target path starts
with `//` is simply not applied instead of corrupting the node.

### 🏷 A node named like a channel brought down the whole config

A subscription node labelled `vpn-1` produced two blocks with the same tag in
the config — the node itself and the channel's selector — and the core refused
to start. Channel tags are now reserved before nodes are emitted, so a
same-named node gets a suffix and both survive.

### 🧩 One malformed element killed the import of an entire subscription

If a provider sent a field of the wrong type (a string where an object was
expected), the exception took down the parsing of the whole subscription
instead of that one element. Now exactly the broken node is skipped, with a
warning, and its neighbours are imported as usual.

## 🔍 Fixed — things went missing quietly

### 🔐 A VLESS node with a chain lost its encryption layer

A node that had both a `dialerProxy` chain and the post-quantum `encryption`
layer arrived without the layer: the code that reassembles the node for the
chain listed its fields by hand and this one was not on the list. Such nodes
silently failed to connect.

### 🎯 Hysteria nodes fell out of auto-select pools

The node identity key computed by the parser and the one computed by the
builder disagreed in three ways — the protocol name for the fork's hysteria
form, the default port, and the `xtls-rprx-vision-udp443` quirk. A pool member
that did not match was dropped without a word; for hysteria nodes this was
always the case.

### 📋 A member with a comma in its password disappeared from an auto-select group

The list of group members is stored comma-separated, and an ss/trojan password
containing a comma broke the split — the member vanished after the app was
restarted. Existing groups are read exactly as before, no migration needed.

### 💾 "Auto ping on start" did not survive a backup restore

The setting was exported but dropped on import — the only key missing from the
import list, which also produced a puzzling "1 unknown keys skipped" on your
own backup.

### 🔢 Large subscriptions could shuffle node names

Above 32 elements the sort used for deciding which element names a duplicated
server stopped being stable, so the name could go to an arbitrary element
rather than the first one in the file.

### 🛡 A numeric `short_id` slipped past the REALITY safety net

The safety net added for broken REALITY blocks only looked at string values;
a numeric one went through untouched and was rejected by the core.

## 🎛 Fixed — false signals

### 🔵 A false "Settings changed" banner after updating a disabled subscription

A disabled subscription is not part of the config, so its update has nothing
to rebuild — but the banner appeared anyway. Noticeable with "Update disabled
subscriptions" turned on.

### 📊 A single ping measurement could land in the wrong channel

If you switched channels while a measurement was in flight, the result was
written to the channel you switched to, not the one it was taken from.

### ⏱ The profiler reported zero duration for short connections

A connection that opened and closed between two polling ticks showed a
duration of 0 and could be falsely flagged as "RST / blocked". The open and
close timestamps now come from the core.

### 🔧 Debug API leaked an internal marker

`/folders/{id}/probe` answered with a raw `__vpn_running__` instead of a clear
409 when the VPN was running.

## 🇷🇺 Changed — Russian domains resolve over three independent paths

The "Russian domains & IPs" preset sent all Russian DNS through a single
server: `yandex_udp`, detoured into the preset's own channel. Pick a dead node
in that channel and every Russian lookup hung until it timed out — and with the
core bug above, that could stall everything else along with it.

Those domains are now served by a DNS group, `dns_ru`, racing three members
whose failure paths do not overlap:

| Member | Transport | Route | What kills it |
|---|---|---|---|
| `yandex_udp` | UDP :53 | the preset's channel | a dead node in that channel |
| `yandex_dot` | DoT :853 | `vpn-1` | a dead `vpn-1` |
| `yandex_doh` | DoH :443 | direct | an ISP blocking 443 |

Whichever answers first wins; a member that errors is set aside for five
minutes. A dead node in the channel now costs you one path out of three instead
of all of them.

On the security side: DoT and DoH are encrypted, so routing them outside the
main channel leaks nothing. Plain UDP goes wherever the preset's traffic goes —
your provider (ISP or VPN) already sees where those connections lead, so an
open lookup along the same path tells them nothing new.

The per-preset "DNS server" dropdown is gone. Every single-server option in it
meant going back to one point of failure — the exact bug above. The traffic
channel and the UDP resolver address are still yours to set. No migration is
needed: the previously stored value simply stops having any effect.

## ⚠️ Added — a dead node now shows who depends on it

A node that fails its ping is easy to spot. What you could not see is that
other things route **through** it: DNS servers, other nodes, whole channels
where it happens to be the current pick. That link lived only inside the config
builder.

Now a failing node that others depend on carries a ⚠ marker next to its name.
Tapping it opens the list of everything affected, with the dependency path
spelled out. The DNS branch gets an extra banner, because that case is silent
by nature — domains on such a server simply stop resolving, with no error to go
on.

No new background probing was added: this works purely off pings you already
ran and group selections you already made. A node that was never measured stays
`unknown` and raises nothing. Auto-test (urltest) channels are excluded — they
heal themselves.

## 🔧 Added — Debug API can now configure a subscription in full

For those who drive the app over the Debug API (Settings → Developer). Three
groups of per-subscription settings existed in the app but had no way in from
the API: the fetch identity (User-Agent, `x-hwid`, device metadata), the
reaction to an auto-update, and the import rules.

The identity one had teeth. Panels that gate a subscription by hardware ID hand
out a placeholder node named `App not supported` until they see an `x-hwid`
header — and the only switch reachable from the API was the global one, which
changes the fetch for *every* subscription. The per-subscription override the
app already had was unreachable. `PATCH /subs/{id}` now takes it:
`{"identity":{"send_hwid":true,"hwid":"<uuid>"}}` enables HWID for that one
subscription and leaves the global settings alone; `{"identity":null}` puts it
back on the global identity.

Import rules got their own sub-resource, `/subs/{id}/rules` — list, create,
edit, delete and reorder one rule at a time, instead of resending the whole set
on every change. Order is preserved, since rules apply in sequence.

Nothing changed in the app's own screens: same settings, same behaviour, now
also reachable headless. `GET /subs/{id}` reports all of it, and `/help` is
updated.

## 📚 Documentation

The source trees in ARCHITECTURE.md were brought up to date after two months
of work; the diagnostics playbook and the Debug API reference gained the two
handles added in v2.19.2 (`quic-knobs`, verbose core logs). Spec statuses were
corrected where they claimed "pending" for work already released, and one
number collision was untangled. The v2.19.2 notes said "unlocking the screen"
where the shipped behaviour is "the screen turning on" — the wording now
matches the code.

## ✅ Tests

2743 tests green, full project analysis clean, all four localisation checks
clean.

</details>

---

<details open>
<summary><h2>🇷🇺 Русский</h2></summary>

## 🧊 Исправлено — мёртвый DNS-маршрут морозил весь туннель

**Это главное в релизе, и это фикс ядра.** Hijack'нутые DNS-запросы резолвились
прямо в пакетной петле tun-стека, а вызов резолвера блокирует вызывающего на
время дозвона. DNS-сервер, у которого `detour` указывал на чёрнодырную ноду,
держал петлю весь DNS-таймаут — и всё это время сквозь туннель не шло
**ничего**: ни другие DNS, ни ICMP, ни новые соединения любого протокола.

Фоновой струйки запросов хватало, чтобы держать туннель замороженным почти
непрерывно. Симптом бесил именно тем, что выглядел как пустота: ноль
соединений, ядро молчит, ошибок нигде нет.

Теперь DNS-обмены идут вне петли, потолок — 256 одновременных (сверх дропается,
клиент ретраит: для UDP это норма). Баг старше этого релиза и жил в обоих
tun-стеках.

## 🩹 Исправлено — приложение отказывалось запускаться

### 💬 Скопированный комментарий в JSON ронял весь конфиг

Ядро отвергает конфиг с неизвестным полем целиком, а `//`-ключ — обычная
манера комментировать JSON-примеры, так что правило, скопированное из примера,
означало, что VPN не запустится, и ничто не указывало на виновника. Теперь
raw-JSON правила роутинга вычищаются от таких ключей с предупреждением
(правило целиком из комментариев пропускается), а правило импорта, у которого
путь назначения начинается с `//`, просто не применяется вместо порчи узла.

### 🏷 Узел с именем канала ронял весь конфиг

Узел подписки с меткой `vpn-1` давал в конфиге два блока с одним тегом — сам
узел и селектор канала, — и ядро отказывалось стартовать. Теперь теги каналов
резервируются до эмиссии узлов: узел-тёзка получает суффикс, и живут оба.

### 🧩 Один битый элемент убивал импорт всей подписки

Если провайдер присылал поле не того типа (строку там, где ожидался объект),
исключение уносило разбор всей подписки, а не одного элемента. Теперь
пропускается ровно битый узел, с предупреждением, а его соседи импортируются
как обычно.

## 🔍 Исправлено — тихие пропажи

### 🔐 Узел VLESS с цепочкой терял слой шифрования

Узел, у которого были и цепочка через `dialerProxy`, и постквантовый слой
`encryption`, приезжал без слоя: код, пересобирающий узел под цепочку,
перечислял поля вручную, и этого в списке не было. Такие узлы молча не
подключались.

### 🎯 Узлы hysteria выпадали из пулов автовыбора

Ключ идентичности узла, посчитанный парсером, расходился с посчитанным
билдером в трёх местах — имя протокола для формы форка hysteria, порт по
умолчанию и особый случай `xtls-rprx-vision-udp443`. Член пула, который не
совпал, отбрасывался без единого слова; для hysteria-узлов — всегда.

### 📋 Член с запятой в пароле исчезал из группы автовыбора

Список членов группы хранится через запятую, и пароль ss/trojan с запятой
ломал раскрой — член пропадал после перезапуска приложения. Существующие
группы читаются ровно как раньше, миграция не нужна.

### 💾 «Auto ping on start» не переживала восстановление из бэкапа

Настройка выгружалась, но отбрасывалась при импорте — единственный ключ, не
попавший в список разрешённых, из-за чего на собственный бэкап показывалось
загадочное «1 unknown keys skipped».

### 🔢 Большие подписки могли перемешать имена узлов

Начиная с 33 элементов сортировка, решающая, какой элемент даёт имя
задублированному серверу, переставала быть устойчивой, и имя могло достаться
произвольному элементу вместо первого по файлу.

### 🛡 Числовой `short_id` проскакивал мимо страховки REALITY

Страховка, добавленная для битых REALITY-блоков, смотрела только на строковые
значения; числовое проходило нетронутым и отвергалось ядром.

## 🎛 Исправлено — ложные сигналы

### 🔵 Ложная плашка «Настройки изменены» после обновления выключенной подписки

Выключенная подписка в конфиг не входит, значит её обновлению нечего
пересобирать — но плашка всё равно появлялась. Заметно при включённой галке
«обновлять выключенные подписки».

### 📊 Одиночный замер пинга мог попасть в чужой канал

Если переключить канал, пока замер ещё идёт, результат записывался в тот
канал, куда переключились, а не в тот, с которого замеряли.

### ⏱ Профайлер показывал нулевую длительность коротких соединений

Соединение, открывшееся и закрывшееся между двумя тиками опроса, показывало
длительность 0 и могло получить ложную пометку «RST / blocked». Время открытия
и закрытия теперь берётся из меток ядра.

### 🔧 Debug API отдавал внутренний маркер

`/folders/{id}/probe` при работающем VPN отвечал сырым `__vpn_running__`
вместо внятного 409.

## 🇷🇺 Изменено — российские домены резолвятся тремя независимыми путями

Пресет «Russian domains & IPs» гонял весь ru-DNS через один сервер:
`yandex_udp` с detour'ом в собственный канал пресета. Выбрал в этом канале
мёртвую ноду — и каждый ru-запрос висел до таймаута, а с ядровым багом выше мог
подвесить и всё остальное.

Теперь домены обслуживает DNS-группа `dns_ru` — гонка трёх членов с
непересекающимися путями отказа:

| Член | Транспорт | Путь | Что его убивает |
|---|---|---|---|
| `yandex_udp` | UDP :53 | канал пресета | мёртвая нода в этом канале |
| `yandex_dot` | DoT :853 | `vpn-1` | мёртвый `vpn-1` |
| `yandex_doh` | DoH :443 | напрямую | провайдер режет 443 |

Побеждает ответивший первым; ошибившийся член откладывается на пять минут.
Мёртвая нода в канале теперь стоит одного пути из трёх, а не всех сразу.

Про безопасность: DoT и DoH шифрованы, вести их мимо основного канала — не
утечка. Открытый UDP идёт туда же, куда трафик пресета: провайдер (оператор или
VPN) и так видит, куда уходят эти соединения, так что открытый запрос по тому
же пути ничего нового ему не сообщает.

Выпадающий список «DNS server» в пресете убран. Любой одиночный сервер в нём
возвращал единственную точку отказа — ровно тот баг, что описан выше. Канал
трафика и адрес UDP-резолвера по-прежнему настраиваются. Миграция не нужна:
прежнее сохранённое значение просто перестаёт на что-либо влиять.

## ⚠️ Добавлено — мёртвая нода показывает, кто от неё зависит

Ноду, которая не отвечает на пинг, видно сразу. Не видно другого: что через неё
ходят остальные — DNS-серверы, другие ноды, целые каналы, где она оказалась
текущим выбором. Эта связь жила только внутри сборщика конфига.

Теперь у неработающей ноды, от которой зависят другие, рядом с именем
появляется ⚠. Тап открывает список пострадавших с расписанным путём
зависимости. Для DNS-ветки дополнительно показывается баннер — этот случай нем
по своей природе: домены такого сервера просто перестают резолвиться, и
зацепиться не за что.

Никакой новой фоновой диагностики не добавилось: всё работает от уже сделанных
замеров пинга и уже сделанного выбора в группах. Нода, которую ни разу не
мерили, остаётся `unknown` и не тревожит. Каналы с автотестом (urltest)
исключены — они самолечатся.

## 🔧 Добавлено — Debug API настраивает подписку целиком

Для тех, кто управляет приложением через Debug API (Settings → Developer). Три
группы настроек подписки жили в приложении, но со стороны API к ним не было
доступа: идентичность фетча (User-Agent, `x-hwid`, метаданные устройства),
реакция на автообновление и правила импорта.

С идентичностью выходило больнее всего. Панели, которые гейтят подписку по
идентификатору устройства, до появления заголовка `x-hwid` отдают узел-заглушку
с именем `App not supported` — а из API дотянуться можно было только до
глобального переключателя, меняющего фетч у *всех* подписок. Собственный
override подписки, который в приложении давно есть, оставался недоступен.
Теперь его принимает `PATCH /subs/{id}`:
`{"identity":{"send_hwid":true,"hwid":"<uuid>"}}` включает HWID одной подписке
и не трогает глобальные настройки, `{"identity":null}` возвращает её на
глобальную идентичность.

Правила импорта получили собственный под-ресурс `/subs/{id}/rules` — список,
создание, правка, удаление и перестановка по одному правилу, вместо пересылки
всего набора на каждое изменение. Порядок сохраняется: правила применяются
последовательно.

В экранах приложения ничего не поменялось: те же настройки, то же поведение,
теперь доступное ещё и headless. `GET /subs/{id}` отдаёт всё перечисленное,
`/help` обновлён.

## 📚 Документация

Деревья исходников в ARCHITECTURE.md актуализированы после двух месяцев работ;
playbook диагностики и справочник Debug API получили две ручки, появившиеся в
v2.19.2 (`quic-knobs`, подробные логи ядра). Статусы спек поправлены там, где
они утверждали «ожидает проверки» о работах, уже вышедших в релиз, и разведена
одна коллизия номеров. В заметках v2.19.2 было написано «после разблокировки
экрана», тогда как в сборку вошло «после включения экрана» — формулировка
приведена к коду.

## ✅ Тесты

2743 теста зелёные, анализ всего проекта чистый, все четыре проверки
локализации чистые.

</details>

---

## 📲 Install

```bash
adb install -r LxBox-v2.19.3-arm64-v8a.apk
```

Без uninstall! Поверх существующей установки. Настройки и подписки сохранятся.

No uninstall needed — install over the existing one. Settings and
subscriptions are preserved.

---

Previous release / Предыдущий релиз: [v2.19.2](docs/releases/v2.19.2.md).
