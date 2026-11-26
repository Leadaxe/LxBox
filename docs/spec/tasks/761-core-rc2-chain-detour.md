# 761 — ядро v1.14.4-lx.37-rc.2: цепочка как перезапись `detour`, блок `lx.detour`, JSON узла от ядра

| | |
|---|---|
| **Статус** | Done — в develop с пином `v1.14.4-lx.37-rc.2` (26.11, `ebc549ac`); эмулятор проверен; на телефоне не проверено |
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

**Ключи цепочки (решение по умолчанию).** В конфиг ядра не пишутся
`idle_timeout`, `strip_evasion`, `strip` — `chainOutboundObject` выпускает только
`tag`, `type`, `outbounds`, `rewrite`. Шаг `on_hop_required` из сборки снят (ключей
`strip` у цепочки нет — снимать нечего), код `stripKeptForHop` из валидации формы
снят. Сохранённое не ломается: модель, запись `sources[]`, бэкап, миграция
`legacy_form_v0` и Debug API продолжают читать и писать поля как есть
(round-trip точный), миграции хранилища нет — поля просто не действуют. Из
редактора цепочки убран блок Advanced целиком (в нём были только эти три поля);
правленое в нём раньше значение остаётся в записи и уходит в бэкап.

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
достижимость по всем членам групп любой вложенности, `direct`/`block`/`dns` не
считаются:
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

**Порты (К5).** `applyChainPositionYields`
(`builder/post_steps/chain_position_yields.dart`) — после плана: у листьев
позиций ≥ 1 снимаются три поля портов, строкой предупреждения
сборки. Поля сокета не трогаются. В предупреждения узла по тегу не кладётся —
у них коды реестра, а кода под это нет (запрос лаунчеру ниже).

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

**Контракт лаунчера (руками не правится, запрос в singbox-launcher).**
- `registry/protocols/chain.json`: снять `idle_timeout`, `strip_evasion`,
  `strip` (каталог `strip` с `on_hop_required`) из `body.fields`, либо пометить
  запрещёнными с rc2; код `chain_strip_utls_on_reality` в `warnings.json` —
  снять.
- `schema/source_chain.schema.json`: те же поля — как сохраняемые, но не
  эмитируемые (или снять).
- `registry/core_config.json`: `lx.mtu_align` — `forbidden` с rc2 (min_core как
  история); новые `lx.detour` и `lx.detour.mtu_align`, `lx.detour.strip`,
  `lx.detour.except_outbounds` с `min_core: 1.14.4-lx.37-rc.2`.
- `registry/vars.json` `mtu_align`: нота — путь `lx.detour.mtu_align`.
- Связь «узел на позиции ≥ 1 цепочки» в реестре: `conflicts` с кодом (по образцу
  `conflicts {with: detour}`, контракт 1.1.65) для WireGuard `listen_port`,
  Tailscale `listen_port`/`relay_server_port`, OpenConnect `dtls_local_port` и
  dial-полей К5 (`dialer.json`); код конфликта перехвата цепочек. Пока их нет,
  LxBox снимает поля без кода.
- Тип `chain-hop`: в реестре не нужен (в пользовательском конфиге запрещён), но
  гард сборки не должен принимать его от пользователя.

- Корпус: `chain_cycle_excluded_from_direction` (`[proxy-out, NL]` при
  proxy-out со всеми узлами — кольцо) и `chain_interrupt_connections`
  (`[F, A]` и `[A, F]` — конфликт) — по новым правилам цепочка выпадает;
  обновить ожидания (тот же алгоритм в лаунчере).
- Корпус `corpus/direction/chain_strip_and_timeout.expected.json` ждёт
  `idle_timeout` / `strip_evasion` / `strip` в выпущенной цепочке — обновить
  ожидание; до этого кейс пропущен в `test/contract/direction_corpus_test.dart`
  (`_skipChainRc2`).

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
  Направление), выпадает молча для маршрута — только предупреждение сборки.
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

Не собрано, не проверено. Юниты (по одному файлу):
- `test/builder/chain_emit_test.dart` — `chain` без `idle_timeout`,
  `strip_evasion`, `strip`; `rewrite` на месте.
- `test/builder/lx_block_template_test.dart` — `lx.detour.mtu_align`, старого
  пути нет.
- `test/services/mixins/mixin_legacy_lx_detour_test.dart` — перенос путей,
  объекты, идемпотентность, `Mixin.fromJson`.
- `test/builder/chain_position_yields_test.dart` — порты сняты у листьев
  позиций ≥ 1 через группы, поля сокета остались, позиция 0 не трогается.
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
- Корпус Направлений: кроме `chain_strip_and_timeout` пропущены
  `chain_cycle_excluded_from_direction` и `chain_interrupt_connections` —
  без пропуска падают (проверено): по новым правилам цепочка выпадает, а
  ожидание держит её (запрос лаунчеру).
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
  "chain-1" (position 2) and here at position 1 — make a copy …», кнопка
  сохранения неактивна.
- Кольцо `[A, Направление{A}]` в UI не собрать: выбор позиции на стенде
  предлагает только раздел Servers. Покрыто юнит-тестами.
- Стенд убран: цепочки удалены, конфиг пересобран, VPN остановлен.

## Unresolved / follow-up

- Предупреждение редактора цепочки из задачи 760 («Not recommended: positions
  … are tunnels … the chain dials a copy of the node with the same keys …»)
  описывает механизм звеньев, которого в rc2 нет: узел на позиции ≥ 1 один,
  с перезаписанным `detour`. Текст устарел — решение владельца, править в 760.

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
- Запросы лаунчеру из Solution — после выхода rc2.
