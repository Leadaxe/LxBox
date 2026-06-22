import '../../vpn/box_vpn_client.dart';
import '../app_log.dart';
import '../settings_storage.dart';

/// §047 — outgoing automation events. Эмиттер хучится в существующие точки
/// смены состояния (`HomeController._handleStatusEvent`, `switchNode`,
/// `setSelectedGroup`, `SubscriptionController` refresh-пути, `UpdateChecker`)
/// и шлёт Android broadcast'ы наружу (Tasker / Macrodroid подписываются через
/// `Profile → Event → Intent Received`).
///
/// **Granular gating.** Каждая категория (lifecycle / state / subs / health)
/// проверяется отдельно перед отправкой. Default — все OFF (security-дефолт
/// §047): пока юзер явно не включил категорию в App Settings → Automation,
/// `emit*` молча no-op'ит. Состояние gates подгружается через [reload] из
/// [SettingsStorage] (зовётся на старте и при смене любого toggle в UI).
///
/// **Send** делается на native стороне ([BoxVpnClient.sendAutomationBroadcast]
/// → `VpnPlugin.sendAutomationBroadcast`): broadcast открыт всем подписчикам.
/// События не содержат секретов — только лейблы (теги нод, группы, статус).
/// Per-app фильтр удалён (§157 — нерабочая permission-галка).
///
/// **Throttle.** Часть событий капится per-key (см. [_throttleWindows]), чтобы
/// при network-outage не заспамить подписчика (например `SUB_REFRESH_FAILED`).
class AutomationEventEmitter {
  AutomationEventEmitter._();
  static final AutomationEventEmitter I = AutomationEventEmitter._();

  // ─── Granular gates (default OFF) ──────────────────────────────────────────
  bool _lifecycleEnabled = false;
  bool _stateEnabled = false;
  bool _subsEnabled = false;
  bool _healthEnabled = false;

  /// Inject-точка для тестов: подменяет реальный native-вызов.
  void Function(String action, Map<String, Object?> extras)? _sendOverride;

  /// Last-emit timestamps per throttle-key (`<event>:<discriminator>`).
  final Map<String, DateTime> _lastEmitAt = {};

  /// Throttle-окна per event-type. Отсутствие записи = без throttle.
  static const Map<String, Duration> _throttleWindows = {
    'SUB_REFRESH_FAILED': Duration(minutes: 1),
  };

  /// Подгрузить состояние gate-toggle'ов из persistent storage. Зовётся на
  /// старте приложения и после смены любого emit-toggle в App Settings.
  Future<void> reload() async {
    _lifecycleEnabled = await SettingsStorage.getAutomationEmitLifecycle();
    _stateEnabled = await SettingsStorage.getAutomationEmitState();
    _subsEnabled = await SettingsStorage.getAutomationEmitSubs();
    _healthEnabled = await SettingsStorage.getAutomationEmitHealth();
  }

  /// Только для тестов — задать gates и перехватить отправку.
  void debugConfigureForTest({
    bool lifecycle = false,
    bool state = false,
    bool subs = false,
    bool health = false,
    void Function(String action, Map<String, Object?> extras)? onSend,
  }) {
    _lifecycleEnabled = lifecycle;
    _stateEnabled = state;
    _subsEnabled = subs;
    _healthEnabled = health;
    _sendOverride = onSend;
    _lastEmitAt.clear();
  }

  // ─── Lifecycle ─────────────────────────────────────────────────────────────

  void emitVpnConnected() => _emit('VPN_CONNECTED', const {}, _lifecycleEnabled);

  void emitVpnDisconnected(String reason) =>
      _emit('VPN_DISCONNECTED', {'reason': reason}, _lifecycleEnabled);

  void emitVpnError(String code, String message) =>
      _emit('VPN_ERROR', {'code': code, 'message': message}, _lifecycleEnabled);

  void emitVpnRevoked() => _emit('VPN_REVOKED', const {}, _lifecycleEnabled);

  void emitUpdateAvailable(String version, String url) => _emit(
      'UPDATE_AVAILABLE', {'version': version, 'url': url}, _lifecycleEnabled);

  void emitPermissionNeeded(String permission) =>
      _emit('PERMISSION_NEEDED', {'permission': permission}, _lifecycleEnabled);

  // ─── State ─────────────────────────────────────────────────────────────────

  void emitNodeChanged(
          String? oldTag, String newTag, String group, String reason) =>
      _emit(
          'ACTIVE_NODE_CHANGED',
          {
            'old_tag': oldTag,
            'new_tag': newTag,
            'group': group,
            'reason': reason,
          },
          _stateEnabled);

  void emitGroupChanged(String? oldGroup, String newGroup, String reason) =>
      _emit(
          'ACTIVE_GROUP_CHANGED',
          {'old_group': oldGroup, 'new_group': newGroup, 'reason': reason},
          _stateEnabled);

  // ─── Subscription ────────────────────────────────────────────────────────────

  void emitSubRefreshed(String subId, int nodesCount, int deltaCount) => _emit(
      'SUB_REFRESHED',
      {
        'sub_id': subId,
        'nodes_count': nodesCount,
        'delta_count': deltaCount,
      },
      _subsEnabled);

  void emitSubRefreshFailed(String subId, String error) => _emit(
        'SUB_REFRESH_FAILED',
        {'sub_id': subId, 'error': error},
        _subsEnabled,
        throttleKey: 'SUB_REFRESH_FAILED:$subId',
      );

  // ─── Health (future — §042 watchdog) ────────────────────────────────────────
  //
  // Namespace зарезервирован спекой §047; источники появятся вместе с §042
  // health watchdog. Gate `_healthEnabled` уже есть в UI — эти методы дают
  // §042 готовую точку входа без новых toggle'ов.

  void emitHeartbeatFailed(int consecutiveFails) =>
      _emit('HEARTBEAT_FAILED', {'fails': consecutiveFails}, _healthEnabled);

  void emitLatencyDegraded(String tag, int latencyMs) => _emit(
      'LATENCY_DEGRADED', {'tag': tag, 'latency_ms': latencyMs}, _healthEnabled);

  // ─── Core emit ───────────────────────────────────────────────────────────────

  void _emit(
    String action,
    Map<String, Object?> extras,
    bool gateEnabled, {
    String? throttleKey,
  }) {
    if (!gateEnabled) return;

    // Throttle: если для action задано окно и последний emit был недавно —
    // дропаем, логируем причину.
    final window = _throttleWindows[action];
    if (window != null) {
      final key = throttleKey ?? action;
      final last = _lastEmitAt[key];
      final now = DateTime.now();
      if (last != null && now.difference(last) < window) {
        final agoSec = now.difference(last).inSeconds;
        AppLog.I.info('[automation] emit $action → throttled (last ${agoSec}s ago)');
        return;
      }
      _lastEmitAt[key] = now;
    }

    final send = _sendOverride;
    if (send != null) {
      send(action, extras);
    } else {
      BoxVpnClient.I.sendAutomationBroadcast(action, extras);
    }
    AppLog.I.info('[automation] emit $action${_fmtExtras(extras)} → ok');
  }

  String _fmtExtras(Map<String, Object?> extras) {
    if (extras.isEmpty) return '';
    final parts = extras.entries
        .where((e) => e.value != null)
        .map((e) => '${e.key}=${e.value}');
    return parts.isEmpty ? '' : ' ${parts.join(' ')}';
  }
}
