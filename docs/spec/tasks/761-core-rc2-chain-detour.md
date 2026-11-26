# 761 — ядро v1.14.4-lx.37-rc.2: цепочка как перезапись `detour`, блок `lx.detour`, JSON узла от ядра

| | |
|---|---|
| **Статус** | Done — в develop с пином `v1.14.4-lx.37-rc.2` (26.11, `ebc549ac`); эмулятор проверен; на телефоне не проверено. Сверка с лаунчером (контракт 1.1.184) — ветка `claude/761-launcher-parity`, эмулятор не проверялся |
| **Дата** | 2026-11-26 |
| **Повод** | Пререлиз ядра `v1.14.4-lx.37-rc.2` (вышел 26.11, тег на `4c57babea`) приносит SPEC 165 ядра «Цепочка как перезапись `detour`»: ломающее изменение конфига и API командного клиента |
| **Связанные** | 393 (цепочки), 709 (корневой блок `lx` шаблона), 758 (миграция путей `lx.wg.*` в миксинах), 760 (туннель после первой позиции), 311 (running config); ядро: SPEC 165 (§2, §5), ALGORITHM К5, `docs-lx/lx-chain.md`, `docs-lx/lx-block.md`, `docs-lx/lx-observability.md`; LxBox#233 |

## Docs to update

- `docs/KERNEL.md` — раздел про цепочку (что изменится с rc2); пин не меняется.
- `docs/spec/features/006-DETOUR_AND_BALANCE/FEATURE.md` / `.ru.md`, `FUNCTIONS/hop-chains*`, `FUNCTIONS/chain-editor*`.
- `CHANGELOG.md` (Unreleased).

## Problem

С rc2 ядро:

1. Отвергает при загрузке `strip_evasion`, `strip`, `idle_timeout` в теле `chain`
   (звеньев больше нет; фильтры переехали в `lx.detour.strip`).
2. Отвергает корневой `lx.mtu_align`: теперь `lx.detour.mtu_align`, исключения
   `lx.mtu_align.except` → `lx.detour.except_outbounds`.
3. Само ставит `detour` каждому узлу, до которого цепочка доходит на позиции ≥ 1
   (включая всех членов групп любой вложенности, кроме `direct`/`block`), и
   отвергает такой узел, если у него фиксированный локальный порт (WireGuard
   `listen_port`, Tailscale `listen_port`/`relay_server_port`, OpenConnect
   `dtls_local_port`, ALGORITHM К5). Поля привязки сокета (`bind_interface`,
   `tcp_fast_open`, `routing_mark` и т. п.) под `detour` ядро принимает и
   показывает в `GetOutboundConfig` недействующими (уточнение владельца
   26.11, К5 в текущей ALGORITHM).
3а. Даёт узлу или группе один путь (ALGORITHM К1, решение владельца 26.11).
   Достижимость — по всем членам групп любой вложенности, выбор не важен,
   `direct` и `block` не считаются.
   - **Кольцо** — узел или группа достижимы на позиции 0 и на позиции выше той
     же цепочки (`[A, Направление{A, X}]`), или собственный `detour` узла
     позиции 0 ведёт в узел позиции выше (бывший К6). Ядро своего анализа не
     делает: это обычный цикл `detour`, пользователь увидит апстримную ошибку
     `circular outbound dependency: … <цепочка>#<i> …`.
   - **Конфликт** — узел или группа в двух цепочках на любых позициях (обе
     на позиции 0 тоже) или на двух позициях ≥ 1 одной цепочки; повтор тега.
     Ошибки ядра: «`<тег>` is needed on chain X position i and on chain Y
     position j: one node or group has one path»; повтор — «duplicate
     outbound …: one node or group has one path».
   - Вложенная `chain` — только на позиции 0 (К4); тип `chain-hop` во входном
     конфиге и тег хопа `<цепочка>#<i>`, занятый узлом, — ошибки (К3, П1);
     `rewrite`, трогающий `detour`, — ошибка.
   Понятное объяснение и запрет — задача клиента: ядро весь конфиг не грузит.
4. Добавляет в списки исходящих внутренние хопы типа `chain-hop` с тегами
   `<цепочка>#<i>`.
5. Меняет API `CommandClient`: удалены `GetChains`, `GetChainCloneConfig`;
   новые `GetEffectiveConfig()`, `GetOutboundConfig(tag)` (оба — объект
   `RunningConfig` с `content()`), `GetChainStatus(tag)`;
   `SetChainPositionEnabled` отдаёт только ошибку.

Конфиг, который LxBox собирает сейчас, на rc2 не загрузится, если у пользователя
есть цепочка с любым из ключей п. 1, ненулевой `mtu_align` или узел п. 3.

## Diagnosis

- **Ключи цепочки.** Модель `SourceChain` хранит `idleTimeout`, `stripEvasion`,
  `strip`; их пишут `chainOutboundObject` (`models/source_chain.dart`) и шаг
  `on_hop_required` (`chainHopUnstrips` в `builder/chain_nodes.dart`). Редактор
  цепочки показывает их в блоке Advanced; валидация формы выдаёт
  `stripKeptForHop`. Те же поля ходят через запись `sources[]`
  (`codec/chain_record.dart`), бэкап `lx_backup`, миграцию `legacy_form_v0` и
  Debug API `/chains`.
- **`mtu_align`.** Пишет только `config.lx` шаблона
  (`assets/wizard_template.json`): строка режима, если не `clamp`. `except`
  шаблон не пишет. Хранилище держит имя переменной `mtu_align`, а не путь ядра —
  миграция настроек не нужна. Старый путь может лежать только в миксинах (как в
  758): цель `lx.mtu_align`, объект `mtu_align` внутри `lx` / корня.
- **К5.** LxBox сам эти поля не генерирует, но они приходят в телах: `ListenPort`
  из INI WireGuard, авторский JSON узла, тела подписок. Шаг
  `applyDetourYields` (контракт 1.1.65) снимает `listen_port` только у тел, где
  `detour` уже стоит; узлам позиций ≥ 1 LxBox `detour` не пишет — его поставит
  ядро. Значит, сейчас такой узел в цепочке уронит загрузку всего конфига.
- **Хопы.** Узлы и группы приходят в UI из ядра (`writeOutbounds`,
  `writeGroups`, `getOutbounds`, `getGroups`), `type` — строка типа опции,
  `chain-hop` (`constant/chain_lx.go`). `activeModel` строится из
  `GetRunningConfig` — конфига до перезаписи, хопов там нет. У соединения теги
  `chains`/`detours` без типов.
- **JSON узла.** Вкладка JSON экрана узла (`screens/outbound_view_screen.dart`)
  показывает `widget.json` — тело из собранного приложением конфига. Узла с
  перехваченным `detour` или выровненным MTU он показывает не таким, каким его
  запустило ядро.
- **Kotlin** не использует `GetChains`, `GetChainCloneConfig`,
  `SetChainPositionEnabled` (проверено grep): удаление ручек сборку не ломает.

## Solution

**Ключи цепочки.** В конфиг ядра не пишутся
`idle_timeout`, `strip_evasion`, `strip` — `chainOutboundObject` выпускает только
`tag`, `type`, `outbounds`, `rewrite`. Шаг `on_hop_required` из сборки снят (ключей
`strip` у цепочки нет — снимать нечего), код `stripKeptForHop` из валидации формы
снят. Из редактора цепочки убран блок Advanced целиком (в нём были только эти
три поля). Хранить их тоже перестали — как лаунчер (контракт 1.1.184: «импорт
снимает их, стороны не пишут»; корпус `backup/chains_roundtrip`, `v10_*` ждёт
цепочки без ключей): у `SourceChain` полей нет; запись `sources[]`, старый
бэкап и миграция `legacy_form_v0` ключи принимают (не `unknownKeys`) и
отбрасывают молча; Debug API `/chains` их не читает. Читатель каталога `strip`
(`services/contract/chain_strip.dart`) удалён вместе с каталогом в
`chain.json`. Миграции хранилища нет: запись перепишется без ключей при первом
сохранении источников.

**`mtu_align`.** Шаблон пишет `lx.detour.mtu_align` вместо `lx.mtu_align`
(условие прежнее: режим ≠ `clamp`). Миксины: `migrateLegacyLxDetourMixin`
(`services/mixins/mixin_legacy_lx_detour.dart`) рядом с 758, вызывается из
`Mixin.fromJson` следом за ним:
- цель `lx.mtu_align` → `lx.detour.mtu_align`; значение-объект
  `{mode, except}` → цель `lx.detour`, значение `{mtu_align: mode,
  except_outbounds: except}`; `lx.mtu_align.mode` → `lx.detour.mtu_align`,
  `lx.mtu_align.except` → `lx.detour.except_outbounds`;
- объект у цели `lx` или корня: `mtu_align` уходит в `detour` по тем же правилам;
  значение в `detour` при совпадении сильнее старого;
- идемпотентно, без маркера.
Подсказка переменной в настройках называет новый путь.

**Один путь — копий нет (решение владельца 26.11, одинаково с лаунчером).**
Клиент кольца и конфликты не разводит, а находит и объясняет, что сделать
пользователю. Проверка — `checkChainTakeover` / `applyChainTakeover`
(`services/chains/chain_takeover.dart`), цепочки в порядке объявления,
достижимость по всем членам групп любой вложенности, `direct` и `block` не
считаются (как ядро, `protocol/chain/rewrite.go`; `dns` считается):
- **кольцо** — узел или группа достижимы на позиции 0 и на позиции выше той же
  цепочки; собственный `detour` узла позиции 0 (с переходами по `detour` и
  членам групп) ведёт в узел позиции выше;
- **конфликт** — узел или группа нужны цепочке на позиции ≥ 1 и встречаются ещё
  на другой позиции ≥ 1 той же цепочки или в другой цепочке на любой позиции;
  повтор тега. Общий вход двух цепочек (один узел или Направление на позиции 0
  обеих) — не конфликт. Во втором месте конфликта — цепочка выше по списку,
  выпадает нижняя; выпавшая цепочка мест не занимает;
- вложенная цепочка выше позиции 0, тег хопа `<цепочка>#<i>`, занятый узлом.

Подсказка называет узел или группу, цепочки и позиции (с 1) и что сделать:
«"A" is the entry and also inside "X" at position 2 — make a copy of "X"
without "A" for this position»; если узел стоит позицией сам, а внутри группы
на входе — копию группы входа без него; две позиции ≥ 1 — копию группы верхней
позиции; две цепочки — «"X" is used in chains "C1" (position i) and "C2"
(position j) — make a copy of "X" (and its nodes; WireGuard copies need other
keys) for one of them»; кольцо через `detour` — убрать этот `detour` или
вынести узел из цепочки.

**Сборка.** Цепочка с кольцом или конфликтом (сохранённая раньше или ставшая
такой после обновления подписки) снимается из `outbounds` прямо перед
граф-санитайзером, ссылки на неё он дочищает (FEATURE 006 P8: плохая цепочка
выпадает, конфиг собирается); предупреждение сборки — с той же подсказкой.
`rewrite`, который не объект или трогает `detour`, валит цепочку в
`chainEmitError`.

**Редактор.** Форма гоняет ту же проверку по последнему собранному конфигу,
правленая цепочка — последней: кольцо или конфликт — ошибка
(`ChainIssueCode.onePath`, EN + ru/zh), сохранить нельзя. Повтор и вложенная
цепочка — прежние находки формы.

**Плашка на главном (решение владельца 26.11).** Цепочка, сохранённая до rc2
(типично `[узел, Направление со всеми узлами]`) или ставшая кольцом после
обновления подписки, выпадает при сборке; одного предупреждения сборки мало.
- Проверка — та же, что у редактора: `chainOnePathFailure` и
  `chainOnePathMessage` (`services/chains/chain_form_validation.dart`, вынесены
  из формы), над последним собранным конфигом; сборка списка —
  `findChainTroubles` (`services/chains/chain_trouble_state.dart`). Судятся
  включённые цепочки с двумя позициями и больше; на плашку идут те же отказы,
  что форма называет находкой `onePath` (повтор и вложенная цепочка — нет: их
  форма называет своими находками).
- Когда: при старте и при каждом новом `configModel` (сборка после обновления
  подписки, импорта, правки) или смене источников — `HomeScreen` сверяет
  идентичность снимков и зовёт `ChainTroubleState.refresh`.
- Вид (решение по умолчанию — проще): **одна** плашка рядом с плашкой краша,
  по её образцу (`app_banner.dart`, ключ `chain_trouble`, палитра warning,
  значок `link_off`). Заголовок `Hop chain "<тег>" is not built`; текст —
  подсказка редактора для первой цепочки; если цепочек больше — строка
  `More chains are not built: N.`; кнопка `Open chain` открывает редактор
  первой (`openTagOwner`), сохранение пересобирает конфиг — плашка
  перепроверяется и переходит к следующей; крестик `Dismiss`.
- «Скрыть» — до следующего изменения конфига: в storage (`vars`,
  `dismissed_chain_trouble_stamp`) пишется sha256 от тел собранного конфига и
  найденных цепочек. Пока отметка совпадает с текущей, плашки нет; любая
  правка конфига или цепочек — новая отметка, плашка возвращается, если
  цепочка не исправлена. Переживает перезапуск; конфиг на изменение не
  помечает.

**Порты (К5) — как у лаунчера.** Фиксированный локальный порт (WireGuard/AWG
`listen_port`, Tailscale `listen_port`/`relay_server_port`, OpenConnect
`dtls_local_port`, ненулевой) у узла позиции ≥ 1 или у любого члена группы
там (любая вложенность) — отказ `ChainTakeoverFault.localPort` в той же
проверке `checkChainTakeover`: сборка выбрасывает цепочку с предупреждением,
редактор запирает сохранение (находка `onePath`), плашка главного называет
цепочку. Порт не снимается (шаг `chain_position_yields` удалён). Проверка идёт
до колец и конфликтов, выпавшая так цепочка мест не занимает — порядок
`ChainDetourProblems` лаунчера (код `chain_hop_local_port`). Поля сокета не
трогаются и ошибкой не являются. Текст (EN, ru/zh в `ui.json`):
- узел позицией: `"<узел>" at position <i> of chain "<цепочка>" has a fixed
  local port (<поля>) — remove the port from the node, or put a copy of the
  node without the port at this position.`
- узел в группе: `"<узел>" inside "<группа>" at position <i> of chain
  "<цепочка>" has a fixed local port (<поля>) — remove the port from the node,
  or use a copy of the node without the port in "<группа>".`
Предупреждение сборки — те же слова после `Hop chain "<цепочка>" was dropped:`.

**Ручки (п. 9).** `GetChains`, `GetChainCloneConfig`, `SetChainPositionEnabled`,
`GetChainStatus` LxBox не вызывает (grep по `lib/` и
`android/app/src/main`: совпадений нет, `SettingsStorage.getChains` — хранилище).
Тип `chain-hop` сборка не пишет нигде.

**Хопы.** `isChainHopType(type)` (`vpn/cc_channel/chain_hop.dart`) — по типу,
без учёта регистра. Хопы снимаются в точках декодирования `CcChannel`: поток
узлов, поток групп (члены групп), `getOutbounds`, `getGroups`. Теги хопов из
последнего снимка узлов запоминаются; из `chains`/`detours` соединения снимаются
теги, попавшие в этот набор (по тегу не судим — `#` бывает в тегах подписок).

**JSON узла (решение владельца).** Вкладка JSON берёт узел у ядра:
`CcChannel.getOutboundConfig(tag)` → `CcOutboundConfig` (`tag`, `original`,
`effective`, `changes[]` из `field`/`from`/`to`/`by`, у `by` — `type` и поля
по типу). По умолчанию показан `effective`; переключатель Effective/Original
виден, только если `original` есть (у хопа его нет); под ним список `changes`
строками `field: from → to` и причиной (`by.type` с цепочкой и позицией / типом
узла / режимом). Ответа нет (туннель не поднят, тег неизвестен ядру) — «No data from the
core: …», свой конфиг не подставляется. Кнопки Copy в AppBar по-прежнему
копируют тело из конфига приложения (это форма для вставки в другой клиент, а
не показ) — см. Unresolved. `CcChannel.getEffectiveConfig()` добавлен по образцу
`getRunningConfig`; `activeModel` остаётся на `GetRunningConfig`.

**Kotlin** — отдельный коммит: `BoxCommandClient.getOutboundConfig(tag)` /
`getEffectiveConfig()` по образцу `getRunningConfig` (`content()`, null при
ошибке), `BgCcMethods` (`ccGetOutboundConfig`, `ccGetEffectiveConfig`), список
`toBg(..., long = true)` в `VpnPlugin.kt`. До AAR rc2 не соберётся.

**Пин** не трогается (`libbox.version`, `kCoreBuildTagsPin` = `v1.14.4-lx.37-rc.1`).
Шаги при бампе на rc2:
1. `app/android/libbox.version` и `kCoreBuildTagsPin`
   (`builder/core_chain_capability.dart`) → `v1.14.4-lx.37-rc.2`.
2. javap по `classes.jar` AAR: `CommandClient.getOutboundConfig(String)`,
   `getEffectiveConfig()` → `RunningConfig`, `getChainStatus(String)`;
   отсутствие `getChains`, `getChainCloneConfig`; `setChainPositionEnabled` → `void`.
   Строка `type` хопа в `OutboundInfo`/`GroupItem` — `chain-hop`.
3. `docs/KERNEL.md` — пин, история версий, javap, теги сборки.
4. Rebase ветки на develop, CI (`build-fast`), эмулятор: конфиг с цепочкой
   (WG на позиции 1, группа на позиции 1), `check-config`, экран узла.

**Сверка с лаунчером (контракт 1.1.184, 26.11).** Синк вендоренной копии с
develop лаунчера `ed1e206a` (1.1.184; пин ядра лаунчера — rc.2, `3eaa3715`).
Запросы, которые здесь стояли, лаунчер закрыл: `chain.json` без
`idle_timeout`/`strip_evasion`/`strip` и каталога `strip`, код
`chain_strip_utls_on_reality` снят, коды `chain_detour_conflict`,
`chain_detour_ring`, `chain_detour_ring_detour`, `chain_hop_local_port`,
`chain_hop_tag_taken`, `chain_rewrite_detour`; `core_config.json` — `lx.detour`
с `min_core` rc.2 и новый атрибут `max_core` (у `lx.mtu_align` — rc.2).
Сведено:
- порт на позиции ≥ 1 — ошибка, а не снятие (см. «Порты»);
- редактор называет обе цепочки по тегу, как плашка: у `chainOnePathMessage`
  один текст, параметра `inEditor` нет, строки «here ("…")» / «this chain
  ("…")» из `ui.json` ru/zh убраны (лаунчер 090b6ab3 тоже убрал «here»);
- `dns` при подсчёте мест считается — как ядро (`rewrite.go`: пропуск только
  `direct` и `block`) и лаунчер (`counted`);
- ключи цепочки не хранятся (см. «Ключи цепочки»).
- `max_core`: гарда по `core_config.json` в LxBox нет и не нужно — нота
  реестра: сторона, у которой ядро всегда своё и равно пину (LxBox), таблицу не
  исполняет (grep: файл в `lib/` не читается). Шаблон пишет только
  `lx.detour.mtu_align` (`wizard_template.json`, `config.lx`), обе формы —
  только лаунчеру (его конфиг может исполнить чужое ядро).
- Коды реестра (`chain_hop_local_port` и др.) LxBox не выдаёт — его строки
  цепочек, как и прежде, без кода; карточка предупреждения по коду — не в этой
  задаче.

**Корпус Направлений.** `chain_strip_and_timeout` проходит без пропуска.
`chain_cycle_excluded_from_direction` (`[proxy-out{DE, NL}, NL]`) и
`chain_interrupt_connections` (`[F, A]` и `[A, F]`) лаунчер не менял — и прав
LxBox: по SPEC 165 ALGORITHM К1 первое — кольцо (NL достижим на позиции 0 и 1
одной цепочки, апстримное `circular outbound dependency`), второе — конфликт
(F на входе одной цепочки и на позиции 2 другой — Т11; `placesConflict` в
`rewrite.go`); ядро такой конфиг не грузит. Расхождение — в слое: раннер
лаунчера (`core/config/contract_direction_test.go`) проверяет генерацию
(`GenerateOutboundsFromParserConfig`) до проверки цепочек, а сборка лаунчера
(`applyChainDetourRules`) снимает те же цепочки кодами `chain_detour_ring` /
`chain_detour_conflict`. Раннер LxBox гоняет всю сборку. Оба кейса пропущены
с этой причиной (`_skipChainRc2`); лаунчеру — либо вынести кейсы из корпуса
генерации, либо перевести на пары без пересечений, если флаг/подвычитание
должны проверяться и дальше.

## Risks and edge cases

- `GetEffectiveConfig` отдаёт весь конфиг через Binder процесса `:bg`, как
  `GetRunningConfig`; на очень большом конфиге упрётся в тот же предел (§747).
  Потребителей в UI пока нет.
- Пользователь, выключавший `strip_evasion` ради узла, которому нужен разрез
  ClientHello через цепочку, теряет это без замены: `lx.detour.strip` LxBox пока
  не пишет (дефолт ядра — все четыре фильтра). Настройку `lx.detour` в UI в эту
  задачу не входит.
- Дефолт ядра rc2 снимает фильтры `strip` с любого узла под `detour`, не только
  со звеньев — поведение узлов с обычным `detour` меняется на стороне ядра.
- **Частая форма LxBox теперь ошибка:** `[узел, Направление со всеми
  узлами]` или `[Направление со всеми узлами, узел]` — кольцо. Сохранённая
  раньше такая цепочка после обновления выпадает при сборке; пользователь
  должен сделать копию Направления сам (подсказка это называет).
- Цепочка, ставшая кольцом после обновления подписки (узел добавился в
  Направление), выпадает; об этом говорит плашка на главном (см. Solution).
- Конфиг, собранный до этой правки, уже без порта (его снимала сборка):
  редактор и плашка увидят порт только после следующей сборки.
- Плашка судит по последнему собранному конфигу; пул ссылок позиций строится
  из источников: пока они не загружены, позиция-ссылка на узел папки или
  подписки не разрешается и цепочка не судится (плашка молчит, а не врёт).
- Если проверка клиента что-то пропустит, пользователь увидит тексты ядра из
  Problem п. 3а — весь конфиг не загрузится.
- Проверка в редакторе идёт по последнему собранному конфигу: до первой
  сборки (или при старых данных) она молчит, сборка остаётся последним
  рубежом.
- Если ядро отдаёт `type` хопа в другом виде (`ProxyDisplayName` и т. п.), хопы
  будут видны — проверить при бампе (шаг 2).
- Теги хопов в соединениях снимаются по последнему снимку узлов; пока он не
  пришёл, хоп в цепочке соединения может мелькнуть.
- Direction на позиции ≥ 1 перехватывает всех своих членов глобально: тот же
  узел через другой маршрут пойдёт путём цепочки (поведение ядра).

## Verification

- Плашка выпадающих цепочек: `test/services/chains/chain_trouble_state_test.dart`
  (старая `[A, Направление{A, X}]` — подсказка; Направление на позиции ≥ 1
  двух цепочек — у второй; общий вход — нет; исправленная и выключенная —
  нет; «скрыть» держится при том же конфиге и снимается при изменении) и
  `test/screens/chain_trouble_banner_test.dart` (заголовок и текст, `Open
  chain` открывает первую, крестик, счётчик при двух цепочках). На
  эмуляторе плашка не проверялась.
Не собрано, не проверено. Юниты (по одному файлу):
- `test/builder/chain_emit_test.dart` — `chain` без `idle_timeout`,
  `strip_evasion`, `strip`; `rewrite` на месте.
- `test/builder/lx_block_template_test.dart` — `lx.detour.mtu_align`, старого
  пути нет.
- `test/services/mixins/mixin_legacy_lx_detour_test.dart` — перенос путей,
  объекты, идемпотентность, `Mixin.fromJson`.
- `test/services/chains/chain_takeover_test.dart` — `[A, Направление{A, X}]` и
  `[Dir{A, B}, A]` → выпала с подсказкой, копий нет; общий вход двух цепочек
  (WireGuard) — не конфликт; группа на позиции ≥ 1 в двух цепочках, узел на
  ≥ 1 одной и на входе другой, две позиции ≥ 1 через группы, вложенная chain,
  кольцо через detour, занятый тег хопа → выпала.
- `test/screens/chain_edit/chain_form_validation_test.dart` — `onePath`: WG на
  ≥ 1 другой цепочки и `[home, vpn-1{home, de}]` — ошибка с подсказкой; общий
  вход — нет.
- `test/builder/chain_emit_test.dart` — T9 при фильтре, не берущем выход;
  `[proxy-out, NL]` при фильтре «всё» — цепочка выпала с подсказкой.
- `test/models/source_chain_test.dart` — `rewrite` с `detour` и не-объект.
- Корпус Направлений: см. «Сверка с лаунчером» ниже.
- `test/vpn/cc_outbound_config_test.dart` — разбор ответа `GetOutboundConfig`
  (узел, хоп, мусор).
- `test/vpn/chain_hop_filter_test.dart` — скрытие `chain-hop`.
- Golden `rich_v0.config.json` — у `chain-1` нет трёх ключей.
- Правлены под новое поведение: `test/models/source_chain_test.dart`,
  `test/screens/chain_edit/chain_form_validation_test.dart`,
  `test/screens/chain_edit/chain_edit_screen_smoke_test.dart`,
  `test/contract/direction_corpus_test.dart` (скип кейса).
- Прогнаны по одному файлу (зелёные): все перечисленные выше, плюс
  `golden_config_test`, `mixin_legacy_lx_wg_test`, тесты экрана узла
  (`outbound_view_route_live_test`, `selector_member_pick_test`,
  `path_mtu_island_test`); `ui_check --strict` — 0; `flutter analyze` по
  затронутым файлам — чисто. Полный прогон и сборка — нет (Kotlin не
  соберётся до AAR rc2).

Бамп на rc2 (26.11): пин и `kCoreBuildTagsPin` → `v1.14.4-lx.37-rc.2`, теги
сборки те же. `javap` релизного AAR: `getOutboundConfig(String)`,
`getEffectiveConfig()` → `RunningConfig.content()`, `setChainPositionEnabled`
без результата, `GetChains`/`GetChainCloneConfig` нет — как в Kotlin.
`sing-box check` (darwin-arm64 rc2): `avd_v0.config.json` — ок;
`rich_v0.config.json` (две цепочки) — ок после снятия локальных rule-set и
подстановки валидного ключа shadowsocks (данные фикстуры, не генератор).

Эмулятор 26.11 (AVD `LxBox_a161`, CI build-fast на `ebc549ac`, в
`libbox.so` — `1.14.4-lx.37-rc.2`):
- Конфиг стенда без цепочек собрался и поднялся на rc2.
- Цепочка `[🔥☁️ WARP, 🔥🎭 WARP (MASQUE)]` сохранилась, конфиг принят, узел
  цепочки отвечает (201 мс).
- Вкладка JSON у MASQUE: Effective по умолчанию, `"detour": "chain-1#0"`,
  блок «Changed by the core»: `detour — → "chain-1#0" · chain chain-1,
  position 2`; переключатель Original работает.
- Вторая цепочка с MASQUE на входе: ошибка в редакторе «… is used in chain
  "chain-1" (position 2) and here ("<цепочка>") at position 1 — make a copy …», кнопка
  сохранения неактивна.
- Кольцо `[A, Направление{A}]` в UI не собрать: выбор позиции на стенде
  предлагает только раздел Servers. Покрыто юнит-тестами.
- Стенд убран: цепочки удалены, конфиг пересобран, VPN остановлен.

Смоук rc2 на эмуляторе 26.11 (сборка CI `36678c48`, ядро `1.14.4-lx.37-rc.2`;
скриншоты — в папке заметок сессий, `lxbox-rc2-screens/`):
- Плашка: при старте `Hop chain "chwarp731" is not built` для старых цепочек стенда
  (`ch731` [FB, J730], `chwarp731` [WARP (MASQUE), J730], `chok731` [J730, T731]),
  обе цепочки по имени, «More chains are not built: 1.»; Open chain открывает
  редактор с той же ошибкой; крестик скрывает до изменения конфига и переживает
  перезапуск; после пересборки с новым конфигом плашка вернулась.
- VPN поднимается, трафик идёт (Chrome, HTTP из adb shell, ~5 МБ); пул round_robin:
  View pool со счётчиками, Run URLTest обновил задержки; подписка Liberty
  обновилась; цепочка `[WARP, WARP (MASQUE)]` — 200 мс, вкладка JSON Effective
  (`detour: chain-1#0` + правка ядра) и Original (без `detour`); в Conns трафик пула
  через MASQUE идёт путём цепочки (`🔥☁️ WARP → …`) — поведение rc2.
- Лог ядра: ошибок загрузки нет (OpenConnect стенда, «endpoint is not ready yet» на
  старте, «missing default interface» при смене сети эмулятора).
- Не проверено: карантин/сдвиги пула под отказами; UDP/QUIC-нагрузка; смена Wi-Fi ↔
  сотовая под трафиком; телефон. Кольцо `[A, Направление{A}]` в UI не собрать —
  выбор позиции на стенде предлагает только Servers.

Сверка с лаунчером (ветка `claude/761-launcher-parity`, 26.11), по одному
файлу, зелёные:
- `test/services/chains/chain_takeover_test.dart` — WireGuard с `listen_port` на
  позиции 2 → выпала, порт на месте; Tailscale `relay_server_port` у члена
  группы позиции 2 → `localPort`, подсказка с группой; порт на входе, нулевой
  порт и `bind_interface` — не ошибка; выпавшая по порту цепочка мест не
  занимает; узел типа `dns` в двух цепочках на позиции ≥ 1 — конфликт.
- `test/screens/chain_edit/chain_form_validation_test.dart` — порт: точный
  текст, сохранение заперто; конфликт: обе цепочки по тегу, без «here».
- `test/services/chains/chain_trouble_state_test.dart` — плашка называет
  цепочку с портом.
- После синка 1.1.184: `direction_corpus_test` (28, 2 пропуска с причиной),
  `backup_corpus_test` (без пропусков; до правки ключей цепочки падали 7
  кейсов), `registry_sync_test`, `registry_load_test`,
  `registry_invariant_test`, `registry_dart_refs_test`, `docs_mirror_test`,
  `template_contract_test`, `warning_text_render_test`, `contract_test`,
  `lx_backup_*` (test, roundtrip, v10, sections, group_links),
  `backup_service_test`, `backup_service_legacy_test`, `migrate_storage_test`,
  `migrate_node_links_test`, `golden_config_test`, `chain_emit_test`,
  `source_chain_test`, `record_codec_sources_test`, `chains_storage_test`,
  `chains_handler_test`, `chains_probe_handler_test`, `lx_backup_slice_test`,
  `chain_edit_screen_smoke_test`, `chain_trouble_banner_test`;
  `check_contract_lock.dart` — совпадает; `ui_check --strict` — 0;
  `flutter analyze` по затронутым — чисто. Полный прогон, CI и эмулятор — нет.

## Unresolved / follow-up

- Предупреждение задачи 760 о туннеле на позиции ≥ 1 снято целиком 26.11
  (решение владельца): копий узла в rc2 нет. Справка «detour на позициях ≥ 1
  не действует» больше не говорит «звено» — «позиция после первой».

- Блок Route на вкладке Overview экрана узла строится из конфига до
  перезаписи: у перехваченного узла он, вероятно, покажет собственный
  `detour`, а не хоп цепочки.

- Настройка `lx.detour` (режим `strip`, `except_outbounds`) в UI — не в этой
  задаче.
- Copy в AppBar экрана узла копирует тело приложения, а вкладка показывает тело
  ядра — решить, копировать ли показанное.
- Показ всего конфига через `GetEffectiveConfig` (Debug API `/config/running`,
  экран конфига) — ручка в Dart есть, потребителей пока нет.
- `GetChainStatus` и переключатель позиций в UI — не используются.
- Probe-конфиги (`probe_config.dart`, послойная проба цепочки) шаг К5 не
  проходят — проверить на стенде после rc2.
