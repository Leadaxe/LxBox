# §328 — Подсказка «Add a server» при нуле серверов, а не при отсутствии файла конфига

| | |
|---|---|
| Статус | ✅ Реализовано |
| Дата | 2026-07-31 |
| Связанные | [`274 detour-role (снэкбар пустых каналов)`](274-detour-role-to-permission.md), [`283 node-disable`](../features/283%20subscription-node-disable/spec.md), [`267 group templates`](267-group-templates-magic-nodes.md), [`311 running config`](311-running-config-from-kernel.md) |

## Проблема

Репорт: свежая установка без серверов — приложение спокойно живёт (а при
непустом конфиге и VPN спокойно стартует), никакой подсказки «иди в Servers»
на главном экране нет.

Empty-state-гайд (`AddServerCta`: иконка + FAB → Servers + restore-from-backup)
в коде есть, но показывался по предикату `configRaw.isEmpty` —
«нет **файла** конфига», а не «нет **серверов**»
([node_list.dart:71](../../../app/lib/screens/home/widgets/node_list.dart)).

Конфиг становится непустым при нуле реальных серверов в типовых сценариях:

| Сценарий | Что происходит |
|---|---|
| подписка отдала 0 нод | bootstrap ([home_screen.dart:384](../../../app/lib/screens/home_screen.dart)) собирает конфиг из шаблона: direct, каналы, magic-ноды §267 |
| удалили все серверы | конфиг пересобирается, но не стирается |
| «Apply» в настройках (routing/DNS/VPN mode) | генерация конфига не зависит от наличия серверов |

После любого из них `configRaw` непустой **навсегда** → гайд не показывается
больше никогда. Контролы рисуются, `startEnabled=true` (условие — только
`configRaw.isNotEmpty`), VPN стартует с конфигом без единого payload-узла.
Единственный сигнал — транзиентный snackbar §274 про пустые каналы.

## Решение

Предикат меняется с «нет файла» на «нет ни одного реального сервера», при
туннеле down. Считаем по двум источникам:

- `configModel.nodeCount` — payload-ноды сохранённого конфига
  (control-типы `selector/urltest/direct/block/dns` не в счёт,
  [config_node.dart:282](../../../app/lib/models/config_node.dart)). Покрывает
  и импорт сырого конфига без entries: там ноды есть → гайд не лезет.
- ноды entries (`e.nodeCount > 0 || e.list.nodes.isNotEmpty`) — покрывает окно
  «сервер добавлен, конфиг ещё не пересобран»; `nodeCount` (персистентный
  кэш) — потому что у подписок `list.nodes` до rehydration пуст, и по одному
  `list.nodes` гайд мигал бы на каждом старте.

```dart
showAddServerGuide = !tunnelUp &&
    (configEmpty || (configNodeCount == 0 && !anyServerNodes));
```

Ветка `configEmpty` сохраняет прежнее поведение бит-в-бит (включая Debug API
`preview-empty-state`, который подменяет только `configRaw`/`nodes`).

Дисциплина показа — вариант A (согласован): в этом состоянии `AddServerCta`
берёт весь экран, контролы и disabled-Start не рисуются — ровно как текущий
first-run. Start при нуле серверов бессмыслен.

### Что сознательно НЕ меняется

| Кейс | Поведение |
|---|---|
| туннель up, серверы удалили на лету | как раньше: контролы + пассивный hint «No nodes in this channel» |
| туннель up, `configRaw` пустой (§116 аномалия) | как раньше: residual-ветка CTA в node_list + error-плашка |
| серверы есть, но все disabled (§283 / entry off) | гайд не показывается — серверы у юзера есть, это его осознанное состояние; пустую сборку сигналит §274 |
| Start из QS-tile / Automation при нуле серверов | вне scope |

## Файлы

| Файл | Изменение |
|---|---|
| [`node_list.dart`](../../../app/lib/screens/home/widgets/node_list.dart) | pure-функция `showAddServerGuide` + параметр `showEmptyGuide`, short-circuit до проверки `nodes.isEmpty` |
| [`home_screen.dart`](../../../app/lib/screens/home_screen.dart) | вычисление предиката, проброс в `HomeNodeList`, гейт контролов `&& !showEmptyGuide` |
| [`add_server_guide_test.dart`](../../../app/test/screens/home/add_server_guide_test.dart) | таблица предиката: свежая установка, шаблонный конфиг без серверов, подписка-пустышка, сырой импорт, окно до пересборки, туннель up, preview-empty parity |

## Проверка

- [x] `flutter test` — вся сьюта
- [x] `flutter analyze` — весь проект
- [x] 4 l10n-чекера `--strict` (новых строк нет — CTA переиспользуется)
- [ ] **device**: конфиг есть, серверов нет (удалить все) → на главном
      полноэкранный «Add a server», Start недоступен; добавить сервер →
      гайд уходит, контролы возвращаются
