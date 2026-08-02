# L×Box v2.19.3

A maintenance release, built entirely from a code revision of the last two
months of work. No new features: the whole diff was inspected, what turned up
was fixed, and the documentation and specs were brought back in line with the
code.

Three of the fixes are about the app refusing to start at all — a copied
JSON comment, a node named like a channel, a malformed field in a
subscription. The rest are about things quietly going missing: a node losing
its encryption layer, hysteria nodes falling out of auto-select pools, a
setting not surviving a backup restore, a group member with a comma in its
password disappearing after a restart.

Релиз обслуживания, целиком собранный из ревизии кода за два последних месяца
работ. Новых функций нет: осмотрен весь дифф, найденное исправлено, а
документация и спеки приведены в соответствие с кодом.

Три исправления — про то, что приложение вовсе отказывалось запускаться:
скопированный комментарий в JSON, узел с именем канала, поле не того типа в
подписке. Остальные — про тихие пропажи: узел терял слой шифрования,
hysteria-узлы выпадали из пулов автовыбора, настройка не переживала
восстановление из бэкапа, член группы с запятой в пароле исчезал после
перезапуска.

Core / Ядро: **sing-box-lx `v1.14.0-lx.20-rc.1`** (was / было
`v1.14.0-lx.19-rc.3`). No code changes in the core itself — that release is
purely about the build environment: a single Go 1.25.x toolchain pin across
every build job. / Изменений в коде ядра нет — тот релиз целиком про среду
сборки: единый пин тулчейна Go 1.25.x во всех сборочных джобах.

---

<details open>
<summary><h2>🇬🇧 English</h2></summary>

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

## 📚 Documentation

The source trees in ARCHITECTURE.md were brought up to date after two months
of work; the diagnostics playbook and the Debug API reference gained the two
handles added in v2.19.2 (`quic-knobs`, verbose core logs). Spec statuses were
corrected where they claimed "pending" for work already released, and one
number collision was untangled. The v2.19.2 notes said "unlocking the screen"
where the shipped behaviour is "the screen turning on" — the wording now
matches the code.

## ✅ Tests

2723 tests green (+10 new regression tests covering each fix above), full
project analysis clean, all four localisation checks clean.

</details>

---

<details open>
<summary><h2>🇷🇺 Русский</h2></summary>

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

## 📚 Документация

Деревья исходников в ARCHITECTURE.md актуализированы после двух месяцев работ;
playbook диагностики и справочник Debug API получили две ручки, появившиеся в
v2.19.2 (`quic-knobs`, подробные логи ядра). Статусы спек поправлены там, где
они утверждали «ожидает проверки» о работах, уже вышедших в релиз, и разведена
одна коллизия номеров. В заметках v2.19.2 было написано «после разблокировки
экрана», тогда как в сборку вошло «после включения экрана» — формулировка
приведена к коду.

## ✅ Тесты

2723 теста зелёные (+10 новых регрессионных, покрывающих каждое исправление
выше), анализ всего проекта чистый, все четыре проверки локализации чистые.

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
