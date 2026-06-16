import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:lxbox/models/node_spec.dart';
import 'package:lxbox/services/parser/ini_parser.dart';
import 'package:lxbox/services/warp/awg_junk.dart';
import 'package:lxbox/services/warp/warp_account.dart';
import 'package:lxbox/services/warp/warp_client.dart';

/// §126 — WARP + AmneziaWG 1.5 обфускация: preset, .conf round-trip, persist.
void main() {
  // client_id «AQID» = base64([1,2,3]).
  final clientId = base64.encode([1, 2, 3]);

  WarpAccount account({Awg? awg}) => WarpAccount(
        privKey: 'PRIVKEYBASE64',
        peerPub: 'PEERPUBBASE64',
        clientV4: '172.16.0.2',
        clientV6: '2606:4700:110::1',
        clientId: clientId,
        accountId: 'acc',
        deviceId: 'dev',
        token: 'tok',
        endpoint: WarpAccount.defaultEndpoint,
        createdAt: '2026-06-15T00:00:00Z',
        awg: awg,
      );

  group('WarpClient — preset (§126/§136)', () {
    test('preset: s1=s2=0, h1..h4=1,2,3,4, jc=4 (handshake остаётся plain WG)',
        () {
      final p = WarpClient.amneziaPreset();
      expect(p['s1'], 0);
      expect(p['s2'], 0);
      expect(p['h1'], 1);
      expect(p['h2'], 2);
      expect(p['h3'], 3);
      expect(p['h4'], 4);
      expect(p['jc'], 4);
      expect(p['jmin'], 40);
      expect(p['jmax'], 70);
      expect(p.containsKey('i1'), isFalse); // i1 генерится отдельно
    });

    test('§136 preset с кастомными jc/jmin/jmax', () {
      final p = WarpClient.amneziaPreset(jc: 120, jmin: 23, jmax: 911);
      expect(p['jc'], 120);
      expect(p['jmin'], 23);
      expect(p['jmax'], 911);
      expect(p['s1'], 0); // S/H не трогаются
      expect(p['h1'], 1);
    });

    test('buildAmneziaAwg(quic): preset + QUIC i1 (сплошной <b>, как рабочий)',
        () {
      final awg = WarpClient.buildAmneziaAwg(JunkTemplate.quic);
      expect(awg.fields['jc'], 4);
      expect(awg.fields['i1'], isA<String>());
      final i1 = awg.fields['i1'] as String;
      expect(i1.startsWith('<b 0x'), isTrue);
      // §136 — сплошной <b>, БЕЗ <r> (узел с <r> у Ильи НЕ работал).
      expect(i1.contains('<r '), isFalse);
      // Уникальность i1 между двумя сборками (рандомный DCID/random).
      final awg2 = WarpClient.buildAmneziaAwg(JunkTemplate.quic);
      expect(awg.fields['i1'], isNot(awg2.fields['i1']));
    });

    test('buildAmneziaAwg(quic): QuicParams применяются (jc/jmin/jmax)', () {
      final awg = WarpClient.buildAmneziaAwg(JunkTemplate.quic,
          params: const QuicParams(
              sni: 'a.io', level: 1, jc: 7, jmin: 10, jmax: 20));
      expect(awg.fields['jc'], 7);
      expect(awg.fields['jmin'], 10);
      expect(awg.fields['jmax'], 20);
    });

    test('buildAmneziaAwg(sip): preset + SIP i1', () {
      final awg = WarpClient.buildAmneziaAwg(JunkTemplate.sip);
      final i1 = awg.fields['i1'] as String;
      expect(i1.startsWith('<b 0x'), isTrue);
      expect(i1.contains('<r '), isFalse); // SIP = сплошной <b>
    });
  });

  group('WarpAccount.toWireguardConf', () {
    test('plain (awg==null): валидный .conf, reserved в [Peer], без AWG', () {
      final conf = account().toWireguardConf();
      expect(conf.contains('[Interface]'), isTrue);
      expect(conf.contains('[Peer]'), isTrue);
      expect(conf.contains('PrivateKey = PRIVKEYBASE64'), isTrue);
      expect(conf.contains('Reserved = 1,2,3'), isTrue);
      expect(conf.contains('MTU = 1280'), isTrue);
      expect(conf.contains('Jc'), isFalse);
    });

    test('obfuscated: AWG-поля в [Interface], i1 присутствует', () {
      final awg = WarpClient.buildAmneziaAwg(JunkTemplate.quic);
      final conf = account(awg: awg).toWireguardConf();
      expect(conf.contains('JC = 4'), isTrue);
      expect(conf.contains('H1 = 1'), isTrue);
      expect(conf.contains('I1 = <b 0x'), isTrue);
    });
  });

  group('.conf → parseWireguardIni round-trip', () {
    test('obfuscated: AWG + reserved доходят до WireguardSpec/endpoint-JSON', () {
      final awg = WarpClient.buildAmneziaAwg(JunkTemplate.sip);
      final i1 = awg.fields['i1'] as String;
      final conf = account(awg: awg).toWireguardConf();

      final spec = parseWireguardIni(conf);
      expect(spec, isNotNull);
      // AWG долетел.
      expect(spec!.awg, isNotNull);
      expect(spec.awg!.fields['jc'], 4);
      expect(spec.awg!.fields['s1'], 0);
      expect(spec.awg!.fields['h4'], 4);
      expect(spec.awg!.fields['i1'], i1); // регистр/содержимое i1 не потеряны
      // reserved (WARP client_id) долетел в peer.
      expect(spec.peers, isNotEmpty);
      expect(spec.peers.first.reserved, [1, 2, 3]);
    });

    test('plain .conf тоже несёт reserved (regression для §126 ini-фикса)', () {
      final spec = parseWireguardIni(account().toWireguardConf());
      expect(spec, isNotNull);
      expect(spec!.awg, isNull);
      expect(spec.peers.first.reserved, [1, 2, 3]);
    });
  });

  group('WarpAccount persist (storage JSON)', () {
    test('awg round-trips через toJson/fromJson', () {
      final awg = WarpClient.buildAmneziaAwg(JunkTemplate.quic);
      final acc = account(awg: awg);
      final back = WarpAccount.fromJson(acc.toJson());
      expect(back, isNotNull);
      expect(back!.awg, isNotNull);
      expect(back.awg!.fields['jc'], 4);
      expect(back.awg!.fields['i1'], awg.fields['i1']);
    });

    test('plain (awg==null): нет ключа awg, fromJson → null', () {
      final acc = account();
      expect(acc.toJson().containsKey('awg'), isFalse);
      expect(WarpAccount.fromJson(acc.toJson())!.awg, isNull);
    });

    test('copyWith(clearAwg) снимает обфускацию', () {
      final acc = account(awg: WarpClient.buildAmneziaAwg(JunkTemplate.quic));
      expect(acc.awg, isNotNull);
      expect(acc.copyWith(clearAwg: true).awg, isNull);
    });

    test('§138 copyWith(endpoint) применяет новый endpoint к аккаунту', () {
      // Корень бага: закешированный аккаунт с дефолтным endpoint; юзер выбрал
      // свой в Advanced. Без применения endpoint в узел шёл старый из кеша.
      final cached = account(); // endpoint = defaultEndpoint
      expect(cached.endpoint, WarpAccount.defaultEndpoint);
      final updated = cached.copyWith(endpoint: '188.114.97.6:988');
      expect(updated.endpoint, '188.114.97.6:988');
      // остальное (ключи) не теряется.
      expect(updated.privKey, cached.privKey);
      expect(updated.peerPub, cached.peerPub);
      // и доходит до .conf/URI узла.
      expect(updated.toWireguardUri(), contains('188.114.97.6:988'));
    });
  });
}
