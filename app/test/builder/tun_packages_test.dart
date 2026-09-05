import 'package:flutter_test/flutter_test.dart';

import 'package:lxbox/services/builder/post_steps.dart';
import 'package:lxbox/services/settings_storage.dart' show TunAppsConfig;

Map<String, dynamic> _configWithTun() => {
      'inbounds': [
        {
          'type': 'tun',
          'tag': 'tun-in',
          'mtu': 1492,
        },
      ],
    };

Map<String, dynamic> _configWithoutTun() => {
      'inbounds': [
        {'type': 'mixed', 'tag': 'mixed-in'},
      ],
    };

void main() {
  group('applyTunPackages (§046)', () {
    test('mode=off → no changes to tun-inbound', () {
      final cfg = _configWithTun();
      applyTunPackages(
        cfg,
        const TunAppsConfig(mode: 'off', packages: ['com.example']),
      );
      final tun = (cfg['inbounds'] as List).first as Map<String, dynamic>;
      expect(tun.containsKey('include_package'), false);
      expect(tun.containsKey('exclude_package'), false);
    });

    test('mode=off + non-empty packages → no changes (mode wins)', () {
      final cfg = _configWithTun();
      applyTunPackages(
        cfg,
        const TunAppsConfig(
          mode: 'off',
          packages: ['ru.tinkoff.investing', 'com.android.chrome'],
        ),
      );
      final tun = (cfg['inbounds'] as List).first as Map<String, dynamic>;
      expect(tun.containsKey('include_package'), false);
      expect(tun.containsKey('exclude_package'), false);
    });

    test('mode=allow + empty packages → no changes', () {
      final cfg = _configWithTun();
      applyTunPackages(
        cfg,
        const TunAppsConfig(mode: 'allow', packages: []),
      );
      final tun = (cfg['inbounds'] as List).first as Map<String, dynamic>;
      expect(tun.containsKey('include_package'), false);
      expect(tun.containsKey('exclude_package'), false);
    });

    test('mode=allow + 2 pkgs → tun.include_package = [pkg1, pkg2]', () {
      final cfg = _configWithTun();
      applyTunPackages(
        cfg,
        const TunAppsConfig(
          mode: 'allow',
          packages: ['org.telegram.messenger', 'com.android.chrome'],
        ),
      );
      final tun = (cfg['inbounds'] as List).first as Map<String, dynamic>;
      expect(tun['include_package'],
          equals(['org.telegram.messenger', 'com.android.chrome']));
      expect(tun.containsKey('exclude_package'), false);
    });

    test('mode=deny + 1 pkg → tun.exclude_package = [pkg1]', () {
      final cfg = _configWithTun();
      applyTunPackages(
        cfg,
        const TunAppsConfig(
          mode: 'deny',
          packages: ['ru.tinkoff.investing'],
        ),
      );
      final tun = (cfg['inbounds'] as List).first as Map<String, dynamic>;
      expect(tun['exclude_package'], equals(['ru.tinkoff.investing']));
      expect(tun.containsKey('include_package'), false);
    });

    test('no tun-inbound в config → silent no-op', () {
      final cfg = _configWithoutTun();
      applyTunPackages(
        cfg,
        const TunAppsConfig(mode: 'allow', packages: ['com.example']),
      );
      // mixed-inbound НЕ должен получить include_package
      final mixed = (cfg['inbounds'] as List).first as Map<String, dynamic>;
      expect(mixed.containsKey('include_package'), false);
      expect(mixed.containsKey('exclude_package'), false);
    });

    test('inbounds key missing → silent no-op (no throw)', () {
      final cfg = <String, dynamic>{};
      expect(
        () => applyTunPackages(
          cfg,
          const TunAppsConfig(mode: 'allow', packages: ['com.example']),
        ),
        returnsNormally,
      );
      expect(cfg.containsKey('inbounds'), false);
    });

    test('multiple tun inbounds — only first gets the field', () {
      final cfg = <String, dynamic>{
        'inbounds': <Map<String, dynamic>>[
          <String, dynamic>{'type': 'tun', 'tag': 'tun-1'},
          <String, dynamic>{'type': 'tun', 'tag': 'tun-2'},
        ],
      };
      applyTunPackages(
        cfg,
        const TunAppsConfig(mode: 'deny', packages: ['com.example']),
      );
      final inbounds = cfg['inbounds'] as List;
      expect((inbounds[0] as Map)['exclude_package'], equals(['com.example']));
      expect((inbounds[1] as Map).containsKey('exclude_package'), false);
    });

    test('TunAppsConfig predicates', () {
      expect(const TunAppsConfig(mode: 'off', packages: []).isOff, true);
      expect(const TunAppsConfig(mode: 'allow', packages: []).isAllow, true);
      expect(const TunAppsConfig(mode: 'deny', packages: []).isDeny, true);
      expect(const TunAppsConfig(mode: 'direct', packages: []).isDirect, true);
    });
  });
  group('Direct (lockdown)', () {
    const selected = TunAppsConfig(mode: 'direct', packages: ['com.example']);

    test('apps stay in the VPN; DNS precedes direct and routing follows', () {
      final cfg = _configWithTun();
      final tun = (cfg['inbounds'] as List).single as Map;
      tun['include_package'] = ['com.other'];
      tun['exclude_package'] = selected.packages;
      final processing = [
        {
          'action': 'sniff',
          'inbound': ['tun-in'],
        },
        {'action': 'hijack-dns', 'protocol': 'dns'},
        {'action': 'resolve'},
      ];
      final routing = [
        {'package_name': selected.packages, 'action': 'reject'},
        {'outbound': 'vpn-1'},
      ];
      cfg['route'] = <String, dynamic>{
        'rules': [...processing, ...routing],
        'find_process': false,
        'auto_detect_interface': false,
        'final': 'vpn-1',
      };
      final dns = {
        'rules': [
          {'server': 'fakeip'},
        ],
        'final': 'dns-proxy',
      };
      cfg['dns'] = dns;

      applyTunPackages(cfg, selected);

      expect(tun.containsKey('include_package'), isFalse);
      expect(tun.containsKey('exclude_package'), isFalse);
      final route = cfg['route'] as Map;
      final rules = route['rules'] as List;
      expect(rules.take(processing.length), processing);
      expect(rules[processing.length], {
        'inbound': ['tun-in'],
        'package_name': selected.packages,
        'action': 'route',
        'outbound': 'direct-out',
      });
      expect(rules.skip(processing.length + 1), routing);
      expect(route['final'], 'vpn-1');
      expect(route['find_process'], isTrue);
      expect(route['auto_detect_interface'], isTrue);
      expect(cfg['dns'], same(dns));
    });

    test('VPN+Proxy: direct is scoped to tun and leaves mixed-in alone', () {
      final cfg = _configWithTun();
      (cfg['inbounds'] as List).add({'type': 'mixed', 'tag': 'mixed-in'});
      applyTunPackages(cfg, selected);
      expect(cfg['route']['rules'].single['inbound'], ['tun-in']);
      expect((cfg['inbounds'] as List).last, {
        'type': 'mixed',
        'tag': 'mixed-in',
      });
    });

    test('Proxy without tun: no new routes', () {
      final cfg = _configWithoutTun();
      applyTunPackages(cfg, selected);
      expect(cfg.containsKey('route'), isFalse);
      expect((cfg['inbounds'] as List).single, {
        'type': 'mixed',
        'tag': 'mixed-in',
      });
    });

    test('an empty list must not route every app directly', () {
      final cfg = _configWithTun();
      final tun = (cfg['inbounds'] as List).single as Map;
      tun['exclude_package'] = ['com.example'];
      applyTunPackages(cfg, const TunAppsConfig(mode: 'direct', packages: []));
      expect(tun.containsKey('exclude_package'), isFalse);
      expect(cfg.containsKey('route'), isFalse);
    });

    test('without initial DNS rules: direct precedes the first route', () {
      final cfg = _configWithTun();
      cfg['route'] = <String, dynamic>{
        'rules': [
          {'outbound': 'vpn-1'},
        ],
      };
      applyTunPackages(cfg, selected);
      expect(cfg['route']['rules'].first['package_name'], selected.packages);
      expect(cfg['route']['rules'].last, {'outbound': 'vpn-1'});
    });

    test('an untagged tun gets a free tag to scope the rule', () {
      final cfg = _configWithTun();
      final inbounds = cfg['inbounds'] as List;
      (inbounds.first as Map).remove('tag');
      inbounds.add({'type': 'mixed', 'tag': 'tun-apps-in'});
      applyTunPackages(cfg, selected);
      final tag = inbounds.first['tag'];
      expect(tag, isNot('tun-apps-in'));
      expect(cfg['route']['rules'].single['inbound'], [tag]);
    });
  });
}
