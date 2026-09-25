# 558 — Переход к цепочке из окна узла не работает

| Поле | Значение |
|------|----------|
| Статус | In progress |
| Дата старта | 2026-09-26 |
| Дата завершения | — |
| Коммиты | — |
| Связанные | §258 (`openTagOwner`), §255 (detour-cycle sheet), §393 (цепочки-источники), §439 (реестр ссылок), §524 (общий список источников) |

## Проблема

Владелец, 26.09.2026: при поднятом туннеле открыть окно узла типа `chain`
(View-экран, `OutboundViewScreen`) и тапнуть по ссылке на саму цепочку, чтобы
перейти к её настройкам в Servers, — переход не происходит. Вместо экрана
всплывает «Source not found in your lists».

## Диагностика

Тап по хопу, участнику или зависимому узлу в `OutboundViewScreen` идёт в
`_onTagTap` → общий переход `openTagOwner` (`lib/screens/owner_navigation.dart`).
Он знает четыре вида владельцев: Направление (по `directionForTag`), папку,
подписку и одиночный сервер. Последние три ищутся через
`ownerOfTag(tag, subController.entries)`.

Цепочки (§393) в `entries` не входят: они хранятся отдельными записями
`kind: chain` в `sources[]`, читаются через `SettingsStorage.getChains()`, а
в конфиге выходят outbound'ом с тегом ровно `SourceChain.tag`
(`build_config.dart`, `'tag': c.tag`). Для тега цепочки `ownerOfTag` возвращает
null, срабатывает `onOwnerNotFound`, и View-экран показывает SnackBar. Тот же
дефект у detour-cycle sheet на Home (§255): если виновник — цепочка, открывается
список Servers вместо цепочки.

Редактор цепочки сейчас открывает только экран Servers (`_editChain` в
`subscriptions_screen.dart`). Сохранение правки (`updateChain`/`deleteChain`,
уведомление о снятых позициях, пересборка конфига) живёт там же, внутри
State экрана.

## Решение (вариант 1, выбран владельцем)

1. **Общий поток правки цепочки** — новый модуль
   `lib/screens/chain_edit/chain_edit_flow.dart`:
   `editChainAndPersist(context, chain, {subController, homeController})`
   собирает входы редактора (directions и chains из storage, lists из
   `subController.entries`, config из `homeController.state.configModel`,
   pool `computeNodeLinkPool`), открывает `openChainEditor`, применяет
   результат (`deleteChain` / `updateChain`) и возвращает итог
   `ChainEditOutcome {deleted, positionsRemoved}` либо null, если пользователь
   ушёл без изменений. Пересборка — вторым общим шагом
   `regenerateSourcesConfig(subController, homeController)` → `bool?`
   (null — конфиг не собран; иначе applied: in-place reload при `canReload`),
   тот же код, что сейчас в `_regenerateAndSave`.
2. **Servers** — `_editChain` переходит на `editChainAndPersist`; экранная
   часть (перечитать источники, SnackBar о снятых позициях, пересборка с его
   SnackBar'ом и подсветкой) остаётся на экране. Поведение не меняется.
3. **`openTagOwner`** — ветка цепочки после ветки Направления и до
   `ownerOfTag`: тег совпал с `SourceChain.tag` → `editChainAndPersist`, затем
   при непустом итоге — SnackBar о снятых позициях и `regenerateSourcesConfig`.
   Параметр `chains` (предзагруженный список, как `directions`); null →
   `SettingsStorage.getChains()`.

## Риски и edge cases

- Коллизия тега цепочки с тегом узла невозможна: `addChain` отвергает занятый
  тег, аллокатор сборки дедуплицирует.
- Servers, открытый ниже в стеке, после правки из View-экрана увидит новые
  хопы только при следующем `_loadSourceOrder` (слушатель контроллера). Не
  чиним: переход из View-экрана открывается поверх Home, не поверх Servers.
- Правка при опущенном туннеле: `canReload` false → только сохранение
  конфига, как в Servers.

## Верификация

- `flutter analyze` чистый.
- Новый widget-тест `test/screens/owner_navigation_chain_test.dart`: тег
  цепочки → пушится `ChainEditScreen`; тег, которого нет нигде, →
  `onOwnerNotFound`.
- Прогон `test/screens/chain_edit/chain_edit_screen_smoke_test.dart` и
  `test/screens/subscriptions_unified_list_test.dart` (затронут `_editChain`).
- CI зелёный.

## Нерешённое / follow-up

—
