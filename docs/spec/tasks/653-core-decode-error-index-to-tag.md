# §653 — Отказ ядра на декодировании: индекс `outbounds[N]` → тег → автоснятие узла

| Поле | Значение |
|------|----------|
| Тип | D (дефект: страховка §478 не срабатывает) |
| Статус | Done (B. LxBox; A — лаунчер) |
| Дата | 2026-10-15 |
| Связанные | §478 (узел, которого не приняло ядро, выключается сам), §642 (контракт 1.1.118, D-129: masque `network` не читается), §577 (авторское тело: мягкие правила не правят), §460 (гард реестра на сборке), ядро SPEC 131 (lx.18: legacy `network` у masque снесён), PARSING_PRINCIPLES §9 |
| Контракт | требуется правка §9.1–§9.3 (лаунчер), версия поднимается лаунчером |

## Проблема

Старые masque-узлы из авторского sing-box-тела несут ключ `network: h2|h3`.
С §642 парсер его не читает, с ядра lx.18 ядро его не знает. При нажатии
Start ядро отказывает, узел **не выключается**, VPN не поднимается, человек
получает ошибку на английском и остаётся без связи — ровно тот сценарий,
ради которого делалась §478.

Дословно (форма `contextjson` из `sing/common/json`, обёртка libbox
`decode config: `, сверху Go `start or reload service: ` и локализованный
шаблон Kotlin, как в §478 Д-1):

```
… start or reload service: decode config: outbounds[12].network: json: unknown field "network"
```

Диагностика — три независимых куска, каждый сам по себе по норме:

1. **Первый эшелон не снимает.** Гард сборки (`registry_gate.dart`) видит
   `network` как `unknown_key`, но у авторского тела мягкое правило тело не
   меняет (§577): `Field removed: unknown key [network=h2] (not applied)`,
   ключ уезжает в конфиг. Проверено юнитом 15.10.2026 на `Outbound(..)
   ..authored = true`. Не дефект §577 — так решено.
2. **Ядро отказывает на ДЕКОДИРОВАНИИ, а не на инициализации.** Форма
   `initialize outbound[i] type[tag]: …` (SPEC 092) появляется, когда конфиг
   уже разобран в структуры. `unknown field` ловится раньше, структуры
   outbound'а ещё нет — тега нет, есть только путь с индексом.
3. **Разбор §478 знает только форму `initialize`.** `parseCoreRejection`
   ищет `initialize ` → `null` → автомат стоит, обычная ошибка.

Текст в `docs/KERNEL.md` (абзац про lx.18) «the node is rejected at start
(the app disables it and starts again, §637)» — **неверен**, написан без
проверки.

## Решение (владелец, 15.10.2026)

Форма ошибки декодирования становится второй нормативной формой §9.1.
Индекс в ней — единственная координата узла и разрешается в тег по
**отправленному конфигу**: массив, который декодировало ядро, — ровно тот,
что приложение записало на диск, порядок тот же. Это не перебор и не
догадка (§9.3 запрещает именно их): сопоставление однозначно. Для формы
`initialize` ничего не меняется — там тег есть и индекс остаётся
диагностическим.

Первый эшелон (стрип `network` у авторского masque) **не трогаем**: §577
стоит, владелец выбрал путь через контракт.

### A. Контракт (лаунчер) — PARSING_PRINCIPLES §9

§9.1, вторая форма:

```
<kind>[<i>](.<path>)?: <text>
```

- `<kind>` — `outbounds` либо `endpoints` (множественное число: это путь
  JSON, а не слово `outbound` из формы `initialize`);
- `<i>` — индекс в массиве отправленного конфига, десятичные цифры. **В этой
  форме индекс несёт нагрузку**: тега в строке нет, и узел находится по
  индексу в массиве `outbounds[]`/`endpoints[]` конфига, который приложение
  отдало ядру;
- `<path>` — необязательный путь внутри тела узла (`network`,
  `tls.server_name`, `transport.type`…), после точки;
- `<text>` — текст декодера (`json: unknown field "network"`, `json: cannot
  unmarshal …`).

Строка приходит обёрнутой: `decode config: ` (libbox), `start or reload
service: ` (Go), локализованный префикс Kotlin. Разбор ищет вхождения
`outbounds[` / `endpoints[` по всей строке слева направо; побеждает первое,
за которым грамматика сходится (цифры, `]`, затем `.` либо `: `) и индекс
попадает в массив отправленного конфига.

§9.3 — дополнение: для формы декодирования сопоставление идёт **индекс →
финальный тег** по отправленному конфигу, дальше «финальный тег → исходный
узел» как и прежде. Индекс вне массива — узел не назван, автоматики нет.

§9.4 — `reason` записи `core_rejected`: `<path>: <text>` (путь внутри тела
без префикса `outbounds[i].`); без `<path>` — просто `<text>`. Пример:
`network: json: unknown field "network"`.

Таблица примеров §9.2 пополняется:

| строка | сопоставление | текст |
|---|---|---|
| `decode config: outbounds[12].network: json: unknown field "network"` | `outbounds[12]` → тег 12-го outbound отправленного конфига | `network: json: unknown field "network"` |
| `decode config: endpoints[0].peers[1].public_key: json: cannot unmarshal …` | `endpoints[0]` | `peers[1].public_key: json: cannot unmarshal …` |
| `decode config: route.rules[3].outbound: …` | — (не про узел) | — |
| `decode config: outbounds[99].foo: …` при 5 outbound'ах | — (индекс вне массива) | — |

Лаунчеру — своя реализация по той же норме (SPEC 132).

### B. LxBox

1. **Теги конфига — с порядком.** `RebuiltConfig` (`core_reject_guard.dart`)
   помимо `tags: Set<String>` получает `outboundTags: List<String>` и
   `endpointTags: List<String>` — финальные теги в порядке массивов
   отправленного конфига. Источник — сам `configJson` (`jsonDecode` →
   `outbounds[].tag`, `endpoints[].tag`, записи без строкового `tag` → пустая
   строка, чтобы индексы не сдвигались). Строит `CoreRejectHostImpl.rebuild`
   (`core_reject_host.dart`), `tags` остаётся как есть.
   Упаковать в один тип `CoreConfigTags {Set<String> all; List<String>
   outbounds; List<String> endpoints;}` и передавать его, а не три поля.
2. **Разбор.** `parseCoreRejection(line, CoreConfigTags)` — сигнатура меняется
   (старые вызовы с `Set<String>` переписать, их два: гард и тесты). Порядок:
   сначала форма `initialize` как сейчас; `null` → форма декодирования по
   §A. `CoreRejection` для неё: `kind` = `outbound`/`endpoint` (единственное
   число, как у первой формы), `index` = `<i>`, `tag` = из массива, `type` =
   `type` записи по тому же индексу из `configJson` — для этого `CoreConfigTags`
   несёт и `outboundTypes`/`endpointTypes` (или список записей `(tag, type)`;
   на вкус исполнителя, но один проход по JSON), `reason` по §9.4.
3. **Автомат** (`core_reject_guard.dart`) не меняется: `_consume` отдаёт
   разбору `CoreConfigTags` вместо `Set`, остальное — как было (повтор по
   `CoreRejectNodeRef`, предел кругов, диалог).
4. **Docs**: `docs/KERNEL.md` абзац lx.18 — убрать ложное «§637», написать
   как есть: с §653 ошибка декодирования называет узел по индексу, узел
   выключается и старт повторяется (§478); `docs/GUARDS.md` — строка в
   разделе второго эшелона/§478 про форму декодирования; докблок
   `core_error_parse.dart` — вторая форма.

## Границы

- Ошибки декодирования вне `outbounds[]`/`endpoints[]` (`route`, `dns`,
  `inbounds`) — как сейчас, обычная ошибка.
- Санитайзер и §577 не трогаем; `network` у авторского masque по-прежнему
  уезжает в конфиг и снимается вторым эшелоном с вердиктом. Это решение
  владельца; если захочется первого эшелона — отдельная задача.
- Эмулятор не трогать (владелец, 15.10.2026): проверка — юниты.

## Проверка

- `app/test/services/core_error_parse_test.dart`: новая группа «§9.1 форма
  декодирования» — таблица §A дословно, плюс: обёртки Go+Kotlin перед
  `decode config:`; `outbounds[` внутри тега формы `initialize` не ломает
  первую форму (строка с обеими — побеждает `initialize`); индекс с
  ведущими нулями/нецифрами → `null`; пустой тег в массиве по индексу →
  `null`.
- `app/test/services/core_reject_guard_test.dart`: поддельный хост отдаёт
  `CoreConfigTags` с порядком; сигнальный старт с ошибкой декодирования на
  `outbounds[1]` → выключен узел с тегом `[1]`, `reason` по §9.4, дальше
  цикл как обычно.
- `test/services/core_reject_host_test.dart` (если есть; иначе юнит на
  функцию извлечения тегов из JSON): `outbounds` без `tag` не сдвигает
  индексы.
- CI зелёный.

## Как сделано

- `core_error_parse.dart`: `CoreConfigEntry(tag, type)` и `CoreConfigTags
  {all, outbounds, endpoints}` с фабрикой `fromConfigJson` (один `jsonDecode`;
  запись без строкового `tag`/`type` → `''`, битый JSON → пустые массивы).
  `parseCoreRejection(line, CoreConfigTags)`: сначала форма `initialize` (по
  `all`), затем `_parseDecode` — вхождения `outbounds[`/`endpoints[` слева
  направо; индекс — цифры без ведущих нулей, в пределах массива, тег по
  индексу непустой; `reason` по §9.4. Решение исполнителя: вхождение, перед
  которым буква/цифра/`_`/`.` (чужой вложенный путь `foo.outbounds[1]`), не
  считается.
- `core_reject_guard.dart`: `RebuiltConfig` несёт `configTags:
  CoreConfigTags`; конструктор с `tags: Set` оставлен (порядка нет — форма
  декодирования молчит), чтобы не трогать поддельные хосты других тестов;
  новый `RebuiltConfig.withConfigTags`. `_consume` отдаёт разбору
  `CoreConfigTags`.
- `core_reject_host.dart`: `rebuild` строит `CoreConfigTags.fromConfigJson(json,
  all: lastEmittedTagMap.keys)`.
- Тесты: `core_error_parse_test.dart` (группы «§9.1 форма декодирования» и
  `fromConfigJson` — отдельного `core_reject_host_test.dart` нет, юнит на
  извлечение тегов там же), `core_reject_guard_test.dart` (`FakeCore.decodeForm`:
  сигнальный старт на `outbounds[1]`, сдвиг индексов после выключения).
- Доки: `KERNEL.md` (абзац lx.18 без ложного «§637»), `GUARDS.md` (строка
  про форму декодирования в разделе feature 478), докблок разбора.
