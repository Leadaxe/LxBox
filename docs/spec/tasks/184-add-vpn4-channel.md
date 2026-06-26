# §184 — Четвёртый канал роутинга (VPN ④)

## Что
Добавить 4-й selector-канал `vpn-4` («VPN ④») к существующим `vpn-1..vpn-3`.

## Почему
Пользователю не хватало трёх параллельных selector-групп — нужен ещё один
независимый канал для разнесения трафика по исходящим.

## Архитектурный контекст
Каналы **не** захардкожены списком констант. Они декларируются в
`app/assets/wizard_template.json` → `preset_groups[]` и подхватываются
динамически через `PresetGroup.fromJson()` → `WizardTemplate`. UI
(`RoutingChannelsTab`, dropdown на Home), builder (`_buildPresetGroups`),
srs-cache (итерирует `template.presetGroups`) и `selectorGroupTags` — всё
работает по списку из template, без знания о конкретном числе каналов.

Поэтому основное изменение — одна запись в JSON. Захардкоженный набор тегов
в коде есть **ровно в одном** месте (фильтр group-тегов в node-picker'е) — его
надо расширить, иначе сама группа `vpn-4` попадёт в список как фейковая нода.

## Изменения

| Файл | Что |
|---|---|
| `app/assets/wizard_template.json` | + `preset_group` `vpn-4` после `vpn-3` (selector, label «VPN ④», `default_enabled: false`, `default: direct-out`, `add_outbounds: [direct-out, @auto_proxy_tag]`) — копия `vpn-3` |
| `app/lib/screens/node_filter_screen.dart` | в `groupTags` set добавлен `'vpn-4'` (строка ~104) — чтобы группа не считалась нодой |
| `app/lib/services/builder/build_config.dart` | обновлён doc-комментарий `_buildPresetGroups` (vpn-4 в перечне) |
| `docs/TEMPLATE.md` | `list[4]`→`list[5]`, пример `preset_groups[]` дополнен строкой vpn-4 |

## Что НЕ менялось (динамика подхватывает сама)
- `routing_srs_cache.dart` — итерирует `template.presetGroups`; `vpn-1` остаётся
  required (forced add), `vpn-4` опциональный.
- `routing_group_tile.dart` — `isRequired = tag == 'vpn-1'`; vpn-4 нерэквайр.
- `home_state.selectorGroupTags` — динамический по `ccGroups`.
- `home_controls.dart` dropdown — по `state.groups` (runtime от ядра).
- `build_config.dart:_buildPresetGroups` — `vpn-1` остаётся всегда-активной;
  vpn-4 включается только когда enabled.

## Дефолты vpn-4
- `default_enabled: false` — как vpn-2/vpn-3 (по умолчанию выключен).
- `default: direct-out` — как vpn-2/vpn-3 (пока юзер не выбрал ноду — direct).
- Label «VPN ④» — продолжение ряда ①②③.

## Тесты
Тесты с захардкоженными каналами (`build_config_test`, `pipeline_e2e_test`,
`backup_service_test`, `settings_storage_staging_test`) проверяют наличие
`vpn-1..vpn-3`, а не отсутствие 4-го → не ломаются. Прогнать `flutter test`.
