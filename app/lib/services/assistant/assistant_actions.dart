/// §750 — изменения конфигурации по просьбе ассистента.
///
/// Этап 1: только `setConnectionEnabled` (Debug API `POST /assistant/
/// connection`). Маршрут приложения ассистент меняет общим `/rules` — узкая
/// операция `setAppRoute` снята решением владельца 17.11.2026.
///
/// Решение (что менять) — чистые функции над списками; применение
/// (пересборка конфига, reload ядра, старт VPN) — отдельный шаг с
/// inject-точкой для тестов.
library;

import 'dart:async';

import '../../controllers/home_controller.dart';
import '../../controllers/subscription_controller.dart';
import '../../models/tunnel_status.dart';
import '../../vpn/box_vpn_client.dart';
import '../app_log.dart';
import '../settings_storage.dart';
import 'assistant_index.dart';

/// Ошибка операции ассистента: машинный [code] (`not_found`,
/// `invalid_argument`, `source_off`, `locked`, `core_error`) и английский
/// [message] для агента.
class AssistantError implements Exception {
  const AssistantError(this.code, this.message);

  final String code;
  final String message;

  Map<String, Object?> toJson() => {
        'error': {'code': code, 'message': message},
      };

  @override
  String toString() => 'AssistantError($code): $message';
}

/// Что сделать с подключением.
sealed class ConnectionTogglePlan {
  const ConnectionTogglePlan(this.connection);
  final AssistantConnection connection;
}

/// Подключение уже в нужном состоянии — ничего не менять и не пересобирать.
final class ConnectionAlready extends ConnectionTogglePlan {
  const ConnectionAlready(super.connection);
}

/// Переключить флаг узла.
final class ConnectionFlip extends ConnectionTogglePlan {
  const ConnectionFlip(super.connection);
}

/// §750 — чистое решение по [connections] (из [assistantConnections]).
///
/// Бросает [AssistantError]: `not_found` — нет подключения с таким `id`;
/// `source_off` — включается узел выключенной папки/подписки (включать
/// контейнер целиком ассистент не вправе: это включило бы и соседей).
ConnectionTogglePlan planConnectionToggle(
  List<AssistantConnection> connections, {
  required String id,
  required bool enabled,
}) {
  final c = connections.where((c) => c.id == id).firstOrNull;
  if (c == null) {
    throw AssistantError('not_found', 'No connection with id "$id".');
  }
  if (c.enabled == enabled) return ConnectionAlready(c);
  if (enabled && !c.sourceEnabled) {
    throw AssistantError(
      'source_off',
      'The source "${c.sourceName}" of this connection is turned off. '
          'Turn it on in L×Box first.',
    );
  }
  return ConnectionFlip(c);
}

/// Применение после записи хранилища: возвращает доп. поля ответа
/// (`reload_pending`, `vpn_started`, `needs_consent`) или бросает
/// [AssistantError].
typedef AssistantApply = Future<Map<String, Object?>> Function(
    {required bool startIfStopped});

/// §750 — включить/выключить подключение [id] (тег ядра из индекса).
///
/// Путь включения тот же, что у UI: одиночный сервер — `toggleAt`, член
/// папки — `setMembersEnabled`, узел подписки —
/// `setSubscriptionNodesEnabled` (отметка `disabledHashes`; страховочные
/// `*ByCoreTag` пишут вердикт ядра — не наш случай). Уже в нужном
/// состоянии → `applied` без пересборки. Подключения собираются заново в
/// момент вызова (тот же состав, что у индекса [buildAssistantIndex]).
Future<Map<String, Object?>> setConnectionEnabled({
  required String id,
  required bool enabled,
  required SubscriptionController sub,
  HomeController? home,
  AssistantApply? apply,
}) async {
  final connections = assistantConnections(
    [for (final e in sub.entries) e.list],
    emittedTagMap: sub.lastEmittedTagMap,
  );
  final plan = planConnectionToggle(connections, id: id, enabled: enabled);
  final c = plan.connection;
  final summary = '${enabled ? 'Turn on' : 'Turn off'} ${c.name}';
  if (plan is ConnectionAlready) {
    return {'status': 'applied', 'summary': summary, 'changed': false};
  }
  // config_locked_for_debug — сборка вернула бы null; отклоняем ДО записи.
  if (await SettingsStorage.getConfigLockedForDebug()) {
    throw const AssistantError('locked',
        'The configuration is pinned for debugging; changes are not applied.');
  }

  switch (c.slot) {
    case AssistantConnectionSlot.userServer:
      await sub.toggleAt(c.sourceIndex);
    case AssistantConnectionSlot.folderMember:
      await sub.setMembersEnabled(c.sourceIndex, {c.memberIndex!}, enabled);
    case AssistantConnectionSlot.subscriptionNode:
      await sub.setSubscriptionNodesEnabled(c.sourceIndex, [c.node],
          enabled: enabled);
  }

  final applyFn = apply ??
      ({required bool startIfStopped}) => applyAssistantConfig(
            sub: sub,
            home: home,
            startIfStopped: startIfStopped,
          );
  final extras = await applyFn(startIfStopped: enabled);
  return {
    'status': 'applied',
    'summary': summary,
    'changed': true,
    ...extras,
  };
}

/// Сколько ждать конца cooldown reload'а (3 с, `HomeController`).
const Duration _kReloadWait = Duration(milliseconds: 3600);

/// §750 — пересборка + запись конфига + reload ядра на месте, если туннель
/// поднят (без оглядки на «Auto-restart VPN on settings change»: человек
/// просил результат сейчас). Cooldown reload'а — ждём его конец (как повтор
/// `applyIfAutoReload`), не дождались — `reload_pending: true`.
/// [startIfStopped] и туннель остановлен — headless-старт, как Debug API
/// `start-vpn-headless` (нужно уже выданное согласие на VPN).
Future<Map<String, Object?>> applyAssistantConfig({
  required SubscriptionController sub,
  HomeController? home,
  required bool startIfStopped,
}) async {
  final json = await sub.generateConfig();
  if (json == null) {
    if (await SettingsStorage.getConfigLockedForDebug()) {
      throw const AssistantError('locked',
          'The configuration is pinned for debugging; changes are not applied.');
    }
    throw AssistantError('core_error',
        'Config build failed: ${sub.lastError?.renderEn() ?? 'unknown error'}');
  }
  if (home == null) {
    // Без HomeController записать конфиг некому — хранилище уже изменено,
    // конфиг соберётся на следующем старте.
    return {'reload_pending': true};
  }
  if (!await home.saveParsedConfig(json)) {
    throw const AssistantError('core_error', 'Saving the config failed.');
  }
  final tunnel = home.state.tunnel;
  if (tunnel.isUp) {
    final deadline = DateTime.now().add(_kReloadWait);
    while (!home.canReload &&
        home.state.tunnel == TunnelStatus.connected &&
        DateTime.now().isBefore(deadline)) {
      await Future<void>.delayed(const Duration(milliseconds: 200));
    }
    if (!home.canReload) return {'reload_pending': true};
    await home.reloadVpn();
    return const {};
  }
  if (startIfStopped) {
    final r = await BoxVpnClient().startVpnHeadless();
    AppLog.I.info('§750: headless start → started=${r.started} '
        'needs_consent=${r.needsConsent}');
    return {'vpn_started': r.started, 'needs_consent': r.needsConsent};
  }
  return const {};
}
