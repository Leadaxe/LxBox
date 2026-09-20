# L×Box v2.25.0

**One parsing engine with the desktop launcher 2.0.0.** The desktop
[singbox-launcher 2.0.0](https://github.com/Leadaxe/singbox-launcher/releases/tag/v2.0.0)
and L×Box now share one protocol registry (contract 1.1.46). Share links,
Xray JSON, WireGuard `.conf` files and **Copy link** are parsed and built by the
same table-driven engine on both sides; the handwritten per-protocol parsers
are gone. Warning texts come from the same registry too. If one app could read a
node, the other reads it the same way. Core: `v1.14.1-lx.8`.

**Second:** when you press **Start** and the core refuses because of one bad
server, that server is disabled automatically with the core's reason
([#147](https://github.com/Leadaxe/LxBox/issues/147)); the VPN comes up on the
rest.

**Десктопный лаунчер 2.0.0 и телефон — один движок разбора.** У обоих
приложений теперь общий реестр протоколов (контракт 1.1.46). Ссылки,
Xray-JSON, WireGuard `.conf` и **Copy link** разбираются и собираются одной
таблицей на обеих сторонах; рукописные парсеры сняты. Тексты предупреждений —
из того же реестра. Узел, который прочитала одна сторона, читает и другая
одинаково. Ядро: `v1.14.1-lx.8`.

**Второе:** по кнопке **Start**, если ядро отказывается стартовать из‑за одного
негодного сервера, этот сервер выключается сам с причиной от ядра
([#147](https://github.com/Leadaxe/LxBox/issues/147)); VPN поднимается на
остальных.

---

<details open>
<summary><h2>🇬🇧 English</h2></summary>

## 🔗 Parsing aligned with singbox-launcher 2.0.0

| Before | Now |
|---|---|
| Thirteen handwritten link parsers, a separate Xray parser, a separate WireGuard INI parser and a separate link builder | One registry-driven engine for all schemes |
| A fix on the phone did not reach the desktop until someone patched both sides | Rules live in the shared registry; both apps pick them up from the same table |
| Warning texts for some codes lived only in the app | All warning titles, explanations and advice come from `warnings.json` in the registry |
| A node read on one side could differ on the other after **Copy link** | Parse and emit use the same table |

WireGuard and AmneziaWG `.conf` files are a first-class input (not converted to an
internal `wireguard://` link first). Invalid WireGuard keys, masked panel keys
and overlapping AmneziaWG magic headers are no longer dropped silently — the node
gets a named warning or is rejected with a reason.

`socks4://` and `socks4a://` links are recognised; the scheme carries the SOCKS
version.

A few schemes still differ from the desktop on **Copy link** (Shadowsocks padding,
some XHTTP / VMess spellings). Those remaining overlays are tracked, not silent
phone-only patches.

## 🛡 Core rejection insurance ([#147](https://github.com/Leadaxe/LxBox/issues/147))

| Before | Now |
|---|---|
| One bad server in a large subscription blocked the whole VPN; the core message named an index, not a node you recognise | **Start** parses the core's refusal, finds the named server and disables it — the same switch you would use yourself |
| No way to see which servers were turned off | After a clean start, a banner shows how many were disabled; **Show** lists each with the core's text; a tap opens that node's **Diagnostics** (notifications at the bottom) |
| A disabled-by-core server stayed disabled after a subscription refresh even if the provider fixed it | When the node's body changes on refresh, it is enabled again for a new check |
| — | Up to ten silent checks of the remaining servers before the app asks whether to continue; **Start** turns into **Stop** while the cycle runs |

Servers you disabled yourself are never touched. Updating the core alone does not
clear a core verdict — toggle the switch or refresh the subscription. The banner
on the home screen goes away after **Stop** (the verdicts on the nodes stay).

This automatic disable runs on the **Start** button. Quick Settings, boot
auto-start and the watchdog raise the last saved config as before.

## 🩹 Visible fixes (parsing and Copy link)

| Situation | Before | Now |
|---|---|---|
| Xray JSON pasted as a single outbound, a full config with `outbounds`, an array of outbounds, or an array of configs | Only an array of configs was accepted; preview showed zero nodes | All four shapes are accepted; preview shows the real count |
| Base64 subscription text pasted from the clipboard | Worked only as a URL | The wrapper is stripped on paste too |
| `type=splithttp` in a share link | Node was built with no transport — dead TCP on an HTTP port, silently | Read as `xhttp`; same node as the canonical name |
| Hysteria2 `mport` with a port range | Server address landed in the port list → core fatal «bad port range», whole VPN down | Only a number pair is a port-range element; a lone port stays on the server |
| REALITY `pbk` in standard base64 (not URL-safe) | Whole config refused to start | Key is rewritten to the alphabet the core expects — same key, different spelling |
| `naive+quic://` after **Copy link** | Scheme fell back to `naive+https://`; QUIC was lost | `naive+quic://` survives the round-trip |
| VMess over gRPC (**Copy link**) | gRPC service name from v2rayN (`path` in the JSON container) was lost on copy | Emitted back with `serviceName` mapped from `path` |
| TUIC link with empty password (`tuic://uuid:@host`) | Node disappeared or passed silently | Node stays; a warning marks the empty password |
| Xray outbound element without `port` | App silently used 443 or 1080 | Element is dropped, as in Xray-core — no fake node |
| Unknown query parameter on a link | Dropped with a generic message or silently | Named by the parameter |
| WireGuard `[Peer]` without `Endpoint` | Became a node with nowhere to connect | Rejected |
| Disabled TLS object `tls: {"enabled": false}` in a JSON body | Could crash the core on first dial | Removed on input on every path, like links already were |
| Invalid CIDR on a WireGuard address | Whole VPN failed to start | Bad prefix is stripped from that node |
| Fractional port in JSON (`443.9`) | Truncated to `443` | Node is rejected |
| Xray `dialerProxy` pointing at a freedom fragment outbound | Whole node dropped as a bad hop | Node stays direct; TLS fragment is set |
| Naive link `password@host` (no colon in userinfo) | Read as a username with an empty password — auth failed | Read as the password, same as NekoBox / NaiveGUI |

## 📋 Notifications and the lists

| Before | Now |
|---|---|
| One long warning line under a node; info drowned real problems | Error ✖ / warning ⚠ show text; info ⓘ is an icon only — tap opens the full list |
| No structured explanation | Expandable cards **What happened** / **Why it happens** / **What you can do**; **Details** opens offline contract docs |
| Home screen and a cold start hid badges that Servers already showed | The same badge (highest level) on the home node list, including after a cold start and on a standalone server |
| A rejected paste on Servers was a red line under the field | The red line stays; a sheet with the same card opens at once |
| A new source on Servers was easy to miss | The list scrolls to the new row and highlights it as **New** for a few seconds |
| Probe bar labelled «Test servers» | Bulk switch sits with the row toggles; no extra label when idle |

In node details the cards live **at the bottom of Diagnostics**, under the live
Check / Run output. The Diagnostics tab shows a yellow dot when there is
something to read (red on error). There is no separate Notifications tab.

**Copy link** on a node whose link carries a private key (SSH, WireGuard/AWG,
MASQUE) now asks with **Link contains a private key** / **Copy anyway**, instead
of refusing or copying silently.

## ⚙️ Core

`v1.14.1-lx.4` → **`v1.14.1-lx.8`**. A REALITY `short_id` that is too long is an
error, not a process panic. Init errors name the record type and tag — **Start**
uses that to find the bad server. A gRPC `service_name` is passed through as
written.

## ⚠️ What may change for you

| Situation | What happens |
|---|---|
| Xray subscription element with no `port` that used to appear as port 443 or 1080 | The element is dropped — it is not turned into a node anymore |
| REALITY public key in URL-safe base64 (`pbk` with `-` and `_`) | Rewritten to standard base64 in the link the app stores and emits — the key bytes are the same; re-import on another client may show a different spelling |
| Donate | Boosty is removed; crypto addresses are unchanged |

## 🧪 Tests

CI `checks` (analyze, the full test suite, four l10n checkers, docs parity)
is the release gate.

</details>

<details open>
<summary><h2>🇷🇺 Русский</h2></summary>

## 🔗 Сближение с singbox-launcher 2.0.0

| Было | Стало |
|---|---|
| Тринадцать рукописных разборщиков ссылок, отдельный разбор Xray, отдельный разбор WireGuard INI и отдельная сборка ссылки | Один движок по таблицам общего реестра для всех схем |
| Починка на телефоне не доезжала до десктопа, пока не правили обе стороны | Правила живут в общем реестре; оба приложения читают одну таблицу |
| Тексты части предупреждений держались только в коде приложения | Заголовки, объяснения и советы — из `warnings.json` реестра |
| Узел после **Copy link** на одной стороне мог отличаться на другой | Разбор и сборка — одна таблица |

Файлы WireGuard и AmneziaWG `.conf` — полноценный вход (без перевода во
внутреннюю ссылку `wireguard://`). Негодные ключи WireGuard, замаскированные
панелью ключи и пересекающиеся magic-заголовки AmneziaWG больше не исчезают
молча — узел получает названное предупреждение или отбраковывается с причиной.

Ссылки `socks4://` и `socks4a://` распознаются; версию протокола несёт схема.

На части схем **Copy link** всё ещё расходится с десктопом (паддинг Shadowsocks,
некоторые написания XHTTP / VMess). Это учтённые оверлеи, а не тихие заплаты
только на телефоне.

## 🛡 Страховка от отказа ядра ([#147](https://github.com/Leadaxe/LxBox/issues/147))

| Было | Стало |
|---|---|
| Один негодный сервер в большой подписке блокировал весь VPN; строка ядра называла индекс, а не узел из списка | **Start** разбирает отказ ядра, находит названный сервер и выключает его — тем же переключателем, что и вы |
| Не было видно, какие серверы вычистили | После чистого старта плашка с числом отключённых; **Show** — список с текстом ядра по каждому; тап открывает **Diagnostics** этого узла (уведомления снизу) |
| Сервер, выключенный ядром, оставался выключенным после обновления подписки, даже если провайдер его починил | При смене тела узла на обновлении он включается снова для новой проверки |
| — | До десяти тихих проверок остальных серверов, затем вопрос — продолжать или остановиться; **Start** на время цикла становится **Stop** |

Серверы, которые выключили вы сами, не трогаются. Одно обновление ядра вердикт
не снимает — переключатель или обновление подписки. Плашка на главном уходит
после **Stop** (вердикты на узлах остаются).

Автомат срабатывает на кнопке **Start**. Плитка быстрых настроек, автозапуск
после загрузки и сторож поднимают последний сохранённый конфиг, как раньше.

## 🩹 Видимые починки (разбор и Copy link)

| Ситуация | Было | Стало |
|---|---|---|
| Xray-JSON: один outbound, полный конфиг с `outbounds`, массив outbound'ов или массив конфигов | Принимался только массив конфигов; превью показывало ноль узлов | Понятны все четыре формы; превью — настоящее число узлов |
| Подписка base64 из буфера обмена | Работала только по ссылке | Оболочка снимается и при вставке |
| `type=splithttp` в ссылке | Узел без транспорта — мёртвое TCP на HTTP-порту, молча | Читается как `xhttp`; тот же узел, что с каноническим именем |
| Hysteria2: диапазон портов в `mport` | Адрес сервера попадал в список портов → фатал ядра «bad port range», весь VPN | Элементом диапазона считается только пара чисел; одиночный порт остаётся у сервера |
| Публичный ключ REALITY в обычном base64 (не URL-safe) | Ядро отказывалось стартовать целиком | Написание ключа переводится в алфавит ядра — тот же ключ, другая запись |
| `naive+quic://` после **Copy link** | Схема откатывалась к `naive+https://`, QUIC терялся | `naive+quic://` переживает круг |
| VMess по gRPC (**Copy link**) | Имя gRPC-сервиса из v2rayN (поле `path` в JSON-контейнере) терялось при копировании | Возвращается с `serviceName`, сопоставленным с `path` |
| TUIC с пустым паролем (`tuic://uuid:@host`) | Узел исчезал или проходил молча | Узел остаётся; предупреждение о пустом пароле |
| Элемент Xray без поля `port` | Приложение молча подставляло 443 или 1080 | Элемент отбраковывается, как в Xray-core — фиктивного узла нет |
| Неизвестный параметр ссылки | Снимался с общим текстом или молча | Называется по имени параметра |
| WireGuard: `[Peer]` без `Endpoint` | Собирался узел без адреса для соединения | Отбраковывается |
| Выключенный TLS `tls: {"enabled": false}` в JSON-теле | Мог ронять ядро на первом дозвоне | Снимается на входе на всех путях, как у ссылок раньше |
| Негодный CIDR у адреса WireGuard | Не стартовал весь VPN | Дурной префикс снимается с этого узла |
| Дробный порт в JSON (`443.9`) | Усекался до `443` | Узел отбраковывается |
| Xray `dialerProxy` на freedom с fragment | Узел отбрасывался как негодный хоп | Узел остаётся прямым; ставится TLS-фрагментация |
| Ссылка naive `пароль@хост` (в userinfo нет двоеточия) | Читалась как имя без пароля — авторизация не проходила | Читается как пароль, как в NekoBox / NaiveGUI |

## 📋 Уведомления и списки

| Было | Стало |
|---|---|
| Одна длинная строка предупреждения под узлом; info заглушал настоящие проблемы | Error ✖ / warning ⚠ — текстом; info ⓘ — значком; тап открывает полный список |
| Не было структурированного объяснения | Раскрывающиеся карточки **What happened** / **Why it happens** / **What you can do**; **Details** — офлайн-доки контракта |
| На главном и после холодного старта значка не было, хотя на Servers предупреждение уже видно | Тот же значок (старший уровень) в списке Nodes на главном — в том числе после холодного старта и у одиночного сервера |
| Отказ вставки на Servers — красная строка под полем | Строка остаётся; сразу открывается шторка с той же карточкой |
| Новую запись на Servers легко было не заметить | Список прокручивается к новой строке и подсвечивает её как **New** на несколько секунд |
| Probe-бар с подписью «Test servers» | Общий переключатель стоит с тогглами строк; лишней подписи в простое нет |

В деталях узла карточки живут **внизу вкладки Diagnostics**, под живым выводом
Check / Run. На ярлыке Diagnostics — жёлтая точка, если есть что прочитать
(красная при error). Отдельной вкладки Notifications нет.

**Copy link** у узла, чья ссылка несёт приватный ключ (SSH, WireGuard/AWG,
MASQUE), теперь спрашивает **Link contains a private key** / **Copy anyway**,
а не отказывает и не копирует молча.

## ⚙️ Ядро

`v1.14.1-lx.4` → **`v1.14.1-lx.8`**. Слишком длинный REALITY `short_id` — ошибка,
а не паника процесса. В ошибках инициализации ядро называет тип и тег записи —
**Start** по ним находит негодный сервер. Имя gRPC-сервиса уходит как написано.

## ⚠️ Что может измениться у вас

| Ситуация | Что произойдёт |
|---|---|
| Элемент Xray-подписки без `port`, который раньше появлялся с портом 443 или 1080 | Элемент отбраковывается — в узел больше не превращается |
| Публичный ключ REALITY в URL-safe base64 (`pbk` с `-` и `_`) | В ссылке, которую хранит и отдаёт приложение, переписывается в обычный base64 — байты ключа те же; на другом клиенте после повторного импорта запись может выглядеть иначе |
| Поддержка проекта | Boosty убран; криптоадреса без изменений |

## 🧪 Тесты

CI `checks` (analyze, полный набор тестов, четыре l10n-чекера, паритет доков) —
релизный гейт.

</details>

---

## Install / Установка

```bash
adb install -r LxBox-v2.25.0-arm64-v8a.apk
```

Без uninstall! Поверх существующей установки. Настройки и подписки сохранятся.

No uninstall needed — install over the existing one. Settings and subscriptions
are preserved.

---

Previous release / Предыдущий релиз: [v2.24.4](docs/releases/v2.24.4.md).
