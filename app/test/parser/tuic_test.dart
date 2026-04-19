import 'package:flutter_test/flutter_test.dart';
import 'package:lxbox/models/node_spec.dart';
import 'package:lxbox/models/template_vars.dart';
import 'package:lxbox/services/parser/uri_parsers.dart';

void main() {
  group('TUIC v5 — new in v2', () {
    test('basic URI → TuicSpec with BBR + native UDP', () {
      final spec = parseTuic(
        'tuic://11111111-2222-3333-4444-555555555555:testpass123@example.com:443?congestion_control=bbr&udp_relay_mode=native&alpn=h3&sni=example.com#TUIC',
      );
      expect(spec, isNotNull);
      expect(spec!.uuid, '11111111-2222-3333-4444-555555555555');
      expect(spec.password, 'testpass123');
      expect(spec.congestionControl, 'bbr');
      expect(spec.udpRelayMode, 'native');
      expect(spec.tls.alpn, ['h3']);
      expect(spec.tls.serverName, 'example.com');
    });

    test('cubic + quic relay + alpn CSV', () {
      final spec = parseTuic(
        'tuic://u:p@h.example:8443?congestion_control=cubic&udp_relay_mode=quic&alpn=h3,h3-29&allow_insecure=1',
      );
      expect(spec, isNotNull);
      expect(spec!.udpRelayMode, 'quic');
      expect(spec.tls.alpn, ['h3', 'h3-29']);
      expect(spec.tls.insecure, true);
    });

    test('emit produces sing-box outbound with required keys', () {
      final spec = parseTuic(
        'tuic://u:p@h:443?congestion_control=bbr&alpn=h3&sni=h&reduce_rtt=1',
      );
      final entry = spec!.emit(TemplateVars.empty);
      final m = entry.map;
      expect(m['type'], 'tuic');
      expect(m['uuid'], 'u');
      expect(m['password'], 'p');
      expect(m['congestion_control'], 'bbr');
      expect(m['zero_rtt_handshake'], true);
      expect((m['tls'] as Map)['alpn'], ['h3']);
    });

    test('round-trip parseUri(toUri()) preserves structure', () {
      final spec = parseTuic(
        'tuic://aaaa-bbbb:secret@srv:443?congestion_control=bbr&udp_relay_mode=native&alpn=h3&sni=srv',
      );
      final uri2 = spec!.toUri();
      final spec2 = parseUri(uri2);
      expect(spec2, isA<TuicSpec>());
      final t2 = spec2 as TuicSpec;
      expect(t2.uuid, spec.uuid);
      expect(t2.password, spec.password);
      expect(t2.congestionControl, spec.congestionControl);
      expect(t2.udpRelayMode, spec.udpRelayMode);
      expect(t2.tls.alpn, spec.tls.alpn);
    });

    test('invalid congestion_control → default cubic', () {
      final spec = parseTuic(
        'tuic://u:p@h:443?congestion_control=bogus',
      );
      expect(spec!.congestionControl, 'cubic');
    });
  });
}
