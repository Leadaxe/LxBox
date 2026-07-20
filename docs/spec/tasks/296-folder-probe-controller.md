# §296 — ProbeController: общий probe-фасад над ServerList

**Тип:** structural refactor (Шаг 3 фичи [§291](../features/291%20layered-architecture-facades/spec.md)) · **Статус:** spec (переписан — был folder-only) · **Размер:** M (фундамент S–M) · **Заменяет:** прежний «FolderProbeController»

Probe (§236/§286) сегодня **folder-only по сигнатуре**, хотя механизм
доменно-агностичен. Это и есть настоящий §291-дефект: `folder_detail_screen`
(1669 строк) держит probe-логику, 11 прямых `SettingsStorage`-вызовов и
решения bulk-action — не потому что «у папок нет контроллера», а потому что
**у probe вообще нет контроллера**. Probe — общий доменный слой над всей
подсистемой Server lists (`sealed ServerList`: subscription · user · folder),
отработан в папках → пора поднять в фасад для подписок и одиночных серверов.

## Проблема (нарушение §291)

- `FolderProbeRunner.run(FolderServers)` + `buildProbeConfig(FolderServers)` —
  единственная структурная привязка к папкам: читает `folder.members[i].node`
  (`probe_config.dart:52-53`). Всё остальное (сессия, пул, lifecycle §286,
  пороги, ping, `onResult(index,result)`) — уже доменно-независимо.
- `SubscriptionServers`/`UserServer` держат ноды прямо в базовом
  `ServerList.nodes` (`server_list.dart:16`), без обёртки `FolderMember`.
- 11 прямых `SettingsStorage` в `folder_detail` — все probe-related (пороги
  `probe_ms_*`, `getPingOptions`/`setGlobalPingUrl/Timeout`); ни один не трогает
  `server_lists` (данные папки идут через `SubscriptionController` — чисто).
- Подписки и одиночные серверы **не имеют probe вообще** — хотя ноды у них те же.

## Решение — доменно-агностичный ProbeController

`lib/services/probe/probe_controller.dart` — сервис (не ChangeNotifier;
per-run stateless, как `FolderProbeRunner` сейчас), владеет тремя вещами, что
сейчас разбросаны по `folder_detail`:

1. **Пороги** — `loadThresholds()`/`saveThresholds()` над `probe_ms_*`; триплет
   `250/500/700` → один `ProbeThresholds.defaults` const.
2. **Ping** — `resolvePingOptions({overrideUrl, overrideTimeoutMs})` (folder
   даёт `pingUrl/pingTimeoutMs`, subs/user — null → чистый глобал);
   `setGlobalPingUrl`.
3. **Прогон** — доменно-агностичный
   `run({required List<NodeSpec?> nodes, required url, timeoutMs, onResult})`.
   Плюс эргономичный `runList(ServerList)` — switch member-vs-nodes[] в ОДНОМ
   месте.

**Генерализация ядра:** `buildProbeConfig(FolderServers)` →
`buildProbeConfig(List<NodeSpec?>)`. Тело не меняется по сути (всё после
`members[i].node` уже на уровне `NodeSpec`). Unification member↔nodes[]
решается ТОЛЬКО в адаптере `runList`, не в ядре.

**Пороговые/пинг/сессия/lifecycle** переезжают verbatim. VPN-гейт
(`_showVpnRunningGate` + `kProbeVpnRunning`) поднимается в общий
`ProbeGateMixin`/helper — один на три экрана.

**Bulk-решения** (`unreachableIndexes`/`slowerThan`/`pingSortOrder`) — чистые
`Map<int,ProbeResult>`→indices, доменно-агностичны → static-хелперы на
`ProbeController`. Но **актуаторы различны**: folder — позиционные
`setMembersEnabled/removeMembersAt` (§234); subs — §283 `toggleSubscriptionNode`
(hash-overlay, НЕ позиционный); user — per-node disable нет. Решения общие,
проводку к мутатору делает каждый экран сам.

## SHARP TRAP (из ресёрча)

- **Folder передаёт `members.map((m)=>m.node)` — nullable, UNFILTERED**, НЕ
  `folder.nodes`. `folder.nodes` (`server_list.dart:459-462`) отфильтрован до
  enabled+parsed → потерял бы выключенные члены и их broken/invalid-вердикты.
- **Subs: выключенные (§283) → null-слот ПЕРЕД индексацией** (адаптер), никогда
  `.where` (рассинхронит индексы с рендер-строками). §283 hash — persistence-ключ,
  для transient result→row достаточно позиционного индекса.
- **Background-refresh mid-probe** (AutoUpdater подменяет инстансы нод) — guard
  `identical(list.nodes, captured)` + drop stale onResult.

## Инкрементальный план (strangler; device-verify точки помечены)

- **Step 0** (механический, 0 поведения): `FolderProbeRunner`→`ProbeRunner`;
  `buildProbeConfig`/`run` → `List<NodeSpec?>`; `tagByMember`→`tagByIndex`; 4
  call-site передают `members.map((m)=>m.node)`; `250/500/700`→
  `ProbeThresholds.defaults`. **DEVICE: folder probe идентичен.**
- **Step 1** (вынос контроллера, folder-only поверхность): `ProbeController`
  (runner + пороги + ping + чистые bulk-хелперы); folder_detail на него — 11
  storage→0, решения→хелперы. **Это закрывает §296.** **DEVICE: folder_detail
  идентичен** (тот же якорь приёмки).
- **Step 2** (гейт): `_showVpnRunningGate`+pre-check → `ProbeGateMixin`. **DEVICE:
  гейт-попап unchanged.**
- **Step 3** (subs probe, additive): control-bar+бейдж+skip-disabled адаптер в
  `subscription_detail` Nodes-таб; bulk→§283 toggle. **DEVICE ОБЯЗАТЕЛЕН** (реальная
  probe-сессия, VPN-гейт, skip-disabled, background-refresh).
- **Step 4** (single-node, additive): Test в `node_settings_screen` через
  `run(nodes:[node])`.

**Ship boundary = Steps 0+1 вместе** — вынос ProbeController + folder_detail с
ДОКАЗУЕМО нулевым изменением поведения. Не смешивать subs-UI в extraction-коммит:
ценность extraction'а в том, что наблюдаемо ничего не меняется.

## Приёмка

- `buildProbeConfig`/`run` берут `List<NodeSpec?>`; folder передаёт
  `members.map((m)=>m.node)` (nullable, unfiltered); subs — `list.nodes` с
  disabled→null.
- 0 прямых `SettingsStorage` в `folder_detail`; порог = один const; экран сдут.
- `ProbeLifecycle` register/deregister сохранён verbatim; `haltAll` рвёт и
  subs-sweep.
- Bulk-хелперы (`unreachableIndexes`/`slowerThan`/`pingSortOrder`) — чистые,
  тестируемы.
- subs/user получают Test-action + общий гейт.
- `flutter analyze` чист; probe-тесты зелёные (Steps 0-2 code-provable; Step 3
  device-verified).

## Docs to update

- `docs/ARCHITECTURE.md` — `ProbeController` (не FolderProbeController) в карте,
  под `services/probe`.
- `CHANGELOG.md` — probe для подписок/серверов (Step 3, user-visible).
