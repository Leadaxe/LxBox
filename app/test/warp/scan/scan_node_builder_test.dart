import 'package:flutter_test/flutter_test.dart';
import 'package:lxbox/models/template_vars.dart';
import 'package:lxbox/services/parser/uri_parsers/wireguard_parser.dart';
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

  test('§305 MASQUE h3 И h2 → IP:port кандидата (форсинг h3→server снят)', () {
    // Боевой тест (пинг через рабочий туннель) опроверг привязку h3 к серверу
    // реги: h3 живёт на чужих IP блока. Оба транспорта берут endpoint кандидата.
    final b = ScanNodeBuilder(masque: masque());

    final h3 = b.uriFor(
        cand(ScanProtocol.masqueH3, ip: '162.159.199.5', port: 4443));
    expect(h3, isNotNull);
    expect(h3, startsWith('masque://'));
    expect(h3, contains('162.159.199.5:4443'), reason: 'h3 — IP:port кандидата');
    expect(h3, isNot(contains('162.159.198.1')), reason: 'НЕ server из аккаунта');
    expect(h3, contains('network=h3'));

    final h2 = b.uriFor(
        cand(ScanProtocol.masqueH2, ip: '162.159.198.5', port: 8443));
    expect(h2, contains('162.159.198.5:8443'), reason: 'h2 — IP:port кандидата');
    expect(h2, contains('network=h2'));
  });

  test('нет аккаунта для протокола → null (caller пропускает)', () {
    final onlyMasque = ScanNodeBuilder(masque: masque());
    expect(onlyMasque.uriFor(cand(ScanProtocol.awg)), isNull);
    final onlyWarp = ScanNodeBuilder(warp: warp());
    expect(onlyWarp.uriFor(cand(ScanProtocol.masqueH3)), isNull);
  });

  group('§313 keepalive из пула', () {
    ScanCandidate awgCand() => ScanCandidate(
          ip: '162.159.192.7',
          port: 2408,
          protocol: ScanProtocol.awg,
          sni: 'yandex.ru',
          awgParams: const AwgParams(ip: 'quic', jc: 4, jmin: 40, jmax: 70),
        );

    /// URI узла → эмит sing-box (то, что реально уйдёт в ядро).
    Map<String, dynamic> emitOf(String uri) =>
        parseWireguardUri(uri)!.emit(TemplateVars.empty).map;

    test('пул с keepalive → в узле persistent_keepalive_interval', () {
      final b = ScanNodeBuilder(warp: warp(), wgKeepalive: 25);
      final uri = b.uriFor(awgCand())!;
      expect(Uri.parse(uri).queryParameters['keepalive'], '25');
      final peers = emitOf(uri)['peers'] as List;
      expect((peers.first as Map)['persistent_keepalive_interval'], 25);
    });

    test('ключа нет в JSON (дефолт 0) → генерация цела, keepalive не пишется',
        () {
      final b = ScanNodeBuilder(warp: warp());
      final uri = b.uriFor(awgCand());
      expect(uri, isNotNull, reason: 'генерация не падает без keepalive');
      final peers = emitOf(uri!)['peers'] as List;
      expect((peers.first as Map).containsKey('persistent_keepalive_interval'),
          isFalse);
    });

    test('keepalive=0 → не пишется (гейт > 0 в WarpAccount)', () {
      final b = ScanNodeBuilder(warp: warp(), wgKeepalive: 0);
      final uri = b.uriFor(awgCand())!;
      expect(Uri.parse(uri).queryParameters.containsKey('keepalive'), isFalse);
    });

    test('MASQUE-ветка от wgKeepalive не зависит', () {
      final b = ScanNodeBuilder(masque: masque(), wgKeepalive: 25);
      final uri = b.uriFor(cand(ScanProtocol.masqueH3))!;
      expect(uri, startsWith('masque://'));
      expect(uri, isNot(contains('keepalive=25')));
    });
  });

  test('заголовок узла (nodeTitle) проносится в фрагмент URI', () {
    final b = ScanNodeBuilder(warp: warp(), masque: masque());

    final awg = ScanCandidate(
      ip: '162.159.192.7',
      port: 2408,
      protocol: ScanProtocol.awg,
      sni: 'ya.ru',
      awgParams: const AwgParams(ip: 'quic', jc: 4, jmin: 40, jmax: 70),
    );
    final awgUri = Uri.decodeComponent(b.uriFor(awg)!);
    expect(awgUri, contains('WARP AWG (quic ya.ru)'));

    final h3 = b.uriFor(cand(ScanProtocol.masqueH3, ip: '162.159.198.5', port: 443))!;
    expect(Uri.decodeComponent(h3), contains('WARP MASQUE (h3: yandex.ru)'));
  });
}
