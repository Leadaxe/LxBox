import 'package:flutter_test/flutter_test.dart';
import 'package:lxbox/services/automation/event_emitter.dart';

/// §047 — AutomationEventEmitter: gate-toggles, throttle policy.
void main() {
  late List<(String, Map<String, Object?>)> sent;

  void capture(String action, Map<String, Object?> extras) =>
      sent.add((action, extras));

  setUp(() => sent = []);

  // AutomationEventEmitter.I — синглтон: сбрасываем перехват/гейты после
  // каждого теста, чтобы состояние не протекало в другие тест-файлы
  // (иначе редкий cross-file flaky, когда шард стартует automation-тест
  // до его setUp с чужим _sendOverride).
  tearDown(() => AutomationEventEmitter.I.debugConfigureForTest());

  group('gates', () {
    test('all OFF — emit no-op', () {
      AutomationEventEmitter.I.debugConfigureForTest(onSend: capture);
      AutomationEventEmitter.I.emitVpnConnected();
      AutomationEventEmitter.I.emitNodeChanged(null, 'n', 'g', 'user');
      AutomationEventEmitter.I.emitSubRefreshed('s', 1, 1);
      expect(sent, isEmpty);
    });

    test('lifecycle gate independent of state/subs', () {
      AutomationEventEmitter.I
          .debugConfigureForTest(lifecycle: true, onSend: capture);
      AutomationEventEmitter.I.emitVpnConnected();
      AutomationEventEmitter.I.emitNodeChanged(null, 'n', 'g', 'user'); // gated off
      AutomationEventEmitter.I.emitSubRefreshed('s', 1, 1); // gated off
      expect(sent.map((e) => e.$1), ['VPN_CONNECTED']);
    });

    test('state gate emits node/group only', () {
      AutomationEventEmitter.I
          .debugConfigureForTest(state: true, onSend: capture);
      AutomationEventEmitter.I.emitVpnConnected(); // off
      AutomationEventEmitter.I.emitNodeChanged('old', 'new', 'grp', 'user');
      AutomationEventEmitter.I.emitGroupChanged('g1', 'g2', 'user');
      expect(sent.map((e) => e.$1), ['ACTIVE_NODE_CHANGED', 'ACTIVE_GROUP_CHANGED']);
      final node = sent.first.$2;
      expect(node['old_tag'], 'old');
      expect(node['new_tag'], 'new');
      expect(node['group'], 'grp');
      expect(node['reason'], 'user');
    });

    test('node-already-active gated by state, carries tag/group', () {
      // §290 — off без State-гейта.
      AutomationEventEmitter.I.debugConfigureForTest(onSend: capture);
      AutomationEventEmitter.I.emitNodeAlreadyActive('n', 'g');
      expect(sent, isEmpty);
      // on под State.
      AutomationEventEmitter.I
          .debugConfigureForTest(state: true, onSend: capture);
      AutomationEventEmitter.I.emitNodeAlreadyActive('🇫🇮node', 'grp');
      expect(sent.single.$1, 'NODE_ALREADY_ACTIVE');
      expect(sent.single.$2['tag'], '🇫🇮node');
      expect(sent.single.$2['group'], 'grp');
    });

    test('subs gate emits subscription events', () {
      AutomationEventEmitter.I
          .debugConfigureForTest(subs: true, onSend: capture);
      AutomationEventEmitter.I.emitSubRefreshed('sub-1', 10, 3);
      expect(sent.single.$1, 'SUB_REFRESHED');
      expect(sent.single.$2['nodes_count'], 10);
      expect(sent.single.$2['delta_count'], 3);
    });
  });

  group('throttle', () {
    // §219 — проверяем МЕХАНИКУ throttle (дубль в окне режется, per-key
    // изоляция), а не точную 60с-границу: у emitter нет инъекции часов, а оба
    // emit идут в одном синхронном блоке (разница « 60с) — тест не флаки от
    // настенного времени. Проверка именно 60с потребовала бы Clock-seam.
    test('SUB_REFRESH_FAILED capped 1/min per sub_id', () {
      AutomationEventEmitter.I
          .debugConfigureForTest(subs: true, onSend: capture);
      AutomationEventEmitter.I.emitSubRefreshFailed('sub-1', 'err');
      AutomationEventEmitter.I.emitSubRefreshFailed('sub-1', 'err2'); // throttled
      // другой sub_id — отдельный ключ, проходит.
      AutomationEventEmitter.I.emitSubRefreshFailed('sub-2', 'err');
      expect(sent.length, 2);
      expect(sent[0].$2['sub_id'], 'sub-1');
      expect(sent[1].$2['sub_id'], 'sub-2');
    });

    test('SUB_REFRESHED not throttled', () {
      AutomationEventEmitter.I
          .debugConfigureForTest(subs: true, onSend: capture);
      AutomationEventEmitter.I.emitSubRefreshed('s', 1, 0);
      AutomationEventEmitter.I.emitSubRefreshed('s', 2, 1);
      expect(sent.length, 2);
    });
  });

  group('health (future §042 namespace)', () {
    test('gated by health toggle', () {
      AutomationEventEmitter.I
          .debugConfigureForTest(health: true, onSend: capture);
      AutomationEventEmitter.I.emitHeartbeatFailed(3);
      AutomationEventEmitter.I.emitLatencyDegraded('node', 700);
      expect(sent.map((e) => e.$1), ['HEARTBEAT_FAILED', 'LATENCY_DEGRADED']);
    });
  });
}
