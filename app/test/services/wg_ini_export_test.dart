import 'package:flutter_test/flutter_test.dart';
import 'package:lxbox/models/node_spec.dart';
import 'package:lxbox/models/template_vars.dart';
import 'package:lxbox/services/parser/ini_parser.dart';
import 'package:lxbox/services/parser/uri_parsers.dart';
import 'package:lxbox/services/wireguard/wg_ini_export.dart';

import '../parser/engine_test_setup.dart';

const _priv = 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaA=';
const _pub = 'bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbA=';
const _psk = 'ccccccccccccccccccccccccccccccccccccccccccA=';
const _pub2 = 'ddddddddddddddddddddddddddddddddddddddddddA=';

/// Тело узла без тега: тег — поле записи, не источника.
Map<String, dynamic> _body(NodeSpec n) =>
    Map<String, dynamic>.from(n.emit(TemplateVars.empty).map)..remove('tag');

// §686 п. 9 — вкладка INI: `.conf` обратным ходом таблицы `conf` реестра.
void main() {
  setUpAll(loadEngineSections);

  /// Ссылка → INI вкладки → разбор INI → то же тело.
  void roundTrip(String link) {
    final node = parseUri(link) as WireguardSpec;
    final ini = wireguardIniOf(node.emit(TemplateVars.empty).map)!;
    expect(ini.lost, isEmpty, reason: ini.text);
    final back = parseWireguardIni(ini.text, nameHint: node.tag);
    expect(back, isNotNull, reason: ini.text);
    expect(_body(back!), _body(node), reason: ini.text);
  }

  test('AWG-ссылка с I1 → INI → то же тело', () {
    const i1 = '<b 0x000100002112a442><r 12>';
    roundTrip('awg://$_priv@host.example.com:51821'
        '?publickey=$_pub&presharedkey=${Uri.encodeQueryComponent(_psk)}'
        '&address=10.0.0.2/32,fd00::2/128&allowedips=0.0.0.0/0,::/0'
        '&mtu=1280&keepalive=25&disablecookies=on'
        '&jc=10&jmin=50&jmax=100&s1=20&s2=20&s3=60&s4=60'
        '&h1=1234567890&h2=1234567891&h3=1234567892&h4=1234567893'
        '&i1=${Uri.encodeQueryComponent(i1)}#awg-server');
  });

  test('маскировка ip/id/ib переносится ключами Ip/Id/Ib', () {
    const link = 'awg://$_priv@h.example:51820'
        '?publickey=$_pub&address=10.0.0.2/32'
        '&jc=3&jmin=40&jmax=70&ip=quic&id=www.example.org&ib=firefox#m';
    roundTrip(link);
    final node = parseUri(link)!;
    final text = wireguardIniOf(node.emit(TemplateVars.empty).map)!.text;
    expect(text, contains('Ip = quic'));
    expect(text, contains('Id = www.example.org'));
    expect(text, contains('Ib = firefox'));
  });

  test('WG-ссылка: reserved, IPv6 Endpoint', () {
    roundTrip('wireguard://$_priv@[2001:db8::1]:2408'
        '?publickey=$_pub&address=172.16.0.2/32&reserved=1,2,3#wg');
  });

  test('ключ тела вне таблицы → «Not in INI», без него строки нет', () {
    final node = parseUri('wireguard://$_priv@h.example:51820'
        '?publickey=$_pub&address=10.0.0.2/32#j')!;
    final body = node.emit(TemplateVars.empty).map;
    expect(wireguardIniOf(body)!.lost, isEmpty);
    final peers = (body['peers'] as List).cast<Map<String, dynamic>>();
    final extra = {
      ...body,
      'workers': 2,
      'peers': [
        {...peers.single, 'foo': 'x'},
      ],
    };
    expect(wireguardIniOf(extra)!.lost,
        unorderedEquals(['workers', 'peers[].foo']));
  });

  test('два пира → две секции [Peer] → два пира после разбора', () {
    final node = parseUri('wireguard://$_priv@a.example:51820'
        '?publickey=$_pub&address=10.0.0.2/32&allowedips=10.1.0.0/16#two')!;
    final body = node.emit(TemplateVars.empty).map;
    final first = (body['peers'] as List).single as Map<String, dynamic>;
    final two = {
      ...body,
      'peers': [
        first,
        {
          'address': 'b.example',
          'port': 51821,
          'public_key': _pub2,
          'allowed_ips': ['10.2.0.0/16'],
        },
      ],
    };
    final ini = wireguardIniOf(two)!;
    expect('[Peer]'.allMatches(ini.text), hasLength(2));
    expect(ini.text.indexOf('a.example:51820'),
        lessThan(ini.text.indexOf('b.example:51821')));
    final back = parseWireguardIni(ini.text, nameHint: 'two')!;
    expect(back.peers, hasLength(2));
    expect(_body(back)['peers'], two['peers']);
  });

  test('имя файла от тега', () {
    expect(wireguardIniFileName('🇩🇪 DE #1'), 'DE_1.conf');
    expect(wireguardIniFileName(''), 'wireguard.conf');
  });
}
