import 'package:flutter_test/flutter_test.dart';
import 'package:lxbox/services/warp/masque_account.dart';
import 'package:lxbox/services/warp/scan/scan_models.dart';
import 'package:lxbox/services/warp/scan/scan_node_builder.dart';
import 'package:lxbox/services/warp/warp_account.dart';

/// §284 — сборка URI-узла кандидата из WARP-аккаунта (переиспользование кредов
/// одной регистрации на любом IP:port).
void main() {
  WarpAccount warp() => const WarpAccount(
        privKey: 'cHJpdmtleQ==',
        peerPub: 'cGVlcnB1Yg==',
        clientV4: '172.16.0.2/32',
        clientV6: '',
        clientId: 'AAAA',
        accountId: 'acc',
        deviceId: 'dev',
        token: 'tok',
        endpoint: 'engage.cloudflareclient.com:2408',
        createdAt: '2026-01-01T00:00:00Z',
      );

  MasqueAccount masque() => const MasqueAccount(
        privKeyDer: 'a2V5',
        serverPubDer: 'cHVi',
        clientV4: '172.16.0.2',
        clientV6: '',
        server: '162.159.198.1',
        port: 443,
        deviceId: 'dev',
        token: 'tok',
        createdAt: '2026-01-01T00:00:00Z',
      );

  ScanCandidate cand(ScanProtocol p, {String ip = '162.159.192.7', int port = 2408}) =>
      ScanCandidate(ip: ip, port: port, protocol: p, sni: 'yandex.ru');

  test('AWG-узел несёт endpoint кандидата в .conf', () {
    final b = ScanNodeBuilder(warp: warp());
    final uri = b.uriFor(cand(ScanProtocol.awg));
    expect(uri, isNotNull);
    expect(uri, contains('162.159.192.7:2408'));
  });

  test('MASQUE-узел несёт IP:port кандидата и правильный network', () {
    final b = ScanNodeBuilder(masque: masque());
    final h3 = b.uriFor(cand(ScanProtocol.masqueH3, ip: '162.159.198.5', port: 443));
    expect(h3, isNotNull);
    expect(h3, startsWith('masque://'));
    expect(h3, contains('162.159.198.5:443'));
    expect(h3, contains('network=h3'));

    final h2 = b.uriFor(cand(ScanProtocol.masqueH2, ip: '162.159.198.5', port: 443));
    expect(h2, contains('network=h2'));
  });

  test('нет аккаунта для протокола → null (caller пропускает)', () {
    final onlyMasque = ScanNodeBuilder(masque: masque());
    expect(onlyMasque.uriFor(cand(ScanProtocol.awg)), isNull);
    final onlyWarp = ScanNodeBuilder(warp: warp());
    expect(onlyWarp.uriFor(cand(ScanProtocol.masqueH3)), isNull);
  });
}
