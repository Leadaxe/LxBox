# 416 — XHTTP: `uplink_data_placement: header` без режима роняет весь конфиг

| Поле | Значение |
|------|----------|
| Статус | Done |
| Дата старта | 2026-09-03 |
| Дата завершения | 2026-09-03 |
| Коммиты | см. ветку задачи |
| Связанные spec'ы | [tasks/410](410-xhttp-extra-empty-not-clobber.md), [tasks/399](399-xhttp-fields-lost-in-json-branches.md), [tasks/217](217-xhttp-normalize-invalid-params.md), [tasks/169](169-drop-not-fit.md), [docs/GUARDS.md](../../GUARDS.md) |

Жалоба с форума 03.09. Реальный конфиг подписки, тот же хост `media.morphai.cc`,
что и в §410, и та же ошибка ядра — но причина другая.

## Симптом

```
initialize outbound[3]: create client transport: xhttp: v2ray-xhttp:
uplink_data_placement can be header only in packet-up mode
```

Не поднимается **весь** VPN: ядро отвергает конфиг целиком на старте, а не
пропускает один негодный outbound. Пользователю это видно как «сервис не
стартует», при том что виноват один узел из подписки, которого он, возможно,
даже не выбирал.

Узел несёт:

```json
"transport": { "type": "xhttp", "uplink_data_placement": "header", … }
```

`mode` в источнике **отсутствует вовсе**.

## Причина

Ядро (`transport/v2rayxhttp/meta.go`, `normalizeMeta`) принимает
`header`-placement только в режиме `packet-up`. Пустой `mode` эмиттер не
пишет, ядро берёт свой дефолт `auto` — и проверка не проходит.

Отличие от §410: там `mode: packet-up` в источнике **был**, но затирался
пустым значением из `extra`. §410 починил слияние `extra`, и та форма
собирается верно. Здесь чинить нечего — режима нет ни в плоских параметрах,
ни в `extra`, источник его просто не прислал.

История поведения поля:

- §217 — placement вне packet-up сбрасывался на дефолт с жёлтой плашкой:
  узел собирался неправильно, зато конфиг жил.
- SPEC 103 перевёл `uplink_data_placement` в чистый passthrough по эталону Go
  (`xhttpStringFields`: «normalization is left to the core»). Плашка исчезла,
  и негодная форма стала фатальной для всего конфига.

Passthrough как канон верен для полей, на которых ядро роняет **одну ноду**.
Здесь оно роняет конфиг целиком — цена ошибки другая, и §410 уже записал в
«Вне задачи»: «Один узел подписки с `header`-placement и режимом не packet-up
по-прежнему роняет весь конфиг». Эта задача закрывает тот хвост со стороны
приложения (страховка в самом ядре остаётся отдельным предложением).

## Что стало

Guard на **эмиссии** — `XhttpTransport.toSingbox`
([`app/lib/models/transport_spec.dart`](../../../app/lib/models/transport_spec.dart)).
Это единственная точка, где `uplink_data_placement` попадает в конфиг: сюда
сходятся все четыре ветки источника (URI-ссылка, sing-box JSON, Xray JSON,
ручной редактор), обойти её нельзя. Ставить проверку в парсер было бы
недостаточно — каждая ветка строит `XhttpTransport` своим путём, и любой
новый источник guard бы миновал.

Регистр и пробелы нормализуются **только для сверки** — в конфиг значение
уходит дословно, как его написал провайдер.

| Вход | Что делает guard | Предупреждение |
|---|---|---|
| `placement: header`, `mode` пуст | дописывает `mode: packet-up`, placement сохраняет | `XhttpModeForcedPacketUpWarning` (warning) |
| `placement: header`, `mode: packet-up` | ничего не меняет | нет |
| `placement: header`, `mode` иной (`auto`/`stream-one`/`stream-up`) | снимает `uplink_data_placement`, `mode` не трогает | `XhttpParamResetWarning(placementRequiresPacketUp)` (warning) |
| `placement` не `header` (`body`/`auto`/`cookie`) | passthrough как раньше | нет |
| `placement` отсутствует | не касается | нет |

Текст новой плашки:

> XHTTP mode was set to "packet-up": the link asks for header uplink data
> placement, which the core accepts only in that mode (the config would
> otherwise fail to load).

### Почему в одном случае дописываем режим, а в другом снимаем поле

Случаи разные по количеству намерений в источнике.

**Режима нет.** Намерения пользователя насчёт режима не существует. При этом
`header`-placement осмыслен ровно в `packet-up` и больше нигде — источник,
прислав его, фактически режим и подразумевал. Дописать `packet-up` значит
собрать узел так, как ждёт сервер. Альтернатива (снять placement) собрала бы
узел **иначе**, чем сервер: uplink пошёл бы телом вместо заголовка — тихо
сломанное соединение вместо рабочего.

**Режим задан и это не packet-up.** Теперь намерений два, и они противоречат
друг другу. Тут работает §169 «отбрасывать, а не подгонять молча»: подогнать
`mode` под placement значит переписать явное значение провайдера и сменить
узлу wire-протокол — на packet-up меняется вся форма обмена, не один
заголовок. Отбрасываем негодную часть (placement), явный `mode` оставляем
целым, ядро берёт дефолтный placement. Узел остаётся рабочим, если сервер
это допускает; если нет — пользователь видит плашку и знает, что править.

Оба пути помечены предупреждением: поведение изменено против источника,
молча этого делать нельзя.

## Тесты

`app/test/parser/xhttp_test.dart`, группа §416: пять случаев из таблицы выше,
разбор ссылки из жалобы через URI-ветку, нормализация регистра/пробелов и
детерминированность эмиссии (два прогона дают байт в байт одинаковый JSON).

Существующий кейс §127 `session_placement/uplink_data_placement/
uplink_http_method — pure passthrough` поправлен: под-случай
`header` + `stream-up` заменён на `cookie` + `stream-up`. Passthrough для
`uplink_http_method: GET` вне packet-up и для «невалидного»
`session_placement` не тронут — там ядро роняет одну ноду, канон Go остаётся
в силе.

## Docs to update

- [`docs/GUARDS.md`](../../GUARDS.md) — **новый файл**: единый реестр всех
  защит парсера/эмиссии/сборки. Заведён этой задачей (владелец просил список
  в одном месте). Ссылки на него — из `docs/PROTOCOLS.md`,
  `docs/ARCHITECTURE.md`, `docs/DEVELOPMENT_GUIDE.md`,
  `docs/spec/features/026 parser v2/spec.md` и таблицы «Документация» в
  `app/CLAUDE.md`.
- `CHANGELOG.md` — строка в `Unreleased → Fixed`.

## Вне задачи

- **Страховка в ядре.** Предложение из §410 в силе: у `uplink_http_method=GET`
  вне packet-up ядро уже деградирует на POST с варнингом (sing-box-lx
  c0bbb1c55), та же деградация напрашивается для placement. Тогда приложение
  могло бы вернуться к чистому passthrough. Пока ядро роняет конфиг целиком,
  guard на стороне приложения нужен.
## Открытый хвост: красный кейс корпуса

`contract/corpus/uri/vless/xhttp_uplink_header_placement_reset` **падает** —
и это работает ровно так, как задумано раннером, а не как баг.

Кейс несёт `uplinkDataPlacement=header` + `mode=stream-up` и ждёт узел с
placement'ом в конфиге (форма §217 → SPEC 103, чистый passthrough). Guard
теперь placement снимает и ставит `xhttp_param_reset` — конверт не совпадает.

Почему нельзя закрыть на месте:

- `app/contract/` — **вендоренная копия**, источник правды в репозитории
  лаунчера (`tool/sync_contract.sh`), каталог в `.gitignore`.
  `tool/check_contract_lock.dart` (шаг CI) сверяет sha256 дерева с
  `app/contract.lock` и падает на любой ручной правке — проверено:
  и override-файл, и правка `contract/docs/IDENTITY.md` §4a роняют lock.
- `UPDATE_CONTRACT=1 flutter test test/contract/` кладёт нужный
  `<case>.expected.lxbox.json` и делает прогон зелёным, но ровно так же
  роняет lock. Тупик замкнутый: файл обязан приехать из репо лаунчера.
- Раннер спроектирован так намеренно (шапка `test/contract/contract_test.dart`):
  общий `<case>.expected.json` нормативен для ОБЕИХ сторон, и настоящее
  расхождение обязано «доехать красным тестом», а не быть заглушенным
  локальной копией.

Что нужно от стороны лаунчера (по образцу D-097 из §410):

1. Решение контракта на расхождение класса **A** по
   `contract/docs/IDENTITY.md` §4a («warning есть у Dart, у Go запланирован»).
   Формулировка: у Dart `xhttp_param_reset` не только ставит warning, но и
   СНИМАЕТ `uplink_data_placement`, потому что ядро на `header` вне packet-up
   роняет ВЕСЬ конфиг, а не одну ноду; Go пока держит passthrough
   (`xhttpStringFields`).
2. `<case>.expected.lxbox.json` для этого кейса в репозитории лаунчера
   (содержимое = база минус `uplink_data_placement`, плюс
   `warnings: ["xhttp_param_reset"]`).
3. Бамп `contract/VERSION` (сейчас 0.12.7) → `tool/sync_contract.sh` и
   пересчёт `app/contract.lock` на стороне LxBox.

Альтернатива, снимающая расхождение целиком, — страховка в ядре (см. ниже):
тогда passthrough вернётся у обеих сторон и override не понадобится.

## Вне задачи

- **Корпус контракта.** Расхождение с Go-эталоном (`xhttpStringFields` — чистый
  passthrough) осознанное и в ту же сторону, что §410 по `host`/`path`/`mode`:
  Dart защищает конфиг там, где Go этого пока не делает. Кейс «header без mode
  → packet-up» в корпус не заводился — сначала нужно решение по страховке в
  ядре, иначе контракт зафиксирует обходной путь.
- **Device-verify.** Не делалась: стенд занят параллельной задачей. Проверка
  логикой и тестами; форма конфига из жалобы воспроизведена в тесте дословно.
