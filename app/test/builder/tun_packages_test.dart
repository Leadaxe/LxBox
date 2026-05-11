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
    });
  });
}
