# 761 — ядро v1.14.4-lx.37-rc.2: цепочка как перезапись `detour`, блок `lx.detour`, JSON узла от ядра

| | |
|---|---|
| **Статус** | In progress — ветка `claude/761-core-rc2-chain-detour`, ждёт rc2; не собрано, не проверено |
| **Дата** | 2026-11-26 |
| **Повод** | Пререлиз ядра `v1.14.4-lx.37-rc.2` (ещё не вышел) приносит SPEC 165 ядра «Цепочка как перезапись `detour`»: ломающее изменение конфига и API командного клиента |
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
   `dtls_local_port`) или поля привязки сокета из ALGORITHM К5: `bind_interface`,
   `inet4_bind_address`, `inet6_bind_address`, `bind_address_no_port`,
   `protect_path`, `routing_mark`, `reuse_addr`, `netns`, `tcp_fast_open`,
   `tcp_multi_path`, `network_strategy`, `network_type`, `fallback_network_type`.
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

**К5.** Новый шаг сборки `applyChainPositionYields`
(`builder/post_steps/chain_position_yields.dart`) после `applyDetourYields`: по
готовому конфигу обходит каждую `chain`, для позиций ≥ 1 собирает листья (узел
позиции или члены групп `selector`/`urltest` любой вложенности, без `direct`,
`block`, `dns` и вложенных `chain`) и снимает у их тел три поля портов и список
К5. Снятие — строкой предупреждения сборки (`Node "<tag>" (chain "<c>"
position <i>): removed …`, позиция с 1, как в прочих сообщениях цепочек);
в предупреждения узла по тегу не кладётся — у них коды реестра, а кода под
это нет (запрос лаунчеру ниже). Тот же обход выдаёт предупреждение о конфликте перехвата
(узел на ≥ 1 в двух цепочках / на двух позициях ≥ 1, или на ≥ 1 в одной и на 0 в
другой): ядро такой конфиг не загрузит, а молча выбрать одну из цепочек сборка
не может. Сборка его не чинит.

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
- Снятие полей К5 молча меняет поведение узла (например, `bind_interface`): под
  `detour` апстрим их и раньше не применял, предупреждение видно в сборке.
- **Конфликт перехвата LxBox только сообщает, ядро конфиг не загрузит
  (К1, К2).** Обычная для LxBox форма попадает сюда же: `[узел A,
  Направление со всеми узлами]` — A достижим на позиции 0 и перехвачен на
  позиции 1 той же цепочки (К2); одно Направление на позиции ≥ 1 двух цепочек
  (К1). FEATURE 006 P8 обещает, что плохая цепочка выпадает, а конфиг
  собирается, — до решения владельца (деградация цепочки в сборке или
  исключение узла из группы) вливать бамп rc2 для таких конфигов небезопасно.
- **К6 не проверяется:** узел позиции ниже со своим `detour` в узел,
  перехваченный на этой или более высокой позиции, — цикл, ошибка загрузки.
  Сборка его не ловит (шаг §760 только предупреждает о `detour` в форме).
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
- `test/builder/chain_position_yields_test.dart` — снятие портов и полей К5 у
  листьев позиций ≥ 1 через группы, позиция 0 не трогается, конфликт перехвата.
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

После rc2: шаги бампа выше, `sing-box check` на golden-конфигах, эмулятор.

## Unresolved / follow-up

- Решение владельца по К1/К2/К6 (см. Risks): деградировать цепочку в сборке
  или оставить ошибку ядра.
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
