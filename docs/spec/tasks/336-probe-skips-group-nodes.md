# §336 — Probe пропускает узлы-группы (автоузел §322 блокировал Test servers)

| | |
|---|---|
| Статус | Реализовано |
| Дата | 2026-08-02 |
| Связанные | [`322 balancer-node`](../features/322%20balancer-node/spec.md), [`236 folder-server-testing`](../features/236%20folder-server-testing), §296 (общий probe над ServerList), [`283 node-disable`](283-subscription-node-disable.md), [`334 onLaunchAfterCrash`](334-on-launch-after-crash-cache-reset.md) |
| Жалобы | 4PDA [#1406](../../forum/posts/01406.md), [#1407](../../forum/posts/01407.md) |

## Проблема

Добавленный в папку узел автовыбора (§322, «Add auto node…») блокирует Test
servers целиком: каждая попытка теста падает с ошибкой, не протестировав ни
одной ноды (#1407). Отключение узла (§283) не помогает — только удалить или
вынести из папки. Подписка с `routing.balancers` (Liberty) блокирует свой тест
так же.

## Причина

`buildProbeConfig` эмитит каждый узел его `getEntries` — а у `AutoSelectSpec`
`emitRaw` отдаёт **заготовку** urltest с пустым `outbounds: []`: члены пула
дописывает только боевой билдер вторым проходом (`auto_select_build.dart`),
которого в probe-пути нет. Ядро отвергает такой конфиг на создании:

```
initialize outbound[N]: missing tags        (protocol/group/urltest.go:86)
```

— и падает **весь probeStart**, а не одна нода. Отключение не помогает потому,
что папка передаёт члены в probe unfiltered (§296 — выключенные должны получить
вердикт), а `buildProbeConfig` не смотрел ни `enabled`, ни `isGroup`.

Репро подтверждено с двух сторон: Dart-тест — конфиг действительно уходит с
пустым `outbounds`; Go-тест на `daemon.StartOrReloadService` — стабильная
ошибка `missing tags` (не паника) на каждой попытке.

## Решение

**Группы в probe не тестируются** (решение юзера 02.08.2026). Свой замер группы
избыточен: её члены лежат в том же контейнере и тестируются поштучно, а
«задержка группы» в бою — это задержка выбранного члена, которого у headless
probe нет.

### Гейт — в `buildProbeConfig`

Единственная точка сборки для всех доменов (папки/подписки/серверы, §296):
узел с `isGroup` не эмитится и не попадает в `tagByIndex` — вердикт сразу,
маркером `'group'` в `brokenByIndex` (тот же канал, что `'broken'`/`'invalid:'`).
Экраны-вызыватели не правятся.

### Вердикт — `ProbeStatus.group`

Отдельный статус, не `broken`: «битая нода» — красный сигнал, «группа» — норма.
Маппинг маркера — в `ProbeRunner.run`, рядом с веткой broken/invalid.

### UI и решения

| место | поведение |
|---|---|
| бейдж строки (`_probeBadge`) | `auto`, нейтральный цвет (`onSurfaceVariant`), не ошибка |
| сводка (`_probeSummary`) | группа не считается ни в ok, ни в dead, ни в broken |
| `unreachableIndexes` | группа исключена — иначе «Disable unreachable» вырубал бы автоузел как «недоступный» |
| `slowerThan` | не затронута (только `ok`) |
| `pingSortOrder` | корзина «не тестировалась» (с `pending`), стабильный порядок |
| Debug API (`folders.dart`) | wire-статус `'group'`, в summary своей строкой |

## Тесты

`test/probe/probe_test.dart` (группа «§336 узлы-группы»):

- автоузел не в конфиге и не в `tagByIndex`, вердикт `'group'`; соседние ноды
  эмитятся как раньше;
- папка из одних групп → `configJson == null` (ядро не зовётся), вердикты есть;
- `ProbeRunner` отдаёт `ProbeStatus.group` без старта сессии;
- `unreachableIndexes` не включает группу; `pingSortOrder` кладёт её к
  нетестированным.

## Границы

Замер самой группы в probe (резолв членов + эмиссия готового urltest) не
делается: дублирует поштучные замеры членов, а параметры (§040 per-group url)
всё равно резолвятся не так, как в бою. Если понадобится — отдельная задача.

## Docs to update

- `CHANGELOG.md` — Unreleased. ✅
