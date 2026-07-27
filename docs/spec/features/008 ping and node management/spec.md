# 008 — Ping & Node Management

| Поле | Значение |
|------|----------|
| Статус | Реализовано |

> **§122/§219 — актуализация транспорта.** Пинг нод описан ниже через Clash API
> `/proxies/{tag}/delay` — это выпилено в §122. Реально пинг идёт через libbox
> CommandClient: `CcChannel.urlTestOutbound(tag)` (см. `ping_orchestration.dart`).

## Контекст

MVP (Feature 003) предоставлял только одиночный ping по long-press на ноде. Для удобства управления узлами нужны: массовый пинг, визуальная индикация качества связи, настраиваемые параметры пинга.

## Mass Ping

- Кнопка рядом с селектором группы запускает последовательный пинг всех нод текущей группы через Clash API (`/proxies/{tag}/delay`).
- Во время пинга иконка меняется на Stop — нажатие отменяет процесс.
- Epoch-based counter предотвращает race condition при быстрой отмене и повторном запуске.
- Пинг автоматически останавливается при отключении VPN (`tunnelUp` check в цикле).

## Расширенное Long-press меню (NodeRow)

- **Ping** — одиночный пинг ноды.
- **Use this node** — переключение на ноду.
- **Run URLTest** — только для urltest-группы (auto и т.п.): групповой тест +
  переселект в ядре (см. раздел ниже).
- **Copy outbound JSON** — копирование JSON в буфер обмена.
- Разделитель между действиями и утилитами.

## Run URLTest (urltest-группа)

`runGroupUrltest(tag)` → CC-мост `urlTestGroup` → libbox
`CommandClient.urlTest(groupTag)` (§308). Семантика — **в ядре**:
force-прогон **всех членов** группы + переселект на живой узел + interrupt
зависших соединений группы.

- **Fire-and-forget:** RPC возвращается сразу, без результатов. Новый
  `selected` приезжает groups-стримом (`_applyGroups`), делеи членов ложатся
  в history ядра. Ни `reloadProxies()`, ни bump сортировки после вызова
  не нужны.
- **URL/timeout теста** — из конфига группы (`urltest_url` шаблона + 15s
  ядра), **не** из per-group ping settings (§040). Ручной пинг нод и
  групповой тест могут мерить разными URL — сведе́ние на этапе генерации
  конфига, вне §308.
- Тот же вызов используется хвостом mass-ping (`_runAllUrltestGroups`) и
  Debug API `POST /action/urltest?group=`.
- **Авто-спасение (§308):** фейл единичного «Ping» узла, который сейчас
  выбран urltest-группой, автоматически форсит групповой URLTest этой
  группы — группа слезает с мёртвого узла сразу, не дожидаясь
  interval-тика ядра. Фейл прочих узлов группового прогона не вызывает.

> **История:** с §122 до §308 сюда по ошибке был подключён per-node
> `urlTestOutbound(groupTag)` — один замер сквозь текущий выбор группы, без
> переселекта; группа могла висеть на мёртвом узле до interval-тика ядра.
> Root cause и стенд приёмки — `tasks/308-group-urltest-wrong-rpc-no-reselect.md`.

## Цветовая индикация задержки

- `< 200ms` — зелёный.
- `200–500ms` — оранжевый.
- `> 500ms` или ошибка — красный.
- `null` (не пинговалось) / busy — стандартный цвет.

## Ping Settings

**Status:** Реализовано

### Long-press на кнопке пинга

Long-press открывает bottom sheet с настройками пинга. Tooltip с кнопки пинга удалён.

### Bottom Sheet

```
┌──────────────────────────────────┐
│  Ping Settings                   │
│                                  │
│  URL Presets                     │
│  [Google 204] [Cloudflare] [Apple]│
│  [Firefox] [Yandex]             │
│                                  │
│  Custom URL                      │
│  ┌──────────────────────────────┐│
│  │ http://...                   ││
│  └──────────────────────────────┘│
│                                  │
│  Timeout (ms)                    │
│  ┌──────────────────────────────┐│
│  │ 5000                        ││
│  └──────────────────────────────┘│
└──────────────────────────────────┘
```

Пресеты URL загружаются из `wizard_template.json` секции `ping_options.presets` как `ChoiceChip` виджеты.

## URLTest Configuration

**Status:** Реализовано

Три переменные в `wizard_template.json → vars`:

| Поле | Дефолт | Описание |
|------|--------|----------|
| `urltest_url` | `http://cp.cloudflare.com/generate_204` | URL для проверки доступности |
| `urltest_interval` | `5m` | Интервал проверки |
| `urltest_tolerance` | `100` | Допуск в мс для переключения узла |

Переменные применяются к preset group `auto-proxy-out` через механизм `@var` подстановки.

## Файлы

| Файл | Изменения |
|------|-----------|
| `controllers/home_controller.dart` | `pingAllNodes()`, `cancelMassPing()`, epoch counter |
| `widgets/node_row.dart` | Расширенное long-press меню, `_delayColor()` |
| `screens/home_screen.dart` | Mass ping button, long-press handler, bottom sheet |
| `assets/wizard_template.json` | Секция `ping_options` с пресетами; urltest vars |
| `screens/settings_screen.dart` | URLTest поля |

## Критерии приёмки

- [x] Mass ping проходит все ноды группы, UI обновляется по мере получения результатов.
- [x] Cancel немедленно обновляет иконку кнопки и прерывает цикл.
- [x] Два параллельных цикла невозможны (epoch guard).
- [x] Long-press меню: Ping, Use, Copy JSON — все действия работают.
- [x] Цвет задержки соответствует диапазонам.
- [x] Long-press на кнопке пинга открывает bottom sheet с настройками.
- [x] ChoiceChip пресеты загружаются из wizard_template.
- [x] URLTest url, interval, tolerance настраиваются в VPN Settings.
