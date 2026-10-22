# 670 — Галка «Register detour in auto group» мертва с §125; галки detour у папки без звеньев

| Поле | Значение |
|------|----------|
| Статус | Done |
| Дата начала | 2026-10-23 |
| Дата конца | 2026-10-23 |
| Коммиты | d83975c3, b9a31199 (`git log --grep 670`) |
| Связанные спеки | [features/006-DETOUR_AND_BALANCE/FUNCTIONS/source-detour-policy.md](../features/006-DETOUR_AND_BALANCE/FUNCTIONS/source-detour-policy.md); [125](125-direction-auto-twin-from-selector.md); [239](239-folder-detour-links.md); [565](565-source-replace-group.md) |

## Проблема

GitHub issue #171 п.8: «Both of "register detour" options in the folder settings
don't seem to work? Not sure what's supposed to happen».

У источника/папки две галки политики detour, обе по умолчанию off:
«Register detour servers» (звенья цепочек становятся выбираемыми выходами в
селекторах направлений) и «Register detour in auto group» (звенья попадают в
`<tag>-auto`). Вторая не делает ничего.

## Диагностика

- Гейт «что такое detour-сервер»: `app/lib/services/builder/server_list_build.dart:249-269`
  — (а) нативное звено из конфига провайдера (`detours`, `:266`), (б) тег с
  префиксом `⚙` (`kDetourTagPrefix`, `:249`), (в) член папки, которого другой
  член **той же** папки использует личным detour (`FolderDetourPlan.isChainLink`,
  `:501, :535-537, :564`). Флаги читаются только здесь (`:263-264`, `:267-268`).
- Первая галка: `toSelector` → `ctx.addToSelectorTagList` → `selectorTags`
  (`build_config.dart:572-576`) → звенья в пуле направлений. Работает.
- Вторая галка: `toAuto` → `ctx.addToAutoList` → `autoEntries`
  (`build_config.dart:1314`). **`autoEntries` никто не читает** (только
  `removeWhere` на `:1188/:1206`). С §125 `<tag>-auto` строится из
  `selectorTags` (`memberSets → autoSets`, `:1360-1385, :1403, :1565`). Итог:
  звенья в `-auto` ровно тогда, когда включена первая галка; вторая не влияет.
  Единственное живое место — свёрнутый источник (§565): `foldAuto` →
  `ReplacePlan.autoMembers` (`server_list_build.dart:353`,
  `source_replace_build.dart:205-213`).
- Спека `source-detour-policy.md:43` и подпись в UI «Include detour servers in
  auto-proxy-out urltest» (`subscription_settings_tab.dart:539`) описывают
  поведение, которого нет; `auto-proxy-out` — устаревшее имя.
- Тесты проверяют вызов `addToAutoList`, а не итоговый `-auto`
  (`app/test/builder/auto_group_folder_test.dart:56` и два соседних).
- Папка: блок Detour показывается, если у любого члена есть личный detour
  (`folder_detail_screen.dart:1583-1584`), а звеном считается только detour
  внутри той же папки. Папка, чьи узлы ходят через WARP или узел подписки,
  показывает галки, которые ничего не меняют.

## Решение

Поведение, обещанное спекой и подписью, восстанавливается; UI перестаёт
показывать галки там, где им нечего регистрировать.

### Р1. `<tag>-auto` уважает вторую галку

- При формировании `autoSets` из `memberSets` исключать звенья, которые
  источник/папка добавили в селектор (`toSelector`), но не в auto
  (`!toAuto`). Источник истины — `autoEntries`/`addToAutoList`: звено есть в
  `-auto` ⇔ оно в `selectorTags` **и** зарегистрировано в auto. Обычные узлы
  не затрагиваются.
- Свёртка §565 — поведение не менять (там галка уже работает).
- Матрица: off/off — звенья только хопы; on/off — в селекторе, не в `-auto`;
  on/on — в обоих; off/on — звено не в селекторе ⇒ и не в `-auto`
  (как сейчас; документировать как зависимость второй галки от первой — в UI
  вторая галка неактивна, пока выключена первая).

### Р2. Подпись и видимость

- Подпись второй галки: «Include detour servers in the Direction's auto group»
  (без `auto-proxy-out`). Только английский; l10n-ключ обновить во всех
  языках по правилам `docs/l10n.md`.
- Папка: блок Detour и обе галки показывать только когда есть настоящие
  звенья — `isChainLink` хотя бы у одного члена или нативная цепочка. Условие
  в `folder_detail_screen.dart:1583` сузить до того же предиката, что у
  сборщика.

### Р3. Тесты

- `auto_group_folder_test.dart` и соседи: проверять состав `-auto` в итоговом
  конфиге для четырёх клеток матрицы, а не вызов `addToAutoList`.

### Сделано

- Р1: `build_config.dart:577-585` — `selectorOnlyTags` = записи из
  `selectorEntries` без пары в `autoEntries`; `_buildDirectionGroups`
  вычитает их из `autoSets` (`:1342, :1401`). Регистрация в пулы идёт через
  одну функцию `poolAdmission` (`server_list_build.dart:369`, вызовы
  `:256, :263`) — её же берёт §675 Д3. Свёртка §565 читает `auto` как есть.
- Р2: подпись «Include detour servers in the Direction's auto group»
  (`subscription_settings_tab.dart:550`), ключ переименован в `ru`/`zh`
  `ui.json`; вторая галка неактивна при выключенной первой (`:553`). Папка:
  `folderHasDetourLinks` (`server_list_build.dart:386`, `FolderDetourPlan.hasChainLinks`
  `:602`) — родная цепочка, тег `⚙` или `isChainLink`; передаётся новым
  параметром `hasDetourLinks` (`folder_detail_screen.dart:1601`) и гейтит
  только register-галки (`subscription_settings_tab.dart:275, :330`).
  **Отступление:** радио Detour (`hasDetour`, `:1583`) не сужено — у папки с
  личными detour наружу режимы None / Replace all по-прежнему меняют
  поведение (§237), прятать их значило бы сломать работающее.
- Р3: `app/test/builder/detour_auto_registration_test.dart` — итоговый
  `buildConfig` для четырёх клеток матрицы и предикат папки.

## Проверка

- `flutter test test/builder/detour_auto_registration_test.dart` — 6 тестов,
  All tests passed: off/off → `vpn-1-auto` = [exit]; on/off → `hop` в `vpn-1`,
  не в `-auto`; on/on → в обоих; off/on → ни там, ни там. Папка с detour на
  внешний узел (корень и подписка) → `false`; на члена папки → `true`.
- `ui_check --strict`: 0 failures.

## Docs to update

- `source-detour-policy.md` — семантика второй галки, зависимость от первой,
  условие показа у папки.
- CHANGELOG `[Unreleased]`.
