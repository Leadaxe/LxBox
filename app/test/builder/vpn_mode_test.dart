import 'package:flutter_test/flutter_test.dart';

import 'package:lxbox/services/builder/post_steps.dart';
import 'package:lxbox/services/settings_storage.dart' show VpnModeConfig;

/// Конфиг как в шаблоне (§119): один tun-inbound + route.rules с привязкой
/// resolve/sniff к "tun-in" + hijack-dns без inbound.
Map<String, dynamic> _templateConfig() => {
      'inbounds': <Map<String, dynamic>>[
        {'type': 'tun', 'tag': 'tun-in', 'auto_route': true, 'mtu': 1492},
      ],
      'route': <String, dynamic>{
        'rules': <Map<String, dynamic>>[
          {'action': 'resolve', 'inbound': 'tun-in', 'strategy': 'prefer_ipv4'},
          {'action': 'sniff', 'inbound': 'tun-in', 'timeout': '1s'},
          {'protocol': 'dns', 'action': 'hijack-dns'},
        ],
        'final': 'vpn-1',
      },
    };

List<Map<String, dynamic>> _inbounds(Map<String, dynamic> cfg) =>
    (cfg['inbounds'] as List).cast<Map<String, dynamic>>();

List<Map<String, dynamic>> _rules(Map<String, dynamic> cfg) =>
    ((cfg['route'] as Map)['rules'] as List).cast<Map<String, dynamic>>();

Map<String, dynamic>? _firstWhere(
        List<Map<String, dynamic>> list, bool Function(Map) p) =>
    list.cast<Map<String, dynamic>?>().firstWhere(
          (e) => e != null && p(e),
          orElse: () => null,
        );

const _proxyAuth = VpnModeConfig(
  mode: 'proxy',
  proxyProtocol: 'mixed',
  proxyPort: 2080,
  proxyListen: '127.0.0.1',
  proxyAuthEnabled: true,
  proxyUsername: 'user',
  proxyPassword: 'deadbeef',
);

void main() {
  group('applyVpnMode (§119)', () {
    test('mode=vpn → config не изменён', () {
      final cfg = _templateConfig();
      const m = VpnModeConfig.defaults();
      applyVpnMode(cfg, m, sniffEnabled: true);
      final inb = _inbounds(cfg);
      expect(inb.length, 1);
      expect(inb.first['type'], 'tun');
      expect(_firstWhere(_inbounds(cfg), (i) => i['type'] == 'mixed'), isNull);
      // rules не тронуты — tun-in остаётся.
      expect(_rules(cfg).any((r) => r['inbound'] == 'tun-in'), true);
    });

    test('mode=proxy → tun удалён, mixed добавлен', () {
      final cfg = _templateConfig();
      applyVpnMode(cfg, _proxyAuth, sniffEnabled: true);
      final inb = _inbounds(cfg);
      expect(_firstWhere(inb, (i) => i['type'] == 'tun'), isNull);
      final mixed = _firstWhere(inb, (i) => i['type'] == 'mixed');
      expect(mixed, isNotNull);
      expect(mixed!['tag'], 'mixed-in');
      expect(mixed['listen'], '127.0.0.1');
      expect(mixed['listen_port'], 2080);
      expect(mixed['listen_port'], isA<int>());
    });

    test('mode=proxy → tun-in resolve/sniff re-tag на mixed-in, нет dangling',
        () {
      final cfg = _templateConfig();
      applyVpnMode(cfg, _proxyAuth, sniffEnabled: true);
      final rules = _rules(cfg);
      // Нет ни одного правила с inbound:tun-in.
      expect(rules.any((r) => r['inbound'] == 'tun-in'), false);
      // resolve и sniff теперь на mixed-in.
      expect(
          rules.any((r) => r['action'] == 'resolve' && r['inbound'] == 'mixed-in'),
          true);
      expect(
          rules.any((r) => r['action'] == 'sniff' && r['inbound'] == 'mixed-in'),
          true);
    });

    test('mode=proxy → hijack-dns нетронут', () {
      final cfg = _templateConfig();
      applyVpnMode(cfg, _proxyAuth, sniffEnabled: true);
      final hijack =
          _firstWhere(_rules(cfg), (r) => r['action'] == 'hijack-dns');
      expect(hijack, isNotNull);
      expect(hijack!.containsKey('inbound'), false);
    });

    test('mode=vpn_proxy → оба inbound (tun первый)', () {
      final cfg = _templateConfig();
      applyVpnMode(cfg, _proxyAuth.copyWith(mode: 'vpn_proxy'),
          sniffEnabled: true);
      final inb = _inbounds(cfg);
      expect(inb.length, 2);
      expect(inb.first['type'], 'tun'); // tun остаётся первым (для applyTunPackages)
      expect(_firstWhere(inb, (i) => i['type'] == 'mixed'), isNotNull);
    });

    test('mode=vpn_proxy → mixed-in resolve+sniff добавлены, tun-in сохранены',
        () {
      final cfg = _templateConfig();
      applyVpnMode(cfg, _proxyAuth.copyWith(mode: 'vpn_proxy'),
          sniffEnabled: true);
      final rules = _rules(cfg);
      expect(rules.any((r) => r['inbound'] == 'tun-in'), true);
      expect(
          rules.any((r) => r['action'] == 'resolve' && r['inbound'] == 'mixed-in'),
          true);
      expect(
          rules.any((r) => r['action'] == 'sniff' && r['inbound'] == 'mixed-in'),
          true);
    });

    test('mode=vpn_proxy + sniffEnabled=false → mixed sniff НЕ добавлен, resolve добавлен',
        () {
      final cfg = _templateConfig();
      applyVpnMode(cfg, _proxyAuth.copyWith(mode: 'vpn_proxy'),
          sniffEnabled: false);
      final rules = _rules(cfg);
      expect(
          rules.any((r) => r['action'] == 'sniff' && r['inbound'] == 'mixed-in'),
          false);
      expect(
          rules.any((r) => r['action'] == 'resolve' && r['inbound'] == 'mixed-in'),
          true);
    });

    test('auth: непустой пароль → users присутствует', () {
      final cfg = _templateConfig();
      applyVpnMode(cfg, _proxyAuth, sniffEnabled: true);
      final mixed = _firstWhere(_inbounds(cfg), (i) => i['type'] == 'mixed')!;
      final users = mixed['users'] as List;
      expect(users.length, 1);
      expect((users.first as Map)['username'], 'user');
      expect((users.first as Map)['password'], 'deadbeef');
    });

    test('protocol=mixed (default) → inbound type=mixed', () {
      final cfg = _templateConfig();
      applyVpnMode(cfg, _proxyAuth, sniffEnabled: true);
      final inb = _firstWhere(_inbounds(cfg), (i) => i['tag'] == 'mixed-in')!;
      expect(inb['type'], 'mixed');
    });

    test('protocol=http → inbound type=http (tag остаётся mixed-in)', () {
      final cfg = _templateConfig();
      applyVpnMode(cfg, _proxyAuth.copyWith(proxyProtocol: 'http'),
          sniffEnabled: true);
      final inb = _firstWhere(_inbounds(cfg), (i) => i['tag'] == 'mixed-in')!;
      expect(inb['type'], 'http');
      // auth-структура та же.
      expect((inb['users'] as List).first, {
        'username': 'user',
        'password': 'deadbeef',
      });
    });

    test('protocol=socks → inbound type=socks', () {
      final cfg = _templateConfig();
      applyVpnMode(cfg, _proxyAuth.copyWith(proxyProtocol: 'socks'),
          sniffEnabled: true);
      final inb = _firstWhere(_inbounds(cfg), (i) => i['tag'] == 'mixed-in')!;
      expect(inb['type'], 'socks');
    });

    test('protocol в vpn_proxy → mixed-in type меняется, tun-in нетронут', () {
      final cfg = _templateConfig();
      applyVpnMode(
          cfg, _proxyAuth.copyWith(mode: 'vpn_proxy', proxyProtocol: 'socks'),
          sniffEnabled: true);
      final tun = _firstWhere(_inbounds(cfg), (i) => i['type'] == 'tun');
      expect(tun, isNotNull);
      expect(tun!['tag'], 'tun-in');
      final proxy = _firstWhere(_inbounds(cfg), (i) => i['tag'] == 'mixed-in')!;
      expect(proxy['type'], 'socks');
    });

    test('auth off (127.0.0.1) → users отсутствует', () {
      final cfg = _templateConfig();
      applyVpnMode(cfg, _proxyAuth.copyWith(proxyAuthEnabled: false),
          sniffEnabled: true);
      final mixed = _firstWhere(_inbounds(cfg), (i) => i['type'] == 'mixed')!;
      expect(mixed.containsKey('users'), false);
    });

    test('listen 0.0.0.0 → effectiveAuth форсится, users есть даже при authEnabled=false',
        () {
      final cfg = _templateConfig();
      final m = _proxyAuth.copyWith(
        proxyListen: '0.0.0.0',
        proxyAuthEnabled: false, // снято — но 0.0.0.0 форсит
      );
      expect(m.effectiveAuth, true);
      applyVpnMode(cfg, m, sniffEnabled: true);
      final mixed = _firstWhere(_inbounds(cfg), (i) => i['type'] == 'mixed')!;
      expect(mixed.containsKey('users'), true);
      expect(mixed['listen'], '0.0.0.0');
    });

    test('пустой пароль при auth → users отсутствует (defensive)', () {
      final cfg = _templateConfig();
      applyVpnMode(cfg, _proxyAuth.copyWith(proxyPassword: ''),
          sniffEnabled: true);
      final mixed = _firstWhere(_inbounds(cfg), (i) => i['type'] == 'mixed')!;
      expect(mixed.containsKey('users'), false);
    });

    test('interaction: proxy + applyTunPackages → no-op (tun уже удалён)', () {
      final cfg = _templateConfig();
      applyVpnMode(cfg, _proxyAuth, sniffEnabled: true);
      // applyTunPackages должен no-op'нуть — tun-inbound нет.
      expect(_firstWhere(_inbounds(cfg), (i) => i['type'] == 'tun'), isNull);
    });

    test('inbounds key missing → silent no-op (no throw)', () {
      final cfg = <String, dynamic>{};
      expect(
        () => applyVpnMode(cfg, _proxyAuth, sniffEnabled: true),
        returnsNormally,
      );
    });
  });

  group('VpnModeConfig model (§119)', () {
    test('predicates', () {
      const vpn = VpnModeConfig.defaults();
      expect(vpn.isVpn, true);
      expect(vpn.hasTun, true);
      expect(vpn.hasMixed, false);

      final proxy = vpn.copyWith(mode: 'proxy');
      expect(proxy.isProxy, true);
      expect(proxy.hasTun, false);
      expect(proxy.hasMixed, true);

      final both = vpn.copyWith(mode: 'vpn_proxy');
      expect(both.isVpnProxy, true);
      expect(both.hasTun, true);
      expect(both.hasMixed, true);
    });

    test('effectiveAuth: 0.0.0.0 форсит on', () {
      const m = VpnModeConfig(
        mode: 'proxy',
        proxyProtocol: 'mixed',
        proxyPort: 2080,
        proxyListen: '0.0.0.0',
        proxyAuthEnabled: false,
        proxyUsername: 'user',
        proxyPassword: 'x',
      );
      expect(m.isPublicListen, true);
      expect(m.effectiveAuth, true);
    });

    test('effectiveAuth: 127.0.0.1 уважает authEnabled', () {
      const off = VpnModeConfig(
        mode: 'proxy',
        proxyProtocol: 'mixed',
        proxyPort: 2080,
        proxyListen: '127.0.0.1',
        proxyAuthEnabled: false,
        proxyUsername: 'user',
        proxyPassword: 'x',
      );
      expect(off.effectiveAuth, false);
    });

    test('toJson round-trip keys', () {
      final json = _proxyAuth.toJson();
      expect(json['mode'], 'proxy');
      expect(json['proxy_protocol'], 'mixed');
      expect(json['proxy_port'], 2080);
      expect(json['proxy_listen'], '127.0.0.1');
      expect(json['proxy_auth_enabled'], true);
      expect(json['proxy_username'], 'user');
      expect(json['proxy_password'], 'deadbeef');
    });

    test('protocol constants', () {
      expect(VpnModeConfig.protoMixed, 'mixed');
      expect(VpnModeConfig.protoHttp, 'http');
      expect(VpnModeConfig.protoSocks, 'socks');
      expect(const VpnModeConfig.defaults().proxyProtocol, 'mixed');
    });

    test('defaults = vpn mode (backward-compat)', () {
      const d = VpnModeConfig.defaults();
      expect(d.mode, 'vpn');
      expect(d.proxyPort, 2080);
      expect(d.proxyListen, '127.0.0.1');
    });
  });
}
