# §609 — Тег цепочки редактируется, как у узлов

| Поле | Значение |
|------|----------|
| Тип | F (доработка) |
| Статус | D (done) |
| Фича | [006-DETOUR_AND_BALANCE](../features/006-DETOUR_AND_BALANCE/FEATURE.md) (hop-chains, chain-editor) |
| Дата | 2026-10-07 |
| Связанные | [594](594-chain-label-removed-tag-only.md) (label снят, тег оставлен неизменяемым), [008-NODE_EDITOR/name-is-tag](../features/008-NODE_EDITOR/FUNCTIONS/name-is-tag.md) |

## Проблема

§594 убрала у цепочки `label` и оставила тег неизменяемым: «переименование —
вне задачи». В итоге осмысленное имя можно дать только при создании, а
ошибку в имени не исправить. Редактор цепочки показывает тег только в
заголовке («Hop chain · chain-1»). В документации фичи 006 по-прежнему
написано «Tag (immutable), Title».

## Решение владельца (07.10.2026)

Отказаться от Title и перейти на редактируемый тег, как у других типов
узлов: одно имя, оно правится в экране, ссылки переписываются.

## Что сделать

**Экран** `chain_edit_screen.dart`:
- Поле Tag тем же виджетом, что у узла (`node_settings_screen.dart:557-567`:
  `TextField` с иконкой метки и `EmojiPickerButton`). Заголовок AppBar
  берётся из поля, как у узла (`node_settings_screen.dart:478`); формат
  «Hop chain · %s» сохраняется.
- Тег входит в `_snapshot` и `_isDirty`.
- Валидация: уже готовые `tagEmpty`/`tagTaken` из
  `chain_form_validation.dart` против `originalTag`. Занятые теги: цепочки
  и Направления (`_requireFreeChainTag`), собственный старый тег не считается
  занятым.
- `new_chain_dialog.dart`: убрать подсказку «System id, cannot be changed
  later» и мёртвые переводы в `assets/l10n/{ru,zh}/ui.json` по `docs/l10n.md`.

**Хранилище** (`services/settings_storage/chains.dart`): новая операция
`renameChain(oldTag, chain)` (или `updateChain` с явным старым тегом).
- Запись меняется **на месте**: место в `sources[]` с ключом `chain:<old>`
  получает ключ `chain:<new>`. Через `_setChains`/`_replaceKind` нельзя:
  переименованная цепочка уедет в конец списка, и цепочки, которые на неё
  ссылаются, окажутся выше неё (`chain_hop_missing`).
- В той же записи на диск переписываются ссылки со старого тега на новый:
  1. позиции других цепочек (`hops`, корневой `NodeLink` с этим тегом);
  2. `CustomRule.outbound`, `varsValues['outbound']`, `route_final`;
  3. корневой `NodeLink` в `overrideDetour` / `FolderMember.detour`;
  4. DNS: `body.detour`, `vars.outbound`.
  Пункты 2–4 из UI цепочку не выбирают, но через Debug API и бэкап могут
  её содержать. Перепись — по образцу `directionRefRetarget`,
  `retargetPresetOutboundVars`, `retargetDnsServerDirectionRefs`
  (`settings_storage/directions.dart:217-280`). Если удобнее, общий
  помощник переименования outbound-ссылок выносится и используется обоими.
- Тег не изменился: поведение `updateChain` как сейчас.

**Debug API** `handlers/chains.dart`: PATCH `tag` больше не отвечает 400
immutable. Он идёт через ту же операцию переименования и ту же валидацию
(`originalTag` = старый тег). Ответ — запись с новым тегом. Обновить help и
`docs/api/` / `027-DEBUG_API/FUNCTIONS/write-operations*.md`.

**Не меняется**
- Фильтры Направлений (regex по тегу): переименование может вывести цепочку
  из пула Направления или ввести её туда. Так и задумано: фильтр работает по
  имени. Предупреждать не нужно.
- Выбор внутри селектора живёт только в ядре (`store_selected` нет), после
  пересборки он сбрасывается на default. Это норма.
- Контракт и схемы (`app/contract`) не трогать.

**Документация**
- `006-DETOUR_AND_BALANCE/FEATURE.md:155`, `FEATURE.ru.md:147`: строка
  «Chain | Tag, Enabled», без immutable и Title.
- `FUNCTIONS/hop-chains*.md:28`: тег редактируется; строка ревизии 9 → 609.
- `FUNCTIONS/chain-editor*.md:27`: поле Tag редактируемое.
- `017-BACKUP_AND_STORAGE/FUNCTIONS/storage-contract*.md:53/54`: `label` у
  `chain` убрать (читается и отбрасывается, §594).
- `docs/ARCHITECTURE.md:902`: «tag/label/enabled» → «tag/enabled».
- CHANGELOG (Unreleased), EN+RU.

## Проверка

- Юнит на операцию переименования: место в `sources[]` сохранилось;
  позиции другой цепочки, правило, `route_final`, detour и DNS-ссылка
  указывают на новый тег; занятый тег (цепочка или Направление) отвергается;
  свой тег свободен.
- Юнит Debug API: PATCH `tag` → 200, затем GET по новому тегу.
- Только затронутые файлы тестов, по одному; полный прогон в CI.
- `flutter analyze` чистый.

## Итог

- **Экран.** В `chain_edit_screen.dart` поле Tag тем же виджетом, что у узла
  (иконка метки, `EmojiPickerButton`, подсказка «Display name in node list»
  уже переведена); заголовок «Hop chain · %s» берётся из поля; тег входит в
  `_snapshot`/`_isDirty`; валидация — готовые `tagEmpty`/`tagTaken` против
  `originalTag`. `SourceChain.copyWith` получил `tag`.
- **Хранилище.** `SettingsStorage.renameChain(oldTag, chain)`
  (`settings_storage/chains.dart`): одна запись `sources[]` целиком, слот
  `chain:<old>` получает новый ключ на месте; в той же записи переписываются
  позиции других цепочек (`retargetChainHopRefs`, `source_chain.dart`),
  корневые `overrideDetour`/`FolderMember.detour` (`retargetDetourRefs`,
  `server_list.dart`), правила, переменные `outbound` пресетов, `route_final`
  и DNS. Для последних общий помощник `_retargetOutboundRefs` вынесен из
  `_healDirectionRefs` (`directions.dart`), удаление Направления ходит через
  него же. Тег не изменился — `_updateChain` как раньше.
- **In-memory зеркало.** `SubscriptionController.syncDetourRefsRetargeted`
  повторяет перепись detour-ссылок в контроллере, иначе следующий
  `_persist()` вернул бы старый тег. Зовут `editChainAndPersist` и Debug API.
- **Debug API.** PATCH `tag` идёт через `renameChain`; рубеж формы
  (`originalTag` = старый тег, тёзка нового тега среди цепочек и узлов
  конфига — занят); пустой тег — 400. Help и `docs/api`, `027` обновлены.
- **Отклонение.** Строка «System id, cannot be changed later» убрана только из
  диалога цепочки: её же показывает `new_direction_dialog.dart` (тег
  Направления неизменяем), поэтому переводы в `assets/l10n/{ru,zh}` живые и
  оставлены.
- **Проверка.** Новые юниты в `test/services/chains_storage_test.dart`
  (группа `renameChain`) и `test/services/debug/chains_handler_test.dart`
  (PATCH `tag` → 200, GET по новому; пустой/занятый → 400) зелёные; прогнаны
  по одному также `chain_edit_screen_smoke_test`,
  `owner_navigation_chain_test`, `detour_direction_resync_test`,
  `direction_heal_refs_test`, `detour_direction_heal_test`. `flutter analyze`
  чистый, `hardcoded_check --strict` 0/0. На устройстве не проверено.
