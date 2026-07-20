import 'dart:async';

import '../../vpn/box_vpn_client.dart';
import '../debug/context.dart';
import '../debug/contract/errors.dart';
import '../settings_storage.dart';
import '../subscription/auto_updater.dart';

/// §047 — pure-business action handlers, общие для двух транспортов:
///   - **Debug API** (`/action/*`, [debug/handlers/action.dart]) — thin
///     wrapper'ы парсят query/body и зовут эти функции;
///   - **Automation API** (broadcast intents, [box_vpn_client] →
///     `_handleAutomationAction`) — роутит intent-action → эти же функции.
///
/// Контекст — [DebugContext] (тот же, что у Debug API): даёт
/// `requireHome()`/`requireSub()`/`autoUpdater` поверх [DebugRegistry]. Это
/// избавляет от дублирования DI-слоя — Automation-bridge собирает контекст из
/// `DebugRegistry.I` без HTTP-обвязки.
///
/// Все функции **бросают** [DebugError] при precondition-фейле (нет группы,
/// tunnel down, lock включён). Debug API мапит их в HTTP-коды; Automation-
/// bridge ловит и логирует в AppLog с `[automation]` префиксом (intent не
/// может «вернуть ошибку» отправителю синхронно — Tasker узнаёт о провале из
/// outgoing `VPN_ERROR`, см. spec §047).
///
/// Большинство — fire-and-forget (`unawaited`): домен работает асинхронно,
/// статус наблюдается через `/state` или outgoing-события.

/// `switch-node` — переключить активную ноду в текущей группе.
/// Бросает [Conflict] если группа не выбрана или туннель не поднят.
Future<void> actionSwitchNode(String tag, DebugContext ctx) async {
  if (tag.isEmpty) throw const BadRequest('"tag" empty');
  final home = ctx.requireHome();
  if (home.state.selectedGroup == null) {
    throw const Conflict('no group selected — set group first');
  }
  // §290 — precondition симметрична urltest-group/reset-network: без tunnel up
  // `switchNode` молча делает ранний return (нет instance для selectOutbound),
  // и automation-мост не смог бы отличить «сделано» от «нет» → уводил Tasker в
  // timeout. Явный Conflict → мост эмитит VPN_ERROR.
  if (!home.state.tunnelUp) {
    throw const Conflict('tunnel not connected');
  }
  unawaited(home.switchNode(tag));
}

/// `set-group` — сменить активную группу (+ загрузить её ноды).
/// Бросает [NotFound] если группы с таким тегом нет: иначе `setSelectedGroup`
/// эмитил бы ложный `ACTIVE_GROUP_CHANGED` на несуществующую группу, а
/// `applyGroup` молча выходил (`groupOf → null`) и ноды не грузил.
Future<void> actionSetGroup(String group, DebugContext ctx) async {
  if (group.isEmpty) throw const BadRequest('"group" empty');
  final home = ctx.requireHome();
  if (!home.state.groups.contains(group)) {
    throw NotFound('group not found: "$group"');
  }
  home.setSelectedGroup(group);
  unawaited(home.applyGroup(group));
}

/// `rebuild-config` — пересобрать sing-box config из подписок.
/// Бросает [Conflict] если §037 config-lock включён.
/// Возвращает размер сгенерированного config'а в байтах.
Future<int> actionRebuildConfig(DebugContext ctx) async {
  if (await SettingsStorage.getConfigLockedForDebug()) {
    throw const Conflict(
      'config_locked_for_debug=true — rebuild blocked.',
    );
  }
  final sub = ctx.requireSub();
  final home = ctx.requireHome();
  final json = await sub.generateConfig();
  if (json == null) {
    throw UpstreamError(
        'generate failed: ${sub.lastError?.renderEn() ?? ''}');
  }
  final saved = await home.saveParsedConfig(json);
  if (!saved) {
    throw const UpstreamError('saveParsedConfig returned false');
  }
  return json.length;
}

/// `refresh-subs` — manual обновление всех подписок.
/// Бросает [Conflict] если auto-updater ещё не готов.
Future<void> actionRefreshSubs(bool force, DebugContext ctx) async {
  final updater = ctx.autoUpdater;
  if (updater == null) {
    throw const Conflict('auto updater not ready');
  }
  unawaited(updater.maybeUpdateAll(UpdateTrigger.manual, force: force));
}

/// `reset-network` — light recovery (closeAll + DNS flush + dialer rebind).
/// Бросает [Conflict] если tunnel не поднят (no-op без него).
/// Возвращает native-результат.
Future<bool> actionResetNetwork(DebugContext ctx) async {
  final home = ctx.requireHome();
  if (!home.state.tunnelUp) {
    throw const Conflict('tunnel not up — resetNetwork is no-op');
  }
  return BoxVpnClient().resetNetwork();
}

/// `urltest-group` — форсировать URLTest на группе (требует tunnel up).
Future<void> actionUrltestGroup(String group, DebugContext ctx) async {
  if (group.isEmpty) throw const BadRequest('"group" empty');
  final home = ctx.requireHome();
  if (!home.state.tunnelUp) {
    throw const Conflict('tunnel not connected');
  }
  unawaited(home.runGroupUrltest(group));
}

/// `start-vpn` — запросить старт VPN (идемпотентно: noop если up).
/// На native стороне `START_VPN` идёт напрямую через `BoxVpnService.start` —
/// этот хелпер для Debug API (где есть HomeController).
Future<void> actionStartVpn(DebugContext ctx) async {
  final home = ctx.requireHome();
  unawaited(home.start());
}

/// `stop-vpn` — запросить остановку VPN.
Future<void> actionStopVpn(DebugContext ctx) async {
  final home = ctx.requireHome();
  unawaited(home.stop());
}
