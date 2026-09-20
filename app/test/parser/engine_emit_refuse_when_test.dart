import 'package:flutter_test/flutter_test.dart';
import 'package:lxbox/services/parser/engine/emitter.dart';
import 'package:lxbox/services/parser/engine/section.dart';
import 'package:lxbox/services/parser/engine/section_loader.dart';

import 'engine_test_setup.dart';

/// Тело WireGuard, как его отдаёт готовый sing-box JSON: несколько `peers`.
///
/// Ссылка выражает одного пира; реестр объявляет `emit.refuse_when` на
/// `peers.length > 1`. Эмиттер обязан отказать, а не отдать первого.
const _priv = 'AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA=';
const _pub1 = 'AQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQE=';
const _pub2 = 'AgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgI=';

Map<String, dynamic> _peer(String host, int port, String pub,
        [List<String> ips = const ['0.0.0.0/0', '::/0']]) =>
    {
      'address': host,
      'port': port,
      'public_key': pub,
      'allowed_ips': ips,
    };

Map<String, dynamic> _body(List<Map<String, dynamic>> peers) => {
      'type': 'wireguard',
      'tag': 'wg-multi',
      'address': ['10.0.0.2/32'],
      'private_key': _priv,
      'peers': peers,
    };

void main() {
  setUpAll(loadEngineSections);

  MapperSection section() => MapperSections.I.sectionFor('uri', 'wireguard')!;

  test('два peers — эмит отказывает, ссылки нет', () {
    final r = emitViaSection(
      section(),
      _body([
        _peer('h1.example', 51820, _pub1),
        _peer('h2.example', 51821, _pub2, const ['10.0.0.0/8']),
      ]),
      'wg-multi',
    );
    expect(r, isNotNull);
    expect(r!.uri, isEmpty,
        reason: 'Copy link на пустой строке молча не копирует — '
            'тот же путь, что у схемы без share_uri');
  });

  test('один peer — ссылка прежняя', () {
    final one = _body([_peer('h.example-1.com', 51820, _pub1)]);
    one['tag'] = 'wg';
    final r = emitViaSection(section(), one, 'wg')!;
    expect(r.uri, isNotEmpty);
    expect(r.uri, startsWith('wireguard://'));
    expect(r.lost, isEmpty);
    // Повторный эмит того же тела — байт в байт.
    expect(emitViaSection(section(), one, 'wg')!.uri, r.uri);
  });
}
