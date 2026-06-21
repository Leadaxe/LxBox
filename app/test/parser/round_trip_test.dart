import 'package:flutter_test/flutter_test.dart';
import 'package:lxbox/services/parser/uri_parsers.dart';

/// Round-trip §4 спеки 026: `parseUri(spec.toUri()) ≈ spec`. Сравнение без
/// `id`, `rawUri`, `warnings` — это ephemeral поля, не связанные со значением
/// узла.
void main() {
  group('Round-trip URI → Spec → URI → Spec', () {
    test('VLESS Reality: pbk, sid, flow preserved', () {
      final a = parseVless(
        'vless://aaaa-bbbb@srv.example:443?type=tcp&security=reality&flow=xtls-rprx-vision&pbk=PK&sid=abcd1234&sni=www.example.com&fp=chrome#Test',
      )!;
      final b = parseVless(a.toUri())!;
      expect(b.uuid, a.uuid);
      expect(b.server, a.server);
      expect(b.port, a.port);
      expect(b.flow, a.flow);
      expect(b.tls.reality?.publicKey, a.tls.reality?.publicKey);
      expect(b.tls.reality?.shortId, a.tls.reality?.shortId);
      expect(b.tls.fingerprint, a.tls.fingerprint);
      expect(b.tls.serverName, a.tls.serverName);
    });

    test('Trojan WS + TLS: password, sni, path preserved', () {
      final a = parseTrojan(
        'trojan://testpass123@h.example:443?type=ws&security=tls&path=%2Ftr&host=h.example&sni=h.example#T',
      )!;
      final b = parseTrojan(a.toUri())!;
      expect(b.password, a.password);
      expect(b.tls.serverName, a.tls.serverName);
    });

    test('§151 F2 — Trojan ALPN double-encoded (http%252F1.1) → чистый http/1.1', () {
      // Нода из реальной подписки-агрегатора: alpn=http%252F1.1 (двойное
      // percent-кодирование). Uri.queryParameters декодит один раз → 'http%2F1.1';
      // _normalizeAlpn снимает остаточный %2F → 'http/1.1'.
      final a = parseTrojan(
        'trojan://p@h.example:443?type=ws&security=tls&alpn=http%252F1.1&sni=h.example#N',
      )!;
      expect(a.tls.alpn, ['http/1.1']);
    });

    test('§151 F2 — Trojan ALPN список h2,http/1.1 не ломается', () {
      final a = parseTrojan(
        'trojan://p@h.example:443?type=ws&security=tls&alpn=h2,http/1.1&sni=h.example#N',
      )!;
      expect(a.tls.alpn, ['h2', 'http/1.1']);
    });

    test('Shadowsocks: method + password preserved across base64', () {
      final a = parseShadowsocks(
        'ss://YWVzLTI1Ni1nY206dGVzdHBhc3Mx@srv:8388#SS',
      )!;
      final b = parseShadowsocks(a.toUri())!;
      expect(b.method, a.method);
      expect(b.password, a.password);
      expect(b.server, a.server);
      expect(b.port, a.port);
    });

    test('Hysteria2 with obfs + alpn: all preserved', () {
      final a = parseHysteria2(
        'hysteria2://secret@h:443?obfs=salamander&obfs-password=op&alpn=h3&sni=h#H',
      )!;
      final b = parseHysteria2(a.toUri())!;
      expect(b.password, a.password);
      expect(b.obfs, a.obfs);
      expect(b.obfsPassword, a.obfsPassword);
      expect(b.tls.alpn, a.tls.alpn);
    });

    test('§084 H3 — Hysteria2 up_mbps/down_mbps round-trip', () {
      final a = parseHysteria2(
        'hysteria2://secret@h:443?up_mbps=100&down_mbps=200&sni=h#H',
      )!;
      expect(a.upMbps, 100);
      expect(a.downMbps, 200);
      final b = parseHysteria2(a.toUri())!;
      expect(b.upMbps, 100, reason: 'up_mbps должен пережить toUri round-trip');
      expect(b.downMbps, 200);
    });

    test('§084 H3 — Hysteria2 без Mbps: остаются null', () {
      final a = parseHysteria2('hysteria2://secret@h:443?sni=h#H')!;
      expect(a.upMbps, isNull);
      expect(a.downMbps, isNull);
      final b = parseHysteria2(a.toUri())!;
      expect(b.upMbps, isNull);
      expect(b.downMbps, isNull);
    });

    test('TUIC: all core fields preserved', () {
      final a = parseTuic(
        'tuic://uuid-1:secret@srv:443?congestion_control=bbr&udp_relay_mode=native&alpn=h3,h3-29&sni=srv&reduce_rtt=1#TUIC',
      )!;
      final b = parseTuic(a.toUri())!;
      expect(b.uuid, a.uuid);
      expect(b.password, a.password);
      expect(b.congestionControl, a.congestionControl);
      expect(b.udpRelayMode, a.udpRelayMode);
      expect(b.zeroRtt, a.zeroRtt);
      expect(b.tls.alpn, a.tls.alpn);
    });

    test('VMess JSON: uuid + server + transport preserved', () {
      final a = parseVmess(
        'vmess://eyJ2IjoiMiIsInBzIjoiViIsImFkZCI6ImguZXhhbXBsZSIsInBvcnQiOiI0NDMiLCJpZCI6InV1aWQtMSIsImFpZCI6IjAiLCJzY3kiOiJhdXRvIiwibmV0Ijoid3MiLCJob3N0IjoiaC5leGFtcGxlIiwicGF0aCI6Ii92IiwidGxzIjoidGxzIiwic25pIjoiaC5leGFtcGxlIn0=',
      )!;
      final b = parseVmess(a.toUri())!;
      expect(b.uuid, a.uuid);
      expect(b.server, a.server);
      expect(b.port, a.port);
      expect(b.tls.enabled, a.tls.enabled);
    });

    test('WireGuard: private key + peer preserved', () {
      final a = parseWireguardUri(
        'wireguard://Privatekey==@h:51820?publickey=PublicKey&address=10.0.0.2%2F32&mtu=1420&keepalive=25#WG',
      )!;
      final b = parseWireguardUri(a.toUri())!;
      expect(b.privateKey, a.privateKey);
      expect(b.peers.first.publicKey, a.peers.first.publicKey);
      expect(b.mtu, a.mtu);
      expect(b.peers.first.persistentKeepalive, a.peers.first.persistentKeepalive);
    });

    test('SOCKS: credentials preserved', () {
      final a = parseSocks('socks5://user:pass@h.example:1080#S')!;
      final b = parseSocks(a.toUri())!;
      expect(b.username, a.username);
      expect(b.password, a.password);
    });

    test('parseUri dispatches — unknown scheme → null', () {
      expect(parseUri('ftp://x'), isNull);
      expect(parseUri('bogus://y'), isNull);
      expect(parseUri(''), isNull);
    });

    test('parseUri — malformed URIs never throw', () {
      expect(parseUri('vless://'), isNull);
      expect(parseUri('vmess://not-base64'), isNull);
      expect(parseUri('ss://@'), isNull);
    });
  });
}
