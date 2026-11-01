import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lxbox/services/platform_channels.dart';
import 'package:lxbox/services/wg_peer_status.dart';
import 'package:lxbox/vpn/cc_channel.dart';

/// §613 (ядро SPEC 114/115) — разбор статуса пиров WG/AWG и пути пиров
/// Tailscale из канала, вердикт «на связи».
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const key = 'RIpgAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA1EoX=';

  group('§613 — getWireGuardStatus', () {
    const channel = MethodChannel(PlatformChannels.methods);
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;

    tearDown(() => messenger.setMockMethodCallHandler(channel, null));

    test('проброс тега и разбор ответа', () async {
      late MethodCall seen;
      messenger.setMockMethodCallHandler(channel, (call) async {
        seen = call;
        return {
          'endpoint_state': 'up',
          'idle_since_seconds': 0,
          'peers': [
            {
              'public_key': key,
              'endpoint': '192.0.2.1:51820',
              'last_handshake_unix': 1700000000,
              'rx_bytes': 1200,
              'tx_bytes': 340,
              'session_rx_bytes': 200,
              'session_tx_bytes': 40,
            },
            {'public_key': 'short'},
          ],
        };
      });
      final st = await CcChannel.instance.getWireGuardStatus('wg-de');
      expect(seen.method, 'ccGetWireGuardStatus');
      expect(seen.arguments, {'tag': 'wg-de'});
      expect(st.endpointState, 'up');
      expect(st.peers, hasLength(2));
      final p = st.peers.first;
      expect(p.publicKey, key);
      expect(p.endpoint, '192.0.2.1:51820');
      expect(p.lastHandshakeUnix, 1700000000);
      expect(p.rxBytes, 1200);
      expect(p.txBytes, 340);
      expect(p.sessionRxBytes, 200);
      expect(p.sessionTxBytes, 40);
      expect(p.shortKey, 'RIpg…1EoX');
      final q = st.peers.last;
      expect(q.endpoint, '');
      expect(q.lastHandshakeUnix, 0);
      expect(q.sessionRxBytes, 0);
      expect(q.shortKey, 'short');
    });

    test('null из native — пустой статус', () async {
      messenger.setMockMethodCallHandler(channel, (call) async => null);
      final st = await CcChannel.instance.getWireGuardStatus('wg-de');
      expect(st.endpointState, '');
      expect(st.peers, isEmpty);
    });

    test('отказ ядра — код различим', () async {
      messenger.setMockMethodCallHandler(channel, (call) async {
        throw PlatformException(code: CcStatusError.unimplemented);
      });
      expect(
        () => CcChannel.instance.getWireGuardStatus('wg-x'),
        throwsA(
          isA<PlatformException>().having(
            (e) => e.code,
            'code',
            'unimplemented',
          ),
        ),
      );
    });
  });

  group('§613 — вердикт пира', () {
    const now = 1700001000;
    CcWireGuardPeer peer(int hs) =>
        CcWireGuardPeer(publicKey: key, lastHandshakeUnix: hs);

    WgPeerVerdict v(
      String state,
      int hs, {
      bool grew = false,
      int limit = 180,
    }) => wgPeerVerdict(
      endpointState: state,
      peer: peer(hs),
      rxGrew: grew,
      nowUnix: now,
      rejectAfterSeconds: limit,
    );

    test('хендшейка не было — never connected', () {
      expect(v('up', 0).kind, WgPeerVerdictKind.neverConnected);
    });

    test('age ≤ порога — на связи', () {
      expect(v('up', now - 180).kind, WgPeerVerdictKind.connected);
    });

    test('age > порога, rx стоит — нет сессии с возрастом', () {
      expect(
        v('up', now - 600),
        const WgPeerVerdict(WgPeerVerdictKind.noSession, 600),
      );
    });

    test('age > порога, rx растёт — на связи', () {
      expect(v('up', now - 600, grew: true).kind, WgPeerVerdictKind.connected);
    });

    test('порог reject_after_time', () {
      expect(v('up', now - 250, limit: 300).kind, WgPeerVerdictKind.connected);
    });

    test('без ответа — выше порога и роста rx, с возрастом', () {
      expect(
        wgPeerVerdict(
          endpointState: 'up',
          peer: peer(now - 90),
          rxGrew: false,
          unanswered: true,
          nowUnix: now,
        ),
        const WgPeerVerdict(WgPeerVerdictKind.noResponse, 90),
      );
      expect(
        wgPeerVerdict(
          endpointState: 'up',
          peer: peer(0),
          rxGrew: false,
          unanswered: true,
          nowUnix: now,
        ).kind,
        WgPeerVerdictKind.neverConnected,
      );
    });

    test('asleep / disabled', () {
      expect(v('asleep', now).kind, WgPeerVerdictKind.asleep);
      expect(v('disabled', now).kind, WgPeerVerdictKind.disabled);
    });

    test('секция видна только в up / asleep / disabled', () {
      expect(wgPeersSectionVisible('up'), isTrue);
      expect(wgPeersSectionVisible('asleep'), isTrue);
      expect(wgPeersSectionVisible('disabled'), isTrue);
      expect(wgPeersSectionVisible('never_built'), isFalse);
      expect(wgPeersSectionVisible('torn_down'), isFalse);
      expect(wgPeersSectionVisible(''), isFalse);
    });
  });

  group('§613 — reject_after_time и счётчики', () {
    test('число, диапазон, нет поля', () {
      expect(wgRejectAfterSeconds(null), 180);
      expect(wgRejectAfterSeconds({'reject_after_time': 240}), 240);
      expect(wgRejectAfterSeconds({'reject_after_time': '120-300'}), 300);
      expect(wgRejectAfterSeconds({'reject_after_time': '200'}), 200);
      expect(wgRejectAfterSeconds({'reject_after_time': 'x'}), 180);
    });

    test('рост rx; меньшее значение — новая база', () {
      final t = WgTrafficTracker();
      expect(t.record(key, 100, 0, 0).rxGrew, isFalse);
      expect(t.record(key, 150, 0, 2).rxGrew, isTrue);
      expect(t.record(key, 150, 0, 4).rxGrew, isFalse);
      expect(t.record(key, 10, 0, 6).rxGrew, isFalse);
      expect(t.record(key, 20, 0, 8).rxGrew, isTrue);
    });

    test('tx растёт, rx стоит — без ответа с четвёртого роста', () {
      final t = WgTrafficTracker();
      t.record(key, 100, 100, 0);
      expect(t.record(key, 100, 200, 2).unanswered, isFalse);
      expect(t.record(key, 100, 300, 4).unanswered, isFalse);
      expect(t.record(key, 100, 400, 6).unanswered, isFalse);
      expect(t.record(key, 100, 500, 8).unanswered, isTrue);
      // tx встал — ростов в окне хватает, вердикт держится.
      expect(t.record(key, 100, 500, 10).unanswered, isTrue);
      // rx вырос — счёт обнуляется.
      final s = t.record(key, 200, 600, 12);
      expect(s.rxGrew, isTrue);
      expect(s.unanswered, isFalse);
    });

    test('keepalive раз в 25 с — не без ответа', () {
      final t = WgTrafficTracker();
      var tx = 0;
      for (var now = 0; now <= 300; now += 2) {
        if (now % 25 < 2) tx += 32;
        expect(t.record(key, 100, tx, now).unanswered, isFalse, reason: '$now');
      }
    });

    test('ростов tx, вышедших из окна 20 с, не считаем', () {
      final t = WgTrafficTracker();
      t.record(key, 100, 0, 0);
      t.record(key, 100, 10, 2);
      t.record(key, 100, 20, 4);
      t.record(key, 100, 30, 6);
      expect(t.record(key, 100, 40, 30).unanswered, isFalse);
    });

    test('сброс tx — новая база, счёт с нуля', () {
      final t = WgTrafficTracker();
      t.record(key, 100, 100, 0);
      t.record(key, 100, 200, 2);
      t.record(key, 100, 300, 4);
      t.record(key, 100, 400, 6);
      expect(t.record(key, 100, 50, 8).unanswered, isFalse);
      expect(t.record(key, 100, 60, 10).unanswered, isFalse);
    });
  });

  group('§613 — путь и health Tailscale', () {
    test('поля пира и health статуса', () {
      final list = CcTailscaleStatus.listFrom([
        {
          'tag': 'ts',
          'backend_state': 'Running',
          'health': ['no DERP home', '', null],
          'exit_node': {
            'stable_id': 'n1',
            'host_name': 'gl-mt2500',
            'path': 'direct',
            'endpoint': '198.51.100.7:41641',
            'peer_relay': '',
            'derp_region_code': 'fra',
            'last_handshake': 1700000000,
          },
        },
      ]);
      final s = list.single;
      expect(s.health, ['no DERP home']);
      final e = s.exitNode!;
      expect(e.path, CcTailscalePath.direct);
      expect(e.endpoint, '198.51.100.7:41641');
      expect(e.derpRegionCode, 'fra');
      expect(e.lastHandshake, 1700000000);
    });

    test('§645 — путь ядра строчный; регистр при разборе не важен', () {
      for (final raw in ['direct', 'DIRECT']) {
        final p = CcTailscalePeer.fromMap({'stable_id': 'n1', 'path': raw});
        expect(p.path, CcTailscalePath.direct);
      }
      expect(
        CcTailscalePeer.fromMap(const {'path': 'peer_relay'}).path,
        CcTailscalePath.peerRelay,
      );
      expect(
        CcTailscalePeer.fromMap(const {'path': 'derp'}).path,
        CcTailscalePath.derp,
      );
    });

    test('ядро без пути — пустые поля', () {
      final p = CcTailscalePeer.fromMap(const {'stable_id': 'n1'});
      expect(p.path, '');
      expect(p.peerRelay, '');
      expect(p.lastHandshake, 0);
    });
  });
}
