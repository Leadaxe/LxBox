import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:lxbox/services/builder/post_steps.dart';
import 'package:lxbox/services/settings_storage.dart';

/// §043: tests for `resolveDnsServersList` and `resolveDnsServersBodies`.
void main() {
  late Directory tmp;
  const channel = MethodChannel('plugins.flutter.io/path_provider');

  setUp(() async {
    TestWidgetsFlutterBinding.ensureInitialized();
    tmp = await Directory.systemTemp.createTemp('lxbox_dns_servers_test_');
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
      if (call.method == 'getApplicationDocumentsDirectory' ||
          call.method == 'getApplicationDocumentsPath') {
        return tmp.path;
      }
      return null;
    });
    SettingsStorage.resetCacheForTesting();
  });

  tearDown(() async {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null);
    if (tmp.existsSync()) await tmp.delete(recursive: true);
  });

  Map<String, dynamic> tplGoogleDoh() => {
        'type': 'https',
        'tag': 'google_doh',
        'server': 'dns.google',
        'server_port': 443,
        'path': '/dns-query',
        'description': 'Google DoH',
        'enabled': true,
      };

  Map<String, dynamic> tplCloudflareUdp() => {
        'type': 'udp',
        'tag': 'cloudflare_udp',
        'server': '1.1.1.1',
        'server_port': 53,
        'description': 'Cloudflare UDP',
        'enabled': true,
      };

  Map<String, dynamic> presetYandexUdp() => {
        'type': 'udp',
        'tag': 'yandex_udp',
        'server': '77.88.8.8',
        'server_port': 53,
        '_preset_label': 'ru-direct',
      };

  group('resolveDnsServersList', () {
    test('Empty storage → auto-discovery populates template + preset entries', () async {
      // SettingsStorage starts empty.
      final result = await resolveDnsServersList(
        templateServers: [tplGoogleDoh(), tplCloudflareUdp()],
        presetServersByTag: {'yandex_udp': presetYandexUdp()},
      );

      expect(result.length, 3);
      expect(result.where((s) => s['kind'] == 'preset').length, 1);
      expect(result.where((s) => s['kind'] == 'template').length, 2);

      // Preset идёт перед template (priority order).
      expect(result[0]['kind'], 'preset');
      expect(result[0]['tag'], 'yandex_udp');
    });

    test('Legacy migration: snapshot matching canonical → kind: template ref', () async {
      // Legacy: full body in storage, no `kind` field.
      await SettingsStorage.saveDnsServers([tplGoogleDoh()]);

      final result = await resolveDnsServersList(
        templateServers: [tplGoogleDoh()],
        presetServersByTag: {},
      );

      // Should be migrated to kind:template ref (no body).
      final googleDoh = result.firstWhere((s) => s['tag'] == 'google_doh');
      expect(googleDoh['kind'], 'template');
      expect(googleDoh.containsKey('body'), false);
      expect(googleDoh['enabled'], true);
    });

    test('Legacy migration: shape mismatch → kind: inline with body', () async {
      // Storage has google_doh с дополнительным `detour` (override).
      final overridden = {
        ...tplGoogleDoh(),
        'detour': 'vpn-1',
      };
      await SettingsStorage.saveDnsServers([overridden]);

      final result = await resolveDnsServersList(
        templateServers: [tplGoogleDoh()],
        presetServersByTag: {},
      );

      final googleDoh = result.firstWhere((s) => s['tag'] == 'google_doh');
      expect(googleDoh['kind'], 'inline');
      expect(googleDoh['body'], isA<Map>());
      expect(googleDoh['body']['detour'], 'vpn-1');
    });

    test('Legacy migration: pure custom (no canonical) → kind: inline', () async {
      final custom = {
        'type': 'udp',
        'tag': 'my-custom-dns',
        'server': '9.9.9.9',
        'server_port': 53,
        'enabled': true,
      };
      await SettingsStorage.saveDnsServers([custom]);

      final result = await resolveDnsServersList(
        templateServers: [tplGoogleDoh()],
        presetServersByTag: {},
      );

      final my = result.firstWhere((s) => s['tag'] == 'my-custom-dns');
      expect(my['kind'], 'inline');
      expect(my['body'], isA<Map>());
      expect(my['body']['server'], '9.9.9.9');
    });

    test('Orphan cleanup: kind:template ref на удалённый tag → drop', () async {
      // Storage уже в new format с ref'ом на отсутствующий в template tag.
      await SettingsStorage.saveDnsServers([
        {'enabled': true, 'kind': 'template', 'tag': 'deleted_tag'},
        {'enabled': true, 'kind': 'template', 'tag': 'google_doh'},
      ]);

      final result = await resolveDnsServersList(
        templateServers: [tplGoogleDoh()], // deleted_tag отсутствует
        presetServersByTag: {},
      );

      final tags = result.map((s) => s['tag']).toList();
      expect(tags, contains('google_doh'));
      expect(tags, isNot(contains('deleted_tag')));
    });

    test('Orphan cleanup: kind:preset ref когда preset deactivated → drop', () async {
      await SettingsStorage.saveDnsServers([
        {'enabled': true, 'kind': 'preset', 'tag': 'orphan_preset_tag'},
      ]);

      final result = await resolveDnsServersList(
        templateServers: [],
        presetServersByTag: {}, // нет active preset с этим tag
      );

      final tags = result.map((s) => s['tag']).toList();
      expect(tags, isNot(contains('orphan_preset_tag')));
    });

    test('kind:inline preserved at all costs (даже без canonical)', () async {
      await SettingsStorage.saveDnsServers([
        {
          'enabled': true,
          'kind': 'inline',
          'tag': 'my-dns',
          'body': {'type': 'udp', 'tag': 'my-dns', 'server': '5.5.5.5', 'server_port': 53},
        },
      ]);

      final result = await resolveDnsServersList(
        templateServers: [],
        presetServersByTag: {},
      );

      expect(result.length, 1);
      expect(result.first['kind'], 'inline');
      expect(result.first['tag'], 'my-dns');
    });

    test('Already-migrated storage (есть kind) — no-op (auto-discovery всё равно работает)', () async {
      await SettingsStorage.saveDnsServers([
        {'enabled': false, 'kind': 'template', 'tag': 'google_doh'},
      ]);

      final result = await resolveDnsServersList(
        templateServers: [tplGoogleDoh(), tplCloudflareUdp()],
        presetServersByTag: {},
      );

      // google_doh user-disabled flag preserved
      final google = result.firstWhere((s) => s['tag'] == 'google_doh');
      expect(google['enabled'], false);
      // cloudflare_udp auto-discovered
      final cf = result.firstWhere((s) => s['tag'] == 'cloudflare_udp');
      expect(cf['kind'], 'template');
      expect(cf['enabled'], true);
    });
  });

  group('resolveDnsServersBodies', () {
    test('kind:template ref → body из templateByTag', () {
      final out = resolveDnsServersBodies(
        resolved: [
          {'enabled': true, 'kind': 'template', 'tag': 'google_doh'},
        ],
        templateByTag: {'google_doh': tplGoogleDoh()},
        presetServersByTag: {},
      );
      expect(out.length, 1);
      expect(out.first['tag'], 'google_doh');
      expect(out.first['type'], 'https');
      // Mutable стрипнуты
      expect(out.first.containsKey('enabled'), false);
      expect(out.first.containsKey('description'), false);
    });

    test('kind:preset ref → body из presetServersByTag', () {
      final out = resolveDnsServersBodies(
        resolved: [
          {'enabled': true, 'kind': 'preset', 'tag': 'yandex_udp'},
        ],
        templateByTag: {},
        presetServersByTag: {'yandex_udp': presetYandexUdp()},
      );
      expect(out.length, 1);
      expect(out.first['tag'], 'yandex_udp');
      // _preset_label стрипнут
      expect(out.first.containsKey('_preset_label'), false);
    });

    test('kind:inline ref → body напрямую', () {
      final out = resolveDnsServersBodies(
        resolved: [
          {
            'enabled': true,
            'kind': 'inline',
            'tag': 'my-dns',
            'body': {
              'type': 'udp',
              'tag': 'my-dns',
              'server': '5.5.5.5',
              'server_port': 53,
            },
          },
        ],
        templateByTag: {},
        presetServersByTag: {},
      );
      expect(out.length, 1);
      expect(out.first['server'], '5.5.5.5');
    });

    test('disabled refs filtered out', () {
      final out = resolveDnsServersBodies(
        resolved: [
          {'enabled': false, 'kind': 'template', 'tag': 'google_doh'},
          {'enabled': true, 'kind': 'template', 'tag': 'cloudflare_udp'},
        ],
        templateByTag: {
          'google_doh': tplGoogleDoh(),
          'cloudflare_udp': tplCloudflareUdp(),
        },
        presetServersByTag: {},
      );
      expect(out.length, 1);
      expect(out.first['tag'], 'cloudflare_udp');
    });

    test('Orphan ref (canonical missing) → silently skipped', () {
      final out = resolveDnsServersBodies(
        resolved: [
          {'enabled': true, 'kind': 'template', 'tag': 'deleted_tag'},
        ],
        templateByTag: {},
        presetServersByTag: {},
      );
      expect(out.length, 0);
    });

    test('Tag dedup: первый wins', () {
      final out = resolveDnsServersBodies(
        resolved: [
          {
            'enabled': true,
            'kind': 'inline',
            'tag': 'google_doh',
            'body': {'type': 'udp', 'tag': 'google_doh', 'server': '8.8.8.8', 'server_port': 53},
          },
          // Тот же tag второй раз — skipped
          {'enabled': true, 'kind': 'template', 'tag': 'google_doh'},
        ],
        templateByTag: {'google_doh': tplGoogleDoh()},
        presetServersByTag: {},
      );
      expect(out.length, 1);
      expect(out.first['type'], 'udp'); // inline wins
      expect(out.first['server'], '8.8.8.8');
    });
  });
}
