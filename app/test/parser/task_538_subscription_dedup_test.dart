/// §538 — повтор узла внутри одной подписки схлопывается по подписи §480.
///
/// Живой вход — подписка D: один AWG-узел строкой `amneziawg://` и тем же
/// узлом в сжатом контейнере `vpn://`. Значения ниже замаскированы: ключи —
/// синтетические, адреса — из документационных диапазонов.
library;

import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:lxbox/models/node_warning.dart';
import 'package:lxbox/services/contract/warning_codes.dart';
import 'package:lxbox/services/l10n/locale_controller.dart';
import 'package:lxbox/services/parser/body_decoder.dart';
import 'package:lxbox/services/parser/parse_all.dart';

import 'engine_test_setup.dart';

const _priv = 'AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA=';
const _pub = 'AQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQE=';
const _psk = 'AgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgI=';
const _hpk = 'AwMDAwMDAwMDAwMDAwMDAwMDAwMDAwMDAwMDAwMDAwM=';
const _host = 'awg.example.com';

String _q(String v) => Uri.encodeQueryComponent(v);

String _awgLink(String name, {String priv = _priv}) =>
    'amneziawg://${_q(priv)}@$_host:44896'
    '?address=${_q('10.8.1.2/32')}&dns=1.1.1.1'
    '&h1=1&h2=2&h3=3&h4=4&headerprotectionkey=${_q(_hpk)}'
    '&jc=5&jmax=50&jmin=10&mtu=1420'
    '&presharedkey=${_q(_psk)}&publickey=${_q(_pub)}'
    '&s1=89&s2=86&s3=29&s4=12#${Uri.encodeComponent(name)}';

/// Контейнер Amnezia в форме qCompress: 4 байта длины + zlib, base64url.
String _vpnLink(String name) {
  final ini = '[Interface]\n'
      'PrivateKey = $_priv\n'
      'Address = 10.8.1.2/32\n'
      'DNS = 1.1.1.1\n'
      'MTU = 1420\n'
      'Jc = 5\nJmin = 10\nJmax = 50\n'
      'S1 = 89\nS2 = 86\nS3 = 29\nS4 = 12\n'
      'H1 = 1\nH2 = 2\nH3 = 3\nH4 = 4\n'
      'HeaderProtectionKey = $_hpk\n'
      '\n[Peer]\n'
      'PublicKey = $_pub\n'
      'PresharedKey = $_psk\n'
      'AllowedIPs = 0.0.0.0/0, ::/0\n'
      'Endpoint = $_host:44896\n';
  final export = {
    'containers': [
      {
        'awg': {
          'isThirdPartyConfig': true,
          'last_config': jsonEncode({'config': ini, 'mtu': '1420'}),
          'port': '44896',
          'protocol_version': '3',
          'transport_proto': 'udp',
        },
        'container': 'amnezia-awg',
      },
    ],
    'defaultContainer': 'amnezia-awg',
    'description': name,
    'dns1': '1.1.1.1',
    'hostName': _host,
  };
  final raw = utf8.encode(jsonEncode(export));
  final payload = [
    (raw.length >> 24) & 0xff,
    (raw.length >> 16) & 0xff,
    (raw.length >> 8) & 0xff,
    raw.length & 0xff,
    ...zlib.encode(raw),
  ];
  return 'vpn://${base64Url.encode(payload).replaceAll('=', '')}';
}

void main() {
  setUpAll(loadEngineSections);

  test('`amneziawg://` и `vpn://` одного узла — один узел и `duplicate`', () {
    const name = 'CH-example-awg3 AWG';
    final dropped = <NodeWarning>[];
    final nodes = parseAll(
        decode('${_awgLink(name)}\n${_vpnLink(name)}'),
        dropped: dropped);

    expect(nodes, hasLength(1));
    expect(nodes.single.tag, name, reason: 'выживает первая запись');
    final dupes = dropped.whereType<DuplicateNodeWarning>().toList();
    expect(dupes, hasLength(1));
    expect(warningCodeOf(dupes.single), 'duplicate');
    expect(dupes.single.winner, isEmpty, reason: 'имена совпали');
  });

  test('имя дубликата другое — предупреждение называет выжившего', () {
    final dropped = <NodeWarning>[];
    final nodes = parseAll(
        decode('${_awgLink('first')}\n${_vpnLink('second')}'),
        dropped: dropped);

    expect(nodes.map((n) => n.tag), ['first']);
    final dupe = dropped.whereType<DuplicateNodeWarning>().single;
    expect(dupe.winner, 'first');
    expect(dupe.messageWith(getLocalText), contains('first'));
  });

  test('разные ключи — два узла, дедупа нет', () {
    final dropped = <NodeWarning>[];
    final nodes = parseAll(
        decode('${_awgLink('a')}\n'
            '${_awgLink('b', priv: 'BAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQ=')}'),
        dropped: dropped);

    expect(nodes, hasLength(2));
    expect(dropped.whereType<DuplicateNodeWarning>(), isEmpty);
  });
}
