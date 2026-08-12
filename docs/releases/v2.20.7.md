# L×Box v2.20.7

Mass actions on test results are now available on subscriptions, not just
folders: after a run you can switch off everything that failed, or everything
slower than a threshold you name, instead of tapping through hundreds of
toggles. A Diagnostics tab now shows what the world actually sees through a
node — exit IP, geo, `warp=` — without switching to it and cutting your live
connections. The core fixes chains through a `detour` that used to die on a
silent MTU wall. And an app that hung on "Connected" after a failed start no
longer does.

Массовые действия по результатам теста появились и на подписке — раньше они
были только у папки. После прогона можно выключить всё, что не ответило, или
всё, что медленнее заданного порога, вместо перещёлкивания сотен тумблеров.
Вкладка Diagnostics показывает, что на самом деле видно через узел — exit-IP,
гео, `warp=` — не переключаясь на него и не обрывая живые соединения. Ядро
чинит цепочки «через detour», которые раньше умирали о молчаливую стену MTU.
И приложение больше не залипает в «Подключено» после неудачного старта.

<details open>
<summary><h2>🇬🇧 English</h2></summary>

## ✨ What's new

**Mass actions on test results, now on subscriptions.** Folders and
subscriptions run the same server test, but only folders could act on the
result. On a subscription you were left with per-node toggles: ping seven
hundred nodes, then switch off three dozen failures by hand. The `⋮` menu in
the test row now offers "Disable slower than…" and "Disable unreachable" —
the latter covering nodes that failed, came back broken, or were invalid.

"Delete unreachable" is deliberately not carried over: subscription nodes
belong to the provider and a refresh brings them back. For a subscription,
deleting *is* disabling, and that already exists.

One caveat the app tells you about: if the subscription has a filter rule with
an Enable action, that rule owns the truth and will clear these marks on the
next refresh. The warning appears in the threshold dialog and as a confirmation
before disabling unreachable nodes.

**Known endpoints in the WARP wizard are now picked from a list.** The default
`engage.cloudflareclient.com:2408` is dropped outright by some carriers, and
the 🎲 button only ever gave a random value — nobody remembers working
addresses by hand. The WG Endpoint and MASQUE Endpoint IP fields are now
comboboxes: type freely, or pick from the known values, with the dice still
next to them.

**A Diagnostics tab: what the world sees through this node.** Node diagnostics
stopped at a single number — the ping answers "alive, N ms" and throws the
response body away. A whole class of complaints needs the body instead: "ping
works but sites don't open", "the node is up but the geo is wrong", "WARP is
connected yet `warp=off`". Checking that meant switching to the node and
opening a browser — diagnosis at the price of cutting live connections.

The core now offers `GetURLViaOutbound`: a GET through a node addressed by tag,
returning the body, without touching the active selector. The tab is one shared
widget across all three node-detail screens, with a dropdown of predefined
checkers (`cdn-cgi/trace` by IP and by host, ip2location, ipinfo), a button,
and the raw response in a field. The body is deliberately *not* parsed — if a
third-party service changes its format, the tab keeps working. (§392)

**The recommended MASQUE SNI is marked in the wizard.** `consumer-masque` now
leads the SNI pool and carries an explicit "recommended" mark, so the value
that actually works is the one you land on rather than a lucky guess.

## 🔧 Changed

**The "all nodes" switch moved into the test row** and now shows the state it
is in rather than the action it would perform. Previously it sat in the
metadata block, far from everything else acting on the list, and its icon was
chosen by the future action — so with every node enabled it looked switched
off, and vice versa.

**The test actions menu unlocks on the first verdict**, not at the end of the
run, and the `⋮` button itself is always present. It used to appear only once
results existed: the control blinked in and out, neighbouring buttons shifted,
and before your first test there was no way to discover the menu at all.

## 🐛 Fixed

**The app hung on "Connected" after a failed start.** On mobile networks with
whitelisting, starting a node with a domain address could stall inside the core
for longer than the fifteen-second timeout the app allows. The app would give
up and tear the session down — and then the stalled start would return seconds
later and announce "started". The result was a connection to an already-dead
session: the UI said Connected, stopping did nothing, starting again did
nothing. The late answer is now checked against the current state; if the
session was already stopped, it is ignored and the core that did manage to come
up is shut down. (§387)

**The "recommended" mark on WARP presets no longer depends on list order** — it
follows an explicit value, at any position. Long preset labels no longer wrap
to a second line, and the MASQUE list puts the domain first. (§386)

**The reload button on the home screen no longer gets pushed off-screen** by a
long status label.

Opening a `market://` link on a device without Google Play no longer dead-ends:
the plain https form is used instead.

## 🔌 Core

Core pin: `v1.14.0-lx.22` → `v1.14.0-lx.25-rc.3`, three steps in one release.

**Chains through a `detour` no longer fail silently (SPEC 060).** A chain like
`MASQUE detour VLESS` would hang for about fifteen seconds and die with
`tls handshake: EOF`, an error you cannot work backwards from. The cause is
neither the core nor the SNI: the lower leg forwards our ClientHello under its
own name, and if the PMTU beyond that leg is smaller than the ClientHello, the
packet is dropped in silence — the ICMP "fragmentation needed" never reaches
the client. Measurements on live nodes give a clean size threshold: 1488 B
passes, 1502 B vanishes, and the threshold belongs to the path beyond the leg
rather than to the protocol — on other nodes the very same bytes go straight
through. It reproduces with plain `curl`, no sing-box involved.

The cure is fragmenting the first TLS record, and the mechanism was already in
the core (`fragment` / `record_fragment`) — what was missing was a default.
`record_fragment` now switches itself on when an outbound dials through a
`detour`. Note this affects *any* outbound with a `detour`, not just MASQUE
chains. An explicit choice always wins, and `fragment: true` is not upgraded by
adding a record split. The cost is bounded to the handshake: only the first
record is rewritten, an established stream is untouched. Direct paths, without
a `detour`, are unaffected.

**MASQUE over h2 moved onto the shared TLS layer (SPEC 021).** It was the last
outbound bypassing `common/tls`: on h2 it ran TLS through a bare
`crypto/tls.Client` for the sake of pinning the endpoint's ECDSA key, and in
exchange got nothing from the shared layer. Pinning now sits on top of the
shared client. h3 is untouched — QUIC does not carry TLS over TCP.

The step before that (`lx.24-rc.2`) caught the branch up with upstream — 19
commits on base `v1.14.0-beta.9` — and moved the toolchain to Go 1.26.5. From
that tail: DNS caches of the local transport are partitioned by interface
signature, so a network change no longer serves a cache belonging to the other
network; the WireGuard handshake resolves *all* addresses of a domain peer and
races them; hijacked DNS gained process info; fixes landed for network reset,
FakeIP async save, the Android process finder, and unbounded allocations on a
hostile rule set.

Then `lx.25-rc.1` added `GetURLViaOutbound`, the core half of the Diagnostics
tab above.

## 📦 Version

`v1.14.0-lx.23` and `v1.14.0-lx.24-rc.1` concern the desktop `lxd` daemon and
do not affect the Android build, which is why the pin jumps straight from
lx.22 to lx.24-rc.2 and on to the lx.25 line.

The AAR's Java surface did change once along the way: `lx.25-rc.1` added
`GetURLResult`, `HTTPHeaders` and `CommandClient.getURLViaOutbound`, which the
Diagnostics tab consumes. Between rc.1 and rc.3 `classes.jar` is byte-for-byte
identical, so the final bump required no client-side changes.

## 🧪 Tests

`flutter analyze` over the whole project and the full suite (3002 tests) are
green, as are the four l10n checkers. The release APK was built, installed and
run on a physical device as well as an emulator: the core starts, the tunnel
comes up, DNS resolves through it, node latency tests return, and the stop path
tears everything down cleanly with no crashes.

The core is still labelled a release candidate upstream in the fork, so the
lx.25 line is not yet promoted to stable there. The new `record_fragment`
default is the change to watch: it alters behaviour for every outbound that
dials through a `detour`, not only the MASQUE chains it was written for.

</details>

<details open>
<summary><h2>🇷🇺 Русский</h2></summary>

## ✨ Что нового

**Массовые действия по результатам теста — теперь и на подписке.** У папки и
подписки один и тот же тест серверов, но действовать по его результатам можно
было только в папке. На подписке оставались поштучные тумблеры: пропинговал
семьсот нод — три десятка ошибок выключай пальцем. В меню `⋮` строки теста
появились «Disable slower than…» и «Disable unreachable» — второе забирает
не ответившие, битые и невалидные узлы.

«Delete unreachable» намеренно не перенесён: узлы подписки принадлежат
провайдеру, обновление вернёт их обратно. Для подписки «удалить» и есть
«выключить», и это уже есть.

Одна оговорка, о которой приложение предупреждает само: если у подписки есть
правило фильтров с действием Enable, источник истины — правило, и на следующем
обновлении оно эти отметки снимет. Предупреждение показывается в диалоге порога
и подтверждением перед выключением неотвечающих.

**Известные адреса в визарде WARP выбираются из списка.** Дефолтный
`engage.cloudflareclient.com:2408` у части операторов дропается целиком, а
кубик 🎲 давал только случайное значение — рабочие адреса руками никто не
помнит. Поля WG Endpoint и MASQUE Endpoint IP стали комбобоксами: свободный
ввод либо выбор из известных значений, кубик по-прежнему рядом.

**Вкладка Diagnostics — что видно через узел.** Диагностика узла упиралась в
одно число: пинг отвечает «жив, N мс» и выбрасывает тело ответа. Жалобы другого
класса требуют как раз содержимого: «пинг есть, а сайты не открываются», «узел
работает, но гео чужая», «WARP подключён, а `warp=off`». Проверить это можно
было только переключившись на узел и открыв браузер — диагностика ценой обрыва
живых соединений.

Ядро дало `GetURLViaOutbound`: GET через узел по тегу с возвратом тела, при
этом активный selector не трогается. Вкладка — общий виджет на всех трёх
экранах деталей узла: выпадающий список предопределённых чекеров (`cdn-cgi/trace`
по IP и по хосту, ip2location, ipinfo), кнопка и сырой ответ в поле. Тело
намеренно **не** парсится: смена формата чужого сервиса вкладку не ломает.
(§392)

**Рекомендованный MASQUE SNI помечен в визарде.** `consumer-masque` теперь идёт
в пуле SNI первым и несёт явную пометку «рекомендуется» — попадаешь на рабочее
значение, а не угадываешь.

## 🔧 Изменено

**Переключатель «все узлы» переехал в строку теста** и показывает состояние, в
котором находится, а не действие, которое выполнит. Раньше он жил в блоке
метаданных, далеко от прочих действий над списком, а иконка выбиралась по
будущему действию — поэтому при всех включённых узлах выглядел выключенным, и
наоборот.

**Меню действий по тесту разблокируется по первому вердикту**, а не в конце
прогона, и сама кнопка `⋮` всегда на месте. Раньше она появлялась только при
готовых результатах: контрол то возникал, то исчезал, соседние кнопки
разъезжались, а до первого теста меню было не найти вовсе.

## 🐛 Исправлено

**Приложение залипало в «Подключено» после неудачного старта.** На мобильных
сетях с «белыми списками» старт узла с доменным адресом мог зависнуть внутри
ядра дольше, чем пятнадцатисекундный таймаут обвязки. Обвязка сдавалась и
сносила сессию — а зависший старт возвращался секундами позже и объявлял
«запущено». Получалось подключение к уже мёртвой сессии: интерфейс показывал
«Подключено», остановка не работала, повторный запуск тоже. Теперь поздний
ответ сверяется с текущим состоянием: если сессию уже остановили, он
игнорируется, а успевшее подняться ядро добивается. (§387)

**Пометка «рекомендуется» у пресетов WARP больше не зависит от порядка списка**
— она следует за явным значением, на любой позиции. Длинные подписи пресетов
не переносятся на вторую строку, а в списке MASQUE первым идёт домен. (§386)

**Кнопка перезагрузки на главном экране не уезжает за край** при длинной
надписи статуса.

Открытие ссылки `market://` на устройстве без Google Play больше не ведёт в
тупик — подставляется обычная https-форма.

## 🔌 Ядро

Пин ядра: `v1.14.0-lx.22` → `v1.14.0-lx.25-rc.3`, три шага за один релиз.

**Цепочки «через detour» перестали молча не подниматься (SPEC 060).** Связка
вида `MASQUE detour VLESS` висела около пятнадцати секунд и падала с
`tls handshake: EOF` — по такой ошибке причину не восстановить. Дело не в ядре
и не в SNI: нижнее плечо пересылает наш ClientHello от своего имени, и если
PMTU за этим плечом меньше размера ClientHello, пакет теряется молча — ICMP
«fragmentation needed» до клиента не доходит. Замер на живых узлах даёт чистый
порог по размеру: 1488 B проходит, 1502 B исчезает, и порог принадлежит пути за
плечом, а не протоколу — на других узлах те же самые байты идут насквозь.
Воспроизводится голым `curl`, без sing-box.

Лечится фрагментацией первой TLS-записи, и механизм в ядре уже был
(`fragment` / `record_fragment`) — не хватало умолчания. Теперь
`record_fragment` включается сам, когда outbound диалит через `detour`.
Обратите внимание: это задевает **любой** outbound с `detour`, не только
MASQUE-цепочки. Явный выбор пользователя всегда сильнее, а `fragment: true` не
апгрейдится добавлением record-split. Цена ограничена хендшейком —
переписывается только первая запись, установившийся поток не трогается. Прямой
путь, без `detour`, не затронут.

**MASQUE на h2 переехал на общий TLS-слой (SPEC 021).** Это был последний
outbound мимо `common/tls`: на h2 он вёл TLS голым `crypto/tls.Client` ради
pinning'а по ECDSA-ключу endpoint'а — и взамен не получал из общего слоя
ничего. Теперь pinning лежит поверх общего клиента. h3 не тронут: QUIC не несёт
TLS поверх TCP.

Шаг до этого (`lx.24-rc.2`) догнал ветку до upstream — 19 коммитов на базе
`v1.14.0-beta.9` — и перевёл тулчейн на Go 1.26.5. Из того хвоста: DNS-кеши
локального транспорта партиционируются по сигнатуре интерфейса, смена сети
больше не отдаёт кеш, принадлежащий другой сети; WireGuard-хендшейк резолвит
**все** адреса домен-пира и гонит их наперегонки; hijacked-DNS получил process
info; исправлены reset network, FakeIP async-save, Android process finder и
неограниченные аллокации на злом наборе правил.

Затем `lx.25-rc.1` добавил `GetURLViaOutbound` — ядровую половину вкладки
Diagnostics выше.

## 📦 Версия

`v1.14.0-lx.23` и `v1.14.0-lx.24-rc.1` касаются десктопного демона `lxd` и на
Android-сборку не влияют — поэтому пин прыгает с lx.22 сразу на lx.24-rc.2, а
дальше на линию lx.25.

Java-поверхность AAR по пути один раз изменилась: `lx.25-rc.1` добавил
`GetURLResult`, `HTTPHeaders` и `CommandClient.getURLViaOutbound` — их и
потребляет вкладка Diagnostics. Между rc.1 и rc.3 `classes.jar` побайтово
совпадает, поэтому финальный бамп клиентских правок не потребовал.

## 🧪 Тесты

`flutter analyze` по всему проекту и полный прогон (3002 теста) зелёные, как и
четыре l10n-чекера. Release-APK собран, установлен и запущен и на физическом
устройстве, и на эмуляторе: ядро стартует, туннель поднимается, DNS через него
резолвится, тесты задержки узлов отвечают, остановка сносит всё чисто и без
крашей.

В самом форке линия lx.25 пока помечена как релиз-кандидат и в stable не
промоучена. Главное, за чем стоит следить, — новое умолчание
`record_fragment`: оно меняет поведение любого outbound'а, который диалит через
`detour`, а не только тех MASQUE-цепочек, ради которых писалось.

</details>

---

## Install / Установка

```bash
adb install -r LxBox-v2.20.7-arm64-v8a.apk
```

Без uninstall! Поверх существующей установки. Настройки и подписки сохранятся.

No uninstall needed — install over the existing one. Settings and
subscriptions are preserved.

---

Previous release / Предыдущий релиз: [v2.20.6](docs/releases/v2.20.6.md).
