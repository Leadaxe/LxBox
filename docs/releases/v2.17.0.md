# L×Box v2.17.0

The headline is **Filters**: rules that fix and weed out subscription nodes on
their own, on every refresh. Plus node inspection (what actually arrived from
the subscription and what it turned into), keepalive in manual WARP
registration, and a fixed MASQUE endpoint generator. Separately — a fix for
WebSocket nodes with `?ed=N` in the path: they connected with a 404 and looked
dead.

Главное — **Filters**: правила, которые чинят и отсеивают узлы подписки сами, на
каждом обновлении. Плюс разбор узла (что именно приехало из подписки и во что
превратилось), keepalive в ручной регистрации WARP и починенный генератор
MASQUE-эндпоинтов. Отдельно — фикс WebSocket-узлов с `?ed=N` в пути: они
подключались с ошибкой 404 и выглядели мёртвыми.

---

<details open>
<summary><h2>🇬🇧 English</h2></summary>

## 🆕 What's new

### 🧰 Filters — subscription processing rules

Every subscription now has a **Filters** tab. Rules apply to its nodes on import
and on every refresh, so a broken parameter from the provider gets fixed once
and stays fixed.

A rule is a set of conditions plus an action. A condition reads as
`path operator value`:

- **path** points inside the node — `tag`, `server`, `server_port`,
  `tls.utls.fingerprint`, `transport.headers.Host` and so on;
- **operator** — `contains` (default), `equals` or `matches`
  (regular expression), plus the **Not** and **Case-sensitive** checkboxes;
- there can be several conditions, combined with **AND** or **OR**;
- an empty path means searching the whole node at once, for when you don't know
  which field holds the value.

There are two actions:

| Action | What it does |
|---|---|
| **Disable** | hides matching nodes from routing — they appear struck through in the list, same as manually disabled ones |
| **Replace** | writes a value at the given path: either whole, or replacing part of the current one; captures `$1`, `$2`… from the regex condition's capture groups are available in the replacement |

Examples:

```
tag contains ⚡                              → Disable
tls.utls.fingerprint matches ^hello(chrome)_\d+$  → tls.utls.fingerprint = $1
```

Rules behave identically across all subscription formats — `vless://`/`trojan://`
lists, Xray JSON, INI/Amnezia — because they apply to the already parsed node
rather than to the subscription text.

The **Apply rules** button at the bottom of the tab reloads the subscription and
reports the outcome ("applied to N nodes, M disabled"). The rule editor has a
**Matches** tab — it runs the rule against the subscription's nodes and shows
which ones it will hit and what exactly it will change, before you even save.

### 🔍 Subscription node inspection

A short tap on a node in the subscription list opens its breakdown:

| Tab | What it shows |
|---|---|
| **JSON** | how the node looks after parsing — what goes into the config |
| **Source** | the original subscription fragment the node was built from |

For JSON subscriptions, Source has a **Compact / Extended** switch: compact
shows the node's outbound object, extended shows the whole element exactly as
the provider sent it.

Many providers serve the subscription as a single base64 string — above the raw
response there's a **Decode base64** checkbox that expands the body into
readable form, the same one the parser works with. The checkbox only appears
when there is something to expand, and in that case it's on right away.

### 🔗 Persistent keepalive for WARP

The Advanced section of the manual WARP registration wizard now has a
**Persistent keepalive (s)** field — for plain WireGuard and for AWG.

| | Keepalive in manual WARP registration |
|---|---|
| Before | never set at all; while the node sat idle the carrier closed the UDP mapping within 30–120 s, ping went to error, the connection dropped — only Rebuild + Reconnect helped |
| Now | a field in Advanced, 25 s by default; `0` or empty means off |

MASQUE is untouched — it has its own QUIC keepalive.

### 🛰️ MASQUE — manual endpoint and experiment window

Manual MASQUE registration now has an **Endpoint IP** field (empty = the
registration server's address) and a port picker; port lists are now separate
per transport. The address pool the generator picks endpoints from has moved to
a dedicated experiment screen — the pool's JSON is editable right there, and the
**Reset** button restores the original. IPv6 endpoints are only offered when
IPv6 is enabled: without a route they are dead anyway.

---

## 🐞 Fixed

- **WebSocket nodes with `?ed=N` in the path failed to connect.** Xray nodes
  commonly set early data as a path suffix (`/api/v2/channel?ed=2560`).

  | | Importing a ws node with `?ed=N` |
  |---|---|
  | Before | the suffix went into the config verbatim, the core requested the path together with `?ed=2560`, the server answered **404** — the node looked dead |
  | Now | the suffix is stripped and the value moves into the core's early data parameter |

  This works for every import path — links, Xray JSON and sing-box JSON. For
  httpupgrade the suffix is stripped as well (the core has no early data field
  for it). Exporting the node back to a link puts `?ed=N` back in place.

- **The MASQUE endpoint generator produced almost nothing but dead h3 nodes.**
  Addresses for h3 (QUIC) were picked across the entire `/24` block, whereas
  they only live on four hosts.

  | | h3 endpoint generation |
  |---|---|
  | Before | roughly a 1% hit rate — one working node out of fifty generated |
  | Now | h3 is taken from its own section, h2 from the whole block; ports expanded to all seven working ones |

  Blocks that live testing on a device found dead were dropped from the pool
  along the way.

</details>

<details open>
<summary><h2>🇷🇺 Русский</h2></summary>

## 🆕 Что нового

### 🧰 Filters — правила обработки подписки

У каждой подписки появилась вкладка **Filters**. Правила применяются к её узлам
на импорте и на каждом обновлении, так что кривой параметр от провайдера чинится
один раз и дальше сам.

Правило — это условия и действие. Условие пишется как `путь оператор значение`:

- **путь** указывает внутрь узла — `tag`, `server`, `server_port`,
  `tls.utls.fingerprint`, `transport.headers.Host` и так далее;
- **оператор** — `contains` (по умолчанию), `equals` или `matches`
  (регулярное выражение), плюс галки **Not** и **Case-sensitive**;
- условий может быть несколько, объединяются по **AND** или **OR**;
- пустой путь = поиск по всему узлу сразу, когда неизвестно, в каком поле
  лежит значение.

Действий два:

| Действие | Что делает |
|---|---|
| **Disable** | прячет подходящие узлы из маршрутизации — в списке они зачёркнуты, как выключенные вручную |
| **Replace** | записывает значение по указанному пути: целиком или заменяя часть текущего; в замене доступны карманы `$1`, `$2`… из групп захвата regex-условия |

Примеры:

```
tag contains ⚡                              → Disable
tls.utls.fingerprint matches ^hello(chrome)_\d+$  → tls.utls.fingerprint = $1
```

Правила работают одинаково для всех форматов подписки — списков
`vless://`/`trojan://`, Xray-JSON, INI/Amnezia, — потому что применяются к уже
разобранному узлу, а не к тексту подписки.

Кнопка **Apply rules** внизу вкладки перезагружает подписку и показывает итог
(«применено N узлов, выключено M»). В редакторе правила есть вкладка
**Matches** — прогоняет правило по узлам и показывает, к каким оно применится и
что именно изменит, ещё до сохранения.

### 🔍 Разбор узла подписки

Короткий тап по узлу в списке подписки открывает его разбор:

| Вкладка | Что показывает |
|---|---|
| **JSON** | как узел выглядит после парсинга — то, что уходит в конфиг |
| **Source** | исходный фрагмент подписки, из которого узел собрался |

Для JSON-подписок у Source есть переключатель **Compact / Extended**: compact
показывает outbound-объект узла, extended — весь элемент, как его прислал
провайдер.

Многие провайдеры отдают подписку одной base64-строкой — над сырым ответом есть
галка **Decode base64**, раскрывающая тело в читаемый вид, тот же, с которым
работает парсер. Галка появляется только когда телу есть что раскрывать, и в
этом случае включена сразу.

### 🔗 Persistent keepalive для WARP

В Advanced-секции визарда ручной регистрации WARP появилось поле **Persistent
keepalive (s)** — для обычного WireGuard и для AWG.

| | Keepalive в ручной регистрации WARP |
|---|---|
| Было | не проставлялся вообще; при простое оператор закрывал UDP-маппинг за 30–120 с, пинг уходил в ошибку, коннект отваливался — лечилось только Rebuild + Reconnect |
| Стало | поле в Advanced, по умолчанию 25 с; `0` или пусто = выключено |

MASQUE поля не касается — там свой QUIC-keepalive.

### 🛰️ MASQUE — ручной endpoint и окно эксперимента

В ручной регистрации MASQUE появилось поле **Endpoint IP** (пустое = адрес
сервера регистрации) и выбор порта; списки портов теперь свои для каждого
транспорта. Пул адресов, по которому генератор подбирает эндпоинты, вынесен на
отдельный экран эксперимента — JSON пула правится прямо там, кнопка **Reset**
возвращает исходный. IPv6-эндпоинты предлагаются только при включённом IPv6:
без маршрута они всё равно мертвы.

---

## 🐞 Исправлено

- **WebSocket-узлы с `?ed=N` в пути не подключались.** Xray-ноды массово задают
  early data хвостом пути (`/api/v2/channel?ed=2560`).

  | | Импорт ws-узла с `?ed=N` |
  |---|---|
  | Было | хвост уезжал в конфиг дословно, ядро запрашивало путь вместе с `?ed=2560`, сервер отвечал **404** — узел выглядел мёртвым |
  | Стало | хвост срезается, значение переносится в параметр early data ядра |

  Работает для всех путей импорта — ссылок, Xray-JSON и sing-box-JSON. Для
  httpupgrade хвост тоже срезается (поля early data в ядре у него нет). При
  экспорте узла обратно в ссылку `?ed=N` возвращается на место.

- **Генератор MASQUE-эндпоинтов давал почти одни мёртвые узлы по h3.** Адреса
  для h3 (QUIC) подбирались по всему блоку `/24`, тогда как живут они лишь на
  четырёх хостах.

  | | Генерация h3-эндпоинтов |
  |---|---|
  | Было | попадание около 1% — из полусотни сгенерированных узлов работал один |
  | Стало | h3 берётся из своей секции, h2 — по всему блоку; порты расширены до всех семи рабочих |

  Заодно из пула убраны блоки, которые боевой тест на устройстве признал
  мёртвыми.

</details>

---

## 📲 Install

```bash
adb install -r LxBox-v2.17.0-arm64-v8a.apk
```

No uninstall needed — installs over the existing app, settings and
subscriptions are preserved.

Без uninstall! Поверх существующей установки. Настройки и подписки сохранятся.

---

Previous release / Предыдущий релиз: [v2.16.0](docs/releases/v2.16.0.md).
