# L×Box v2.25.16

**A patch on top of [v2.25.15](https://github.com/Leadaxe/LxBox/releases/tag/v2.25.15).**

The JSON editor can wrap long lines again: a button next to search, off by
default. A sideways swipe over a long line now scrolls the text instead of
switching the tab, and the selection magnifier shows the text under the
finger. Subscriptions pick up the provider's `announce` description and take
their tag prefix from the emoji in their name; the screen no longer freezes
after start with large subscriptions. Core `v1.14.3-lx.18` and
contract 1.1.119 are unchanged.

**Патч поверх [v2.25.15](https://github.com/Leadaxe/LxBox/releases/tag/v2.25.15).**

Редактор JSON снова умеет переносить длинные строки: кнопка рядом с поиском,
по умолчанию выключена. Свайп вбок по длинной строке теперь прокручивает
текст, а не переключает вкладку, а лупа выделения показывает текст под
пальцем. Подписки показывают описание провайдера из `announce` и берут
префикс тегов из эмодзи в названии; экран больше не замирает после старта
с большими подписками. Ядро `v1.14.3-lx.18` и контракт 1.1.119
без изменений.

---

<details open>
<summary><h2>🇬🇧 English</h2></summary>

## ✨ New

- **Line-wrap button in the JSON editor ([task 649](docs/spec/tasks/649-json-view-wrap-toggle.md)).**
  The Config editor and the read-only JSON views with sticky headers
  (subscription **Source**, node **JSON**) have a wrap button next to search.
  Wrapping is off by default, the button is highlighted while it is on, and
  the choice is not saved: the screen opens again without wrapping. While
  wrapping is on there are no sticky headers — the editor draws them only for
  unwrapped text. Laying out a very long line takes time; a thin progress bar
  at the top of the field shows while it runs.
- **Subscription description from the `announce` header ([task 648](docs/spec/tasks/648-subscription-announce.md)).**
  Providers send a short text in `announce` (`base64:…` or plain), for example
  a legend for the emoji in node names. It is shown in the subscription header
  under **Expires**: up to 4 lines, a tap expands the whole text. If the header
  is missing, the same key is read from the comments at the top of the body.
- **Tag prefix from the emoji in the subscription name ([task 647](docs/spec/tasks/647-subscription-emoji-tag-prefix.md)).**
  When a new subscription first gets its name and the prefix is empty, the
  emoji group from the name becomes the prefix: `Liberty VPN 🗽` → `🗽`. A
  prefix already taken gets an index: `🗽2`. Existing subscriptions keep their
  prefixes.
- **Source tab: `base64:` headers decoded ([task 650](docs/spec/tasks/650-source-headers-base64-toggle.md)).**
  Values such as `profile-title` and `announce` are shown as text; the
  `base64` label under the header name switches the line back to the raw
  value. Copy still copies the raw block.

## 🔄 Changed

- **Editor gestures follow the direction of the swipe (task 649).**
  - A sideways swipe over a line that does not fit scrolls the text; the tab
    stays. Where nothing scrolls sideways, the swipe switches the tab as
    before.
  - A vertical swipe scrolls the text. Once the text is at its edge, the next
    swipe in the same direction scrolls the page.
  - With a selection the editor keeps the whole touch, so the handles move in
    any direction.
- **WARP: the eight `8.x` blocks are back in the WireGuard endpoint pool ([task 651](docs/spec/tasks/651-warp-8x-blocks-return.md)).**
  They were removed in June as unreachable; fresh measurements show them
  answering on a par with the other blocks.

## 🩹 Fixed

- **Selection magnifier (task 649).** In the Config editor after scrolling
  down it was a blank white box; in node JSON after moving the page it showed
  lines from another place. It now draws the editor's own text under the
  finger.
- **The screen no longer freezes after start with large subscriptions ([task 652](docs/spec/tasks/652-lazy-rehydration-isolate.md)).**
  Disabled subscriptions are no longer loaded at start: they are read from the
  cache when turned on, opened, or needed for the config. Parsing the cached
  body and the fresh server response runs off the UI thread: updating a
  subscription with 4025 nodes now holds the UI for 0.24 s instead of 1.85 s.

## 🗑 Removed

- **Tailscale node: the "Allow LAN access while using exit node" switch ([task 646](docs/spec/tasks/646-tailscale-remove-lan-access-switch.md)).**
  The core on Android does not apply `exit_node_allow_lan_access`. The local
  network with an exit node goes direct through the **Private IPs** preset.
  The field is still accepted from JSON.

## 🔧 Under the hood

- Core `v1.14.3-lx.18` and launcher contract 1.1.119, unchanged from v2.25.15.
- The Debug API returns `announce` in `/subs`.
- New tests: the wrap button and its state, the progress bar, the gesture
  decision table and the recognizer against horizontal and vertical drags,
  `announce` parsing, emoji prefixes with indexes, `base64` header decoding.

</details>

<details open>
<summary><h2>🇷🇺 Русский</h2></summary>

## ✨ Новое

- **Кнопка переноса строк в редакторе JSON ([задача 649](docs/spec/tasks/649-json-view-wrap-toggle.md)).**
  В редакторе Config и в просмотрщиках JSON с липкими заголовками (**Source**
  подписки, **JSON** узла) рядом с поиском появилась кнопка переноса. По
  умолчанию перенос выключен, включённая кнопка подсвечена, выбор не
  сохраняется: экран открывается снова без переноса. Пока перенос включён,
  липких заголовков нет — редактор рисует их только без переноса. Раскладка
  очень длинной строки считается не сразу; пока она идёт, у верхнего края
  поля видна тонкая полоса прогресса.
- **Описание подписки из заголовка `announce` ([задача 648](docs/spec/tasks/648-subscription-announce.md)).**
  Провайдеры присылают в `announce` короткий текст (`base64:…` или открытый),
  например легенду к эмодзи в именах узлов. Он показывается в шапке подписки
  под **Expires**: до 4 строк, тап раскрывает текст целиком. Если заголовка
  нет, тот же ключ читается из комментариев в начале тела.
- **Префикс тегов из эмодзи в названии подписки ([задача 647](docs/spec/tasks/647-subscription-emoji-tag-prefix.md)).**
  Когда новая подписка впервые получает имя, а префикс пустой, префиксом
  становится группа эмодзи из имени: `Liberty VPN 🗽` → `🗽`. Занятый префикс
  получает индекс: `🗽2`. У существующих подписок префиксы не меняются.
- **Вкладка Source: `base64:`-заголовки расшифрованы ([задача 650](docs/spec/tasks/650-source-headers-base64-toggle.md)).**
  Значения вроде `profile-title` и `announce` показываются текстом; подпись
  `base64` под именем заголовка переключает строку на исходное значение и
  обратно. Копирование блока — как прежде, в исходном виде.

## 🔄 Изменено

- **Жесты редактора идут по направлению свайпа (задача 649).**
  - Свайп вбок по строке, которая не помещается, прокручивает текст; вкладка
    стоит. Где вбок прокручивать нечего, свайп переключает вкладку, как
    раньше.
  - Вертикальный свайп прокручивает текст. Когда текст упёрся в край,
    следующий свайп в ту же сторону листает страницу.
  - При выделении редактор забирает касание целиком, ручки тянутся в любую
    сторону.
- **WARP: восемь блоков `8.x` вернулись в пул адресов WireGuard ([задача 651](docs/spec/tasks/651-warp-8x-blocks-return.md)).**
  В июне их убрали как недоступные; свежие замеры показывают, что они
  отвечают наравне с остальными блоками.

## 🩹 Исправлено

- **Лупа выделения (задача 649).** В редакторе Config после прокрутки вниз
  она была пустой белой; в JSON узла после сдвига страницы показывала строки
  из другого места. Теперь она рисует текст самого редактора под пальцем.
- **Экран не замирает после старта с большими подписками ([задача 652](docs/spec/tasks/652-lazy-rehydration-isolate.md)).**
  Выключенные подписки на старте больше не загружаются: они читаются из кэша,
  когда их включают, открывают или они нужны для сборки конфига. Разбор
  кэша и свежего ответа сервера идёт вне потока интерфейса: обновление
  подписки на 4025 узлов держит интерфейс 0,24 с вместо 1,85 с.

## 🗑 Удалено

- **Узел Tailscale: переключатель «Allow LAN access while using exit node» ([задача 646](docs/spec/tasks/646-tailscale-remove-lan-access-switch.md)).**
  Ядро на Android поле `exit_node_allow_lan_access` не применяет. Локальная
  сеть при выходном узле идёт напрямую через пресет **Private IPs**. Поле
  по-прежнему принимается из JSON.

## 🔧 Под капотом

- Ядро `v1.14.3-lx.18` и контракт лаунчера 1.1.119 — без изменений с v2.25.15.
- Debug API отдаёт `announce` в `/subs`.
- Новые тесты: кнопка переноса и её состояние, полоса прогресса, таблица
  решений жестов и распознаватель против горизонтального и вертикального
  drag, разбор `announce`, эмодзи-префиксы с индексами, расшифровка
  `base64`-заголовков.

</details>

---

## Install / Установка

```bash
adb install -r LxBox-v2.25.16-arm64-v8a.apk
```

Без uninstall! Поверх существующей установки. Настройки и подписки сохранятся.

No uninstall needed — install over the existing one. Settings and subscriptions
are preserved.

---

Previous release / Предыдущий релиз: [v2.25.15](docs/releases/v2.25.15.md).
