import 'package:flutter_test/flutter_test.dart';
import 'package:lxbox/services/builder/post_steps.dart';

// §691 — «Bypass the tunnel» (`tun.route_exclude_address`): строка не-CIDR
// роняет ядро на разборе префикса, строка, накрывающая адрес TUN, отправляет
// мимо туннеля его же DNS-перехват.

Map<String, dynamic> _config(List<Object> exclude) => {
      'inbounds': [
        {
          'type': 'tun',
          'tag': 'tun-in',
          'address': ['172.16.0.1/30', 'fdfe:dcba:9876::1/126'],
          'route_exclude_address': exclude,
        },
      ],
    };

Map<String, dynamic> _tun(Map<String, dynamic> c) =>
    (c['inbounds'] as List).first as Map<String, dynamic>;

void main() {
  test('валидные исключения остаются как есть', () {
    final c = _config(['192.168.0.0/16', '10.0.0.0/8', 'fd12:3456::/48']);
    expect(healTunRouteExclude(c), isEmpty);
    expect(_tun(c)['route_exclude_address'],
        ['192.168.0.0/16', '10.0.0.0/8', 'fd12:3456::/48']);
  });

  test('не-CIDR снимается с предупреждением', () {
    final c =
        _config(['192.168.1.10', 'nas.local', '10.0.0.0/33', '192.168.0.0/16']);
    final w = healTunRouteExclude(c);
    expect(w, hasLength(3));
    expect(w.first, contains('"192.168.1.10"'));
    expect(_tun(c)['route_exclude_address'], ['192.168.0.0/16']);
  });

  test('накрывающее адрес TUN снимается: IPv4 и IPv6', () {
    final c =
        _config(['172.16.0.0/12', 'fdfe::/16', '0.0.0.0/0', '192.168.0.0/16']);
    final w = healTunRouteExclude(c);
    expect(w, hasLength(3));
    expect(w.every((s) => s.contains("tunnel's own address")), isTrue);
    expect(_tun(c)['route_exclude_address'], ['192.168.0.0/16']);
  });

  test('соседняя сеть без адреса TUN остаётся', () {
    final c = _config(['172.16.0.4/30', '172.17.0.0/16']);
    expect(healTunRouteExclude(c), isEmpty);
    expect(
        _tun(c)['route_exclude_address'], ['172.16.0.4/30', '172.17.0.0/16']);
  });

  test('всё снято — ключа нет', () {
    final c = _config(['garbage']);
    expect(healTunRouteExclude(c), hasLength(1));
    expect(_tun(c).containsKey('route_exclude_address'), isFalse);
  });

  test('без tun-inbound и без ключа — ничего', () {
    expect(
        healTunRouteExclude({
          'inbounds': [
            {'type': 'mixed'}
          ]
        }),
        isEmpty);
    final c = {
      'inbounds': [
        {
          'type': 'tun',
          'address': ['172.16.0.1/30']
        },
      ],
    };
    expect(healTunRouteExclude(c), isEmpty);
    expect(_tun(c).containsKey('route_exclude_address'), isFalse);
  });
}
