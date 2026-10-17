# §662 — Единая карточка соединения: Conns и профайлер

| Поле | Значение |
|------|----------|
| Тип | Доработка фич [012-LIVE_STATE](../features/012-LIVE_STATE/FEATURE.ru.md) (Conns) и [028-TRAFFIC_PROFILER](../features/028-TRAFFIC_PROFILER/FEATURE.ru.md) (лента Live), предложение владельца 17.10.2026 |
| Статус | I (implemented): решения 1–4 согласованы владельцем 17.10.2026 как рекомендовано; CI и эмулятор — ждут |
| Дата | 2026-10-17 |
| Связанные | §152 (карточка Conns), §160 (карточка события), §044 (строка App), §204 (общая секция Routing), §661 (Source / Inbound) |

## Проблема

Карточек соединения две, и делают они одно и то же:

- `connection_detail_sheet.dart` (§152): тап по строке в Stats → Conns,
  источник `CcConnection`;
- `traffic_event_detail_sheet.dart` (§160): тап по событию в ленте
  профайлера, источник `TrafficEvent`.

Общая у них только секция Routing (`routingRows`, §204). Каркас (ручка,
заголовок, футер), группы, строки, копирование — две копии примерно по
400 строк, и они разъехались: разный порядок групп, разные подписи, иконка
приложения есть только у одной. Любое новое поле (§661 Source/Inbound)
приходится добавлять дважды и следить, чтобы совпало.

## Решение

Одна карточка: один каркас, одни общие секции в одном порядке, одно
поведение строк. Модели `CcConnection` и `TrafficEvent` **не сливаются**:
у них разные источники и жизненный цикл (живое соединение / записанное
событие). Между моделью и карточкой встаёт адаптер.

### Устройство

```
CcConnection ──fromConnection──┐
                               ├──► ConnectionDetailData ──► ConnectionDetailSheet
TrafficEvent ──fromEvent───────┘        (общие поля)           (каркас + общие секции
                                                                 + слоты своих секций)
```

- `ConnectionDetailData` — плоский набор полей карточки (все строки, пустые
  скрываются): заголовок, бейджи, app, source, destination, network,
  routing, traffic, timing, id, JSON для копирования.
- Два фабричных конструктора: `ConnectionDetailData.fromConnection(conn,
  closed:, oneWay:)` и `ConnectionDetailData.fromEvent(event)`.
- `showConnectionDetailSheet(context, data, {onSearchKey, onClose,
  extraSections})` — один вход для обоих экранов.
  - `onSearchKey` есть (профайлер) → Host, Address, App открывают поиск, как
    сейчас в профайлере; нет (Conns: поиска там нет) → эти строки копируют.
  - `onClose` есть (Conns, соединение живое) → в футере кнопка Close.
  - Свои секции подключаются слотами (см. ниже), общий код о них не знает.
- Файлы: `lib/screens/connection_detail/` — `detail_data.dart` (модель и
  адаптеры), `detail_sheet.dart` (каркас, общие секции, строки). Старые два
  файла удаляются, вызовы в `connections_screen.dart` и
  `trace_explorer.dart` переходят на новый вход.

### Свои секции (остаются у одной карточки)

| Карточка | Что | Где в карточке |
|---|---|---|
| Conns | Плашка «One-way traffic» (§153) | слот сверху, до групп |
| Conns | Кнопка Close | футер, рядом с Copy JSON |
| Профайлер | Группа DNS (Record, CNAME, DNS server, Group, Attempts, Group mode, Source ответа) | слот после Destination |
| Профайлер | Confidence, Matched via, Shown because | строки в конце группы App |
| Профайлер | Группа Issues | слот после Timing |

## Было / станет

### Каркас

| Элемент | Conns — было | Профайлер — было | Станет (обе) |
|---|---|---|---|
| Иконка в заголовке | `Icons.link` | иконка приложения 20×20, без приложения `Icons.apps` | иконка приложения, без приложения `Icons.apps` |
| Заголовок | `host:port` или destination, пусто → `(connection)` | `host:port` или ip, пусто → `(event)` | `host:port` (host = домен, иначе адрес); пусто → `(connection)` у Conns, `(event)` у профайлера |
| Бейдж протокола | нет | `DNS` / `TCP` / `TCP·` / `UDP`, цвет по виду события | есть у обеих. Conns: `TCP` / `UDP`, закрытое — `TCP·` / `UDP·` цветом `outline`, как закрытые в профайлере |
| Бейдж `One-way` | есть | нет | только Conns (у события признака нет) |
| Бейдж `closed` | есть | нет (закрытие показывает `TCP·`) | бейдж `TCP·` / `UDP·` и рядом словами `TCP closed` / `UDP closed` — у обеих карточек. Точка — наше обозначение из ленты, стандартом не является; подпись учит её читать (решение владельца 17.10.2026) |
| Футер | Copy JSON + Close | Copy JSON | Copy JSON; Close — если передан `onClose` |
| Copy JSON | 9 полей (`id`, `network`, `domain`, `destination`, `rule`, байты, время) | весь `event.toJson()` | Conns: все поля `CcConnection` (+ chains, detours, outbound, outboundType, protocol, process, source/inbound); профайлер: как было |

### Порядок групп

| Было — Conns | Было — профайлер | Станет |
|---|---|---|
| (One-way) | — | (One-way) — Conns |
| App | Source | **App** |
| Source | Destination | **Source** |
| Destination | DNS | **Destination** |
| Network | Network | (DNS) — профайлер |
| Routing | App | **Network** |
| Traffic | Routing | **Routing** |
| Timing | Traffic | **Traffic** |
| ID | Timing | **Timing** |
| — | Issues | (Issues) — профайлер |
| — | Raw | — |
| — | — | **ID** |

Логика порядка: кто → откуда → куда → как → сколько → когда.

### Строки

| Группа | Conns — было | Профайлер — было | Станет |
|---|---|---|---|
| App | Process (путь), Package — текстом | одна строка: иконка + имя + package, тап → поиск | строка иконка + имя + package (тап → поиск, без поиска → копирует package); ниже Process — путь процесса, если он есть и не совпадает с package |
| App (профайлер) | — | Confidence, Matched via, Shown because | без изменений, в конце группы |
| Source | Source, Inbound, Inbound type | Source, Inbound | Source, Inbound, Inbound type (событие начинает нести `inboundType`) |
| Destination | Host, Destination (`адрес:порт`), Dest port | Host, Dest IP, Dest port | Host, **Address**, **Port**. Conns: Address = хост-часть `destination` (там может быть и домен, поэтому не «IP»). Строка `Destination` (`адрес:порт`) уходит — повтор заголовка и двух соседних строк |
| Network | Network, Protocol | Network, Kind | Network, Protocol (событие начинает нести `protocol` — сниф ядра: tls/http/quic), Kind — только у события |
| Routing | `routingRows` | `routingRows` | без изменений (уже общая) |
| Traffic | Upload, Download | Upload, Download, только если байты есть | Upload, Download, только если байты есть |
| Timing | Started, Duration (живое — до сейчас) | Started, Duration | без изменений |
| ID | ID | — (поле `connId` есть, но не заполняется) | ID у обеих: профайлер начинает заполнять `connId` из `CcConnection.id` |
| Raw | — | Log (`rawLogLine`) | убирается: поле не заполняется с §180 (§219 DORMANT). Поле в модели остаётся ради старых дампов |

### Поведение строк

| | Conns — было | Профайлер — было | Станет |
|---|---|---|---|
| Тап по Host / Address / App | копирует | поиск в ленте, карточка закрывается | поиск, если экран его даёт (`onSearchKey`); иначе копирует |
| Тап по остальным | копирует | копирует | копирует |
| Пустые строки и группы | скрыты | скрыты | скрыты |

## Изменения в данных профайлера

`TrafficEvent` начинает нести три поля, которые в `CcConnection` уже есть:

- `connId` — из `c.id` (поле было, не заполнялось);
- `protocol` — из `c.protocol`, в `toJson` ключ `protocol`;
- `inboundType` — из `c.inboundType`, только для нестандартного входа
  (как `source`/`inbound`, §661), ключ `inbound_type`.

Все три копируются в `copyWith` и в `_ConnSnapshot` (для события
закрытия). Старые записи без них читаются как раньше (пустые строки
скрываются).

## Не делаем

- Не сливаем `CcConnection` и `TrafficEvent`.
- Не добавляем поиск в Conns.
- Не меняем строки списков (Conns, Overview, лента Live) — только карточку.
- Не трогаем секцию Routing: она уже общая.

## Решения (согласованы 17.10.2026)

Владелец уточнил: в Destination остаются Host, Address и Port; уходит только склейка `адрес:порт`.

1. **Порядок групп** — App первой (как в Conns), а не после Network (как в
   профайлере). Рекомендую App первой: заголовок уже с иконкой
   приложения, группа App сразу под ним.
2. **Бейдж `closed` в Conns** заменяется бейджем протокола `TCP·`/`UDP·`.
   Рекомендую: один язык с профайлером. Альтернатива — оставить `closed`
   словом рядом с бейджем протокола.
3. **Строка `Destination` (`адрес:порт`) в Conns уходит** в пользу
   Address + Port. Рекомендую: повторяет заголовок.
4. **Группа Raw** уходит из карточки профайлера. Рекомендую: она пустая с
   §180.

## Проверка

- Точечный тест адаптеров: `test/screens/connection_detail_data_test.dart`
  — `fromConnection` и `fromEvent` на одних данных дают одинаковые общие
  поля (app, source, destination, network, routing, traffic, id).
- Эмулятор: открыть карточку в Conns и в профайлере на одном соединении —
  группы и подписи совпадают, у Conns есть One-way/Close, у профайлера
  DNS/Issues/Confidence.
