# §201 — block-outbound для каналов + route-final

> **СТАТУС: РЕАЛИЗОВАНО (28.06.2026).** Расширение [§125](../features/125%20configurable-channels/spec.md).
> Ветка `feat/configurable-channels-125`. Покрыто тестами (channel/sort/
> special_node_display/channel_groups).

## Контекст

В каждом канале (§125) сейчас есть опция `direct-out` (галка `include_direct` →
прямой выход мимо прокси). Аналогичной опции **block** (дроп трафика) нет.
Ядро `v1.14.0-lx.1-rc.10` block-outbound **поддерживает**
(`protocol/block/outbound.go` регистрирует `C.TypeBlock`) — `{type: block}`
валиден, конфиг не падает.

`block` (outbound type) ≠ `reject` (rule action, `kOutboundReject`): первое —
выбираемый outbound в селекторе/route_final, второе — действие правила. Не путать.

## Цель

Добавить block-outbound `{type: block, tag: "block"}` (без эмодзи, как
`direct-out`) и сделать доступным:
1. **галка** «Include block» в редакторе канала (как `include_direct`);
2. **опция селектора** канала (`if includeBlock → 'block'`);
3. **route-final пикер** — `block` всегда доступен, покрашен **красным** (как
   `reject` в правилах);
4. **fallback пустого канала** — `outbounds: ['block', 'direct-out']`,
   `default: 'block'` (block выбран дефолтом, direct доступен но не выбран);
5. **на главной** в списке нод — иконка `Icons.block` + label «Block»,
   закреплён **сверху** как direct/auto (через specialNodeDisplayForType,
   по `type == 'block'`).

## Решения (согласованы с юзером 28.06.2026)

1. **Тег = `block`** (без эмодзи), как `direct-out`.
2. **Дефолт галки — ВЫКЛ.** В template `add_outbounds` каналов block НЕ
   добавляем — юзер сам включает. Старые каналы → `includeBlock=false`.
3. **block всегда в route-final** (системный, не зависит от каналов), красный.
4. **fallback пустого канала**: block — default-выбор, direct — доступная опция.
5. **На главной — пин сверху** как direct/auto (не отдельный bottom-pin).
6. **Иконка `Icons.block`**, в строке нод нейтральная; красный — только в
   route-final пикере.

## Реализация (1:1 по образцу direct)

| Слой | Файл | Изменение |
|---|---|---|
| const | `config/consts.dart` | `kBlockOutboundTag = 'block'` |
| template | `assets/wizard_template.json` | `config.outbounds += {type: block, tag: block}` |
| модель | `models/channel.dart` | `includeBlock` (bool, `include_block`, default false) + copyWith/json/seedFromPreset |
| билдер selector | `services/builder/build_config.dart` | `if (c.includeBlock) 'block'` в selectorOutbounds |
| билдер fallback | `build_config.dart` | пустой набор → `['block','direct-out']`, `default: 'block'` |
| §200 warning | `build_config.dart` | текст «traffic blocked» вместо «Direct» (пустой канал теперь block) |
| dangling | `build_config.dart` (§125 F4.5) | `block` валидная мишень route_final (не схлопывать) |
| редактор | `screens/channel_edit_screen.dart` | галка «Include block» (_includeBlock state/init/snapshot/isDirty) |
| route-final | `routing_screen.dart` `_outboundOptions` | опция `block` всегда; пометка для красного |
| route-final UI | `routing_screen/widgets/route_final_tile.dart` | block-item красным (как reject) |
| отображение | `screens/home/special_node_display.dart` | `type=='block'` → «Block» + Icons.block |
| пин | `models/home_state.dart` | block пинится сверху (по type из конфига, как direct/auto) |

Валидатор (`validator.dart`) автоматом подхватит тег из `config.outbounds`
(allTags) — отдельных правок не нужно.

## Storage

`Channel` + `include_block` (bool, default false). Миграция не нужна (новое
поле, дефолт false; старые каналы → false через fromJson).

## Тесты

- `channel_test.dart` — round-trip includeBlock, дефолт false.
- `channel_groups_test.dart` — block в selector при includeBlock; fallback
  пустого канала = `['block','direct-out']` + default block; §200 warning текст.
- `home_state_sort_test.dart` — block пинится сверху (type=block).
- `special_node_display_test.dart` — type=block → «Block» + Icons.block.

## Связанные

- [§125 configurable-channels](../features/125%20configurable-channels/spec.md) — include_direct (образец).
- [§200] (этот же файл tasks) — warning пустого канала (текст меняется на blocked).
- [§199] — отображение служебных нод по типу (specialNodeDisplayForType).
