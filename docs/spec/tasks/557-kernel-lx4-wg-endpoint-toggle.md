# 557 — Ядро v1.14.2-lx.4: вкл/выкл WG/AWG-узла на лету и состояние `disabled`

| Поле | Значение |
|------|----------|
| Статус | **Реализовано** (бамп, биндинг, UI, переприменение). Решения владельца: А1, **Б1** (заменило Б2 26.09.2026). Проверено: javap-дельта, `flutter analyze`, затронутые тесты. **Не снято:** эмулятор, CI — см. «Итог» |
| Дата | 2026-09-26 |
| Ядро | `v1.14.2-lx.4` — fork **SPEC 106** (`SPECS/TASKS/106-WG_ENDPOINT_TOGGLE/` в `../sing-box-lx`): `CommandClient.SetEndpointEnabled(tag, enabled)` → `*EndpointToggleResult{State string}`; новое `endpointState = "disabled"` в `GetOutbounds`. Плюс OpenWrt-инсталлятор (LxBox не касается) |
| Связанные | §535 (lx.1: `endpointState`/`idleSinceSeconds`, `CcEndpointState`), §540 (idle-время в UI), §544 (lx.3, текущий пин), §122 (CommandClient), §283 (отключение узла в подписке — **другая** механика, через сборку конфига), `docs/KERNEL.md` («Gotchas when bumping the version») |

## Зачем

Сейчас WG/AWG-узел можно убрать только правкой конфига: отключить в подписке
(§283) и пересобрать — это reload ядра и разрыв всех соединений. lx.4 даёт
мгновенный runtime-выключатель: узел опускает устройство, рвёт свои
соединения и отвергает дайлы, остальной туннель не трогается. Плюс ядро
теперь отдаёт состояние `disabled`, и LxBox должен его показывать, а не
путать со сном.

## Семантика ядра (SPEC 106, дословно по смыслу)

- `SetEndpointEnabled(tag, false)`: устройство уходит в Down как при idle-сне,
  установленные потоки рвутся, каждый dial/UDP-listen/форвард получает
  `WireGuard endpoint is disabled`. Ничто не будит узел до включения.
- `SetEndpointEnabled(tag, true)`: усыплённое устройство просыпается сразу;
  разобранное или не собранное собирает следующий dial через бюджет сборок.
- Ответ — `State` узла после вызова (те же строки, что `endpointState`).
- Ошибки gRPC: `NotFound` (нет тега), `InvalidArgument` (не WG/AWG),
  `FailedPrecondition` (ядро не запущено, узел закрывается), `Unavailable`
  (пробуждение не удалось, узел спит, следующий dial повторит).
- **Не сохраняется:** reload или apply конфига стартуют все узлы включёнными.
- urltest по выключенному узлу получает ошибку и метит узел недоступным;
  selector, выбравший выключенный узел, теряет трафик — «решает клиент».

## Что сделать

### 1. Бамп пина

- `app/android/libbox.version` → `v1.14.2-lx.4`; `docs/KERNEL.md`: строка
  «The current pin», новая строка таблицы истории (lx.3 перестаёт быть current).
- javap-дельта `classes.jar` lx.3 → lx.4 из **релизных** AAR обеих версий
  (механика — `docs/KERNEL.md`; javap ОДИН раз списком классов). Ожидание:
  аддитивно — класс `EndpointToggleResult` (`getState`/`setState`) и метод
  `CommandClient.setEndpointEnabled(String, boolean)`. Любая иная разница —
  стоп и отчёт. Число классов и строк сигнатур — в строку KERNEL.md.
- AAR sha256 сверить с `SHA256SUMS` релиза, записать в KERNEL.md.
- Новых ключей конфига нет → контракт **не** двигается. Проверить grep-ом по
  `app/contract` и `docs/contract`, что норм, привязанных к `lx.3`, нет; если
  есть — стоп и отчёт, не править контракт односторонне.

### 2. Биндинг

- `BoxCommandClient.kt`: `setEndpointEnabled(tag, enabled): String` (state),
  gRPC-код ошибки пробросить как код `PlatformException`
  (`not_found` / `invalid_argument` / `failed_precondition` / `unavailable`,
  прочее — `error`). Правила биндинга — `project_commandclient_binding`
  (no-throw наружу, single-sink).
- `VpnPlugin.kt`: метод канала `setEndpointEnabled {tag, enabled}`.
- `cc_channel.dart`: `Future<String> setEndpointEnabled(String tag, bool enabled)`;
  `CcEndpointState.disabled = 'disabled'`. `isNotBuilt` **не** трогать:
  `disabled` — не «соберётся при дайле».

### 3. Наблюдаемость

- `disabled` показывать везде, где сейчас выводится `endpointState`
  (`node_list.dart` бейдж/строка узла, `outbound_view_screen.dart`
  `_endpointStateValue`), отдельным видом «Off», не как сон; время простоя
  (§540) для `disabled` не показывать.
- В списке узлов (`node_row.dart`) у выключенного узла в сабтайтле, на месте
  `up`/`sleep`/`down`: `off` цветом `Colors.orange` (как пинг 200–500 мс),
  курсивом, без точки (в сабтайтле уже есть разделитель `•`). Справа вместо
  пинга прочерк `—` (onSurfaceVariant).
- Пинг/urltest по выключенному узлу: не рисовать как сбой узла — вместо
  красного таймаута «Off». Проверить места, где `isNotBuilt` гасит таймаут
  (§535), и добавить туда `disabled`.
- Heartbeat `_refreshEndpointStates` уже тянет состояние; после вызова
  переключателя сразу обновить `endpointStates[tag]` из ответа, не ждать тика.

### 4. Переключатель в UI

- Только для узлов, у которых `endpointState` непуст (ядро отдаёт его лишь
  WG/AWG) и VPN запущен. Для прочих пункта нет.
- Места: переключатель на экране узла (`outbound_view_screen.dart`) и пункт
  «Turn off» / «Turn on» в контекстном меню узла в списке. UI-строки только
  английские, через l10n-словарь, `§NNN` в видимых строках нет.
- Ошибки ядра → snackbar с человеческим текстом по коду.
- Выключать можно любой WG/AWG-узел, в том числе выбранный в selector:
  без блокировок и предупреждений, он ведёт себя как обычный мёртвый узел
  (решение Б).

### 5. Сохранение (решение А)

Держать множество выключенных тегов в `HomeController` и **переприменять его
после каждого (пере)старта ядра** в пределах сеанса VPN (reload после
автообновления подписки, apply из редактора), иначе автообновление молча
включает узел обратно. Тег, которого больше нет в конфиге, выкидывать
(`NotFound` при переприменении — молча). При остановке VPN множество
сбрасывается (решение А).

## Решения владельца (26.09.2026)

- **А1.** Выключатель живёт до остановки VPN и переживает reload/apply
  (переприменение после каждого старта ядра в сеансе).
- **Б.** Выбранный в selector узел выключать можно, без предупреждения:
  узел и сам может перестать работать, выключенный = мёртвый.

## Проверка

- `flutter analyze` чистый по проекту; тесты — только затронутые файлы
  (`cc_channel`, `home_controller`, экран узла), полный прогон — CI-дежурный.
- Эмулятор (сценарий для Sonnet): синтетический WG-узел TEST-NET
  `192.0.2.x` через `PUT /config` + `config_locked=true` (память
  `kernel-bump-emulator-verify`); выкл → `endpointState=disabled` в UI, dial
  даёт ошибку, остальной трафик идёт; вкл → `asleep`/`up`; reload конфига →
  узел остаётся выключенным (решение А); `strings -a lib/arm64-v8a/libbox.so`
  в APK показывает `1.14.2-lx.4`.

## Не делать

- `libbox.version` не коммитить до проверки, что релиз `v1.14.2-lx.4` есть на
  GitHub с AAR (иначе CI `fetch-libbox` падает). Релиз есть на 26.09.2026.
- Контракт, реестр, §283-механику не трогать.

## Итог (26.09.2026)

**Решение Б изменено владельцем на Б1:** выключать можно любой WG/AWG-узел,
в том числе выбранный сейчас в selector; блокировок, подсказки
«Selected in <group>» и предупреждений нет — выключенный выбранный узел
ведёт себя как мёртвый. Пункт «Б2» выше устарел.

**Вид выключенного узла в списке (финальное решение владельца):** в
сабтайтле на месте `up`/`sleep`/`down` — курсивная метка `off` оранжевым
(`Colors.orange`, как пинг 200–500 мс). Точки перед ней нет (в сабтайтле уже
есть серый разделитель `•`, вторая точка путает). Справа вместо пинга —
прочерк `—` цветом `onSurfaceVariant`, без красного таймаута и без `PING…`.
На экране узла строка «Endpoint state» показывает `off`, время простоя для
него не выводится.

**Ядро.** `libbox.version` → `v1.14.2-lx.4`. javap по `classes.jar` из
релизных AAR (один вызов списком): 253 → 254 класса, 3498 → 3512 строк;
дифф ровно `EndpointToggleResult` (`getState`/`setState` + служебное
gomobile) и `CommandClient.setEndpointEnabled(String, boolean)`. sha256 AAR
совпали с `SHA256SUMS` релизов: lx.4
`ddd266242ed236f028faa17942937475221931dda50a06fce031c6136e67fb10`, lx.3
`42474da0956c429b020e12d439b4ae60670b59a6e21d474a87afe633d7ac979c`. Норм
контракта, привязанных к `1.14.2-lx.3`, нет (grep по `docs/contract`;
`1.14.1-lx.3` в `warnings.md` — другая версия). Константа пина в
`test/perf/registry_guard_perf_test.dart` сдвинута на lx.4.

**Биндинг.** `BoxCommandClient.setEndpointEnabled` — no-throw, код отказа из
gRPC-статуса в тексте ошибки gomobile (`code = NotFound` → `not_found` и
т. д., прочее → `error`); `VpnPlugin` `ccSetEndpointEnabled` отдаёт строку
состояния или `PlatformException` с кодом; `CcChannel.setEndpointEnabled`,
`CcEndpointState.disabled` (`isNotBuilt` не тронут).

**Сохранение (А1).** `HomeController._disabledEndpoints`: пополняется при
успешном выключении, переприменяется после захвата снапшота новой сессии
ядра (§311: старт и `reloadVpn`, куда сходятся apply, автообновление
подписки и Debug API), плюс страховка на тике heartbeat'а — узел из
множества, который ядро видит включённым, гасится снова. `not_found` /
`invalid_argument` при переприменении выкидывают тег молча. На спуске
туннеля множество и карты `endpointStates`/`endpointIdleSince` очищаются.
Ответ выключателя сразу пишется в `endpointStates[tag]`.

**UI.** Пункт «Turn off» / «Turn on» в меню узла (только при живом туннеле и
непустом `endpointState`), переключатель «Node enabled» на вкладке Overview
экрана узла (слушает контроллер). Отказ ядра — snackbar с текстом по коду.
Новые l10n-ключи (ru/zh): `off`, `Turn on`, `Turn off`, `Node enabled`,
подпись переключателя и пять текстов ошибок.

**Проверки.** `flutter analyze` — чисто. Тесты: новые
`test/vpn/cc_endpoint_toggle_test.dart` (5) и
`test/widgets/node_row_endpoint_off_test.dart` (5), плюс
`test/widgets/node_row_sick_test.dart` — зелёные.

**Не снято:** эмулятор (сценарий в «Проверке»), сборка Kotlin и полный
прогон — CI; `ui_check`/`hardcoded_check` локально не гонялись. Юнит-теста
на переприменение в `HomeController` нет — контроллер в тестах не
поднимается без native-обвязки; проверка — на эмуляторе.
