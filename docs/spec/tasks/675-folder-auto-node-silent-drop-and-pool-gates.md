# 675 — Auto-узел папки: молчаливое снятие при пустом составе и дыра в гейтах пула

| Поле | Значение |
|------|----------|
| Статус | Done |
| Дата начала | 2026-10-23 |
| Дата конца | 2026-10-23 |
| Коммиты | см. `git log --grep 675` |
| Связанные спеки | [322F](322F-balancer-node/spec.md); [features/007-NODE_LIST/FUNCTIONS/server-folders.md](../features/007-NODE_LIST/FUNCTIONS/server-folders.md); [568](568-source-replace-group.md); [591](591-detour-to-auto-group-forbidden.md) |

## Проблема

GitHub issue #171 п.9: «"Auto" node created in the folder seems completely
broken». Деталей нет (запрошены). По коду всегда-ломающего дефекта нет, но
есть пути, где узел **молча** пропадает из конфига, и дыра в гейтах пула.

## Диагностика

- Узел — член папки `kind: auto` (`AutoSelectSpec`), собирается во втором
  проходе в `urltest`/`selector` над включёнными членами той же папки
  (`server_list_build.dart:282-339`); режимы состава All / Rule / Explicit
  (`:371-440`).
- **Д1. Молчаливое снятие.** Пустая папка или Rule без совпадений: редактор
  сохраняет (`auto_group_edit_screen.dart:552`), сборка группу не выпускает, и
  для All/Rule — без предупреждения; предупреждение есть только у Explicit
  (`server_list_build.dart:294-302`). Все члены выключены — то же. Итог: узел в
  папке виден, на главном экране его нет, причины нет нигде.
- **Д2. Свёртка Auto.** «Replace with a group» = Auto на той же папке: группа
  папки кладётся только в члены селектора свёртки (`:333-335`, `toSelector`), у
  режима `auto` селектора нет (`source_replace.dart:53`,
  `source_replace_build.dart:205-235`) → узел ни в одну группу не входит,
  недостижим. По замыслу §74 п.3, но без предупреждения в отчёте сборки.
- **Д3. Гейты пула обходятся.** В пул auto-узла попадают звенья цепочек (`⚙`)
  и Tailscale без exit node независимо от политики detour: `resolvedTags`
  заполняется для всех узлов раньше гейтов (`server_list_build.dart:175`
  против `:255-268`). В селекторы направлений те же узлы гейты не пускают.
  Логическое расхождение: один и тот же узел допустим в одной группе и
  недопустим в другой по одному и тому же основанию.
- **Д4. Косметика.** Значки пула ищутся через `tag.endsWith(spec.tag)`
  (`node_list.dart:888, 920-925`), комментарий обещает учёт суффикса
  уникализации; тег с суффиксом `-1` не находится, регэксп значков молча
  берётся по умолчанию.

## Решение

- Д1: предупреждение сборки для All/Rule при пустом составе того же вида, что у
  Explicit (`group_member_dropped`/«auto group 'X' has no members, skipped»),
  плюс в редакторе при сохранении пустого Rule — та же подпись, что уже есть
  для пустой папки.
- Д2: предупреждение сборки «auto group 'X' is unreachable: folder folded as
  Auto» (один раз на группу). Поведение свёртки не менять.
- Д3: пул auto-узла проходит те же гейты, что пул направлений
  (`tailnetOnly` — вон; звенья `⚙`/нативные/`isChainLink` — по политике
  detour источника, как у `toSelector`). Вынести предикат допуска в одну
  функцию и использовать в обоих местах.
- Д4: сравнение по точному итоговому тегу (через ту же карту `resolvedTags`),
  не `endsWith`.
- Ничего из UX папки (кнопки, пункты меню, перенос группы между папками
  §322F:22) не менять.

### Сделано

- Д1: `server_list_build.dart:297-306` — пустой состав называется при любом
  режиме: «Auto node "X" was skipped: it has no members, an empty group would
  stop the VPN core» (у явного — прежняя строка). Редактор:
  `auto_group_edit_screen.dart:398-405` — при кандидатах без совпадений под
  счётчиком «No servers match, the auto node stays out of the config until
  one does» (стиль строки «Folder has no servers yet»), ключ в `ru`/`zh`.
- Д2: `server_list_build.dart:307-313` — при свёртке без селектора
  (`!fold.hasSelector`) «Auto node "X" is unreachable: its source is replaced
  with an Auto group, which does not include auto nodes»; `ctx.warn`
  дедуплицирует. Поведение свёртки прежнее.
- Д3: кандидат пула пишется в `resolvedTags` только при
  `poolAdmission(...).selector` (`server_list_build.dart:264`) — предикат
  §670, один на оба пула. Явный член, отсеянный гейтом, выпадает с
  `group_member_dropped`.
- Д4: сборка отдаёт карту «итоговый тег → spec группы»
  (`EmitContext.noteGroupEmitted`, `server_list_build.dart:323`;
  `BuildResult.groupByEmittedTag`, `build_config.dart:87, :1065`;
  `SubscriptionController.lastEmittedGroupMap`, `subscription_controller.dart:3115`).
  `poolBadgeOf` (`node_list.dart:941`) ищет по ней точный тег, до первой
  сборки — по показанному тегу spec'а (`displayTag(префикс, tag)`), без
  `endsWith`. Карта отдельная от `nodeByEmittedTag` намеренно: туда группы
  положить нельзя — `_collectPresetNodes` сделал бы их узлами обхода пресетов
  (§578), а отказ ядра по тегу группы выключал бы группу.

## Проверка

- `flutter test test/builder/auto_group_folder_test.dart` — 23 теста, All
  tests passed: Rule без совпадений и пустая папка → группы нет, warning;
  свёртка Auto → warning о недостижимости, свёртка Both → без warning; папка
  с `isChainLink`-звеном и Tailscale без exit: при политике off пул = [exit]
  (оба узла эмитированы), при «Register detour servers» = [hop, exit].
- `flutter test test/screens/pool_badge_cache_test.dart` — 8 тестов, All
  tests passed: `Auto-1` находится по карте сборки; суффиксное совпадение
  чужую группу больше не ловит.
- `ui_check --strict`: 0 failures.

## Docs to update

- `322F` — таблица предупреждений, гейты пула; `server-folders.md`.
- CHANGELOG `[Unreleased]`.
