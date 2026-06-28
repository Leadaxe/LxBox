# §202 — лечить dangling channel-refs в storage при выключении канала

> **СТАТУС: РЕАЛИЗОВАНО (28.06.2026).** Расширение [§125](../features/125%20configurable-channels/spec.md) F4.5.
> Ветка `feat/configurable-channels-125`. Покрыто тестами
> (`test/migration/channel_heal_refs_test.dart`).

## Контекст / баг

§125 F4.5 деградирует dangling route-ссылки (route_final / custom-rule
`outbound`, указывающие на удалённый/несуществующий канал) **в момент сборки
конфига** (`build_config.dart` схлопывает в `vpn-1`). Это чинит **выхлоп**, но
не **внутреннее состояние**: значения в storage остаются висеть на битом теге.

`_healChannelRefs(tag)` (channels.dart) умеет переписывать storage
(route_final + custom-rule outbound → `vpn-1`), но вызывался **только из
`_deleteChannel`**. При **выключении** канала (`_updateChannel`,
`enabled: true → false`) heal не срабатывал:

- **Удалили канал** → storage чинится ✓
- **Выключили канал** → storage НЕ чинится ✗ → route_final/правило держат тег
  выключенного канала; билдер деградирует только выхлоп, а UI/storage остаются
  с битой ссылкой. Симптом юзера: «надо идти и пересохранять — деградирует
  только UI, а не внутреннее состояние».

## Цель

При переходе канала `enabled: true → false` лечить storage так же, как при
удалении: route_final и custom-rule `outbound`, висящие на этом теге, →
`vpn-1` (неудаляемый fallback).

## Решения (согласованы с юзером 28.06.2026)

1. **Вариант B — лечить storage и на выключение** (не только на удаление).
   Симметрично уже существующей семантике удаления; `vpn-1` — всегда валидный
   fallback. **Необратимо**: повторное включение канала НЕ воскрешает старую
   ссылку (правила привязаны к активной конфигурации; молчаливое «оживление»
   старого тега было бы более сюрпризным).
2. **Триггер — именно переход true → false**, а не любой `_updateChannel`.
   Update выключенного канала (смена label и т.п. при `enabled` уже false) heal
   повторно НЕ запускает (`wasEnabled` guard).
3. **detour оставляем билдеру.** detour-ссылки на выключенный канал деградирует
   `healDanglingDetours` (§172-паттерн) при сборке; detour живёт в нодах
   подписки, а не в `channels[]`-storage — чинить его в channels.dart не к месту.
   Класс бага тот же, но скоуп §202 — только route_final + custom-rule outbound.

## Реализация

| Слой | Файл | Изменение |
|---|---|---|
| storage | `services/settings_storage/channels.dart` `_updateChannel` | `wasEnabled && !channel.enabled` → `_setChannels(flush:false)` + `_healChannelRefs(tag)`; иначе обычный `_setChannels` |
| docstring | `channels.dart` `_healChannelRefs` | «удалён ИЛИ выключен» вместо «удалён» |

`_healChannelRefs` не менялся по сути — он уже kind-aware (Inline/Srs имеют
`outbound`; reject/direct — outbound-значения, не channel-теги, под tag не
подпадут) и атомарен (единый финальный `_save()`).

## Тесты

`test/migration/channel_heal_refs_test.dart` (harness как
channels_migration_test):

- delete канала: route_final + rule outbound → vpn-1 (регресс §125 F4.5).
- disable канала: route_final + rule outbound → vpn-1 в storage; канал остаётся
  в списке (disable ≠ delete).
- повторное включение НЕ воскрешает старую ссылку (Решение B).
- выключение НЕ затрагивает ссылки на ДРУГИЕ каналы (heal матчит только
  выключаемый тег).
- disabled → update без смены enabled НЕ перелечивает (wasEnabled guard).

## Связанные

- [§125 configurable-channels](../features/125%20configurable-channels/spec.md) F4.5 — деградация dangling в билдере (образец heal-логики).
- [§172](172-heal-dangling-detour.md) — healDanglingDetours (detour остаётся за билдером).
- [§201](201-block-outbound-for-channels.md) — block-outbound (та же серия каналов).
