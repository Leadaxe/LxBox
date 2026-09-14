import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:lxbox/models/dns_ref.dart';
import 'package:lxbox/services/builder/post_steps.dart';
import 'package:lxbox/services/settings_storage.dart';

/// §043 + §117: tests for `resolveDnsServersList` / `resolveDnsServersBodies`
/// / `resolveTemplateDnsServerBody`.
///
/// §117: template-серверы — обёртки `{description, enabled, vars?, server}`,
/// tag в `server.tag`, `@var`-плейсхолдеры в body.
///
/// §439 A1 — резолверы работают с моделями [DnsServerRef]; записи, которые
/// модель не выражает (формы до §043), наверх не отдаются и в хранении
/// остаются (миграция `_migrateLegacyDnsServers` снята).
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

  // §117-обёртки — эталон формата задачи 1 (wizard_template.json).
  Map<String, dynamic> tplGoogleUdp() => {
        'description': 'Google DNS (direct)',
        'enabled': true,
        'vars': [
          {
            'name': 'outbound',
            'type': 'outbound',
            'default_value': 'direct-out',
            'title': 'Outbound',
          },
          {
            'name': 'dns_ip',
            'type': 'enum',
            'default_value': '8.8.8.8',
            'title': 'UDP server IP',
            'options': [
              {'title': 'Primary v4', 'value': '8.8.8.8'},
              {'title': 'Secondary v4', 'value': '8.8.4.4'},
            ],
          },
        ],
        'server': {
          'type': 'udp',
          'tag': 'google_udp',
          'server_port': 53,
          'server': '@dns_ip',
          'detour': '@outbound',
        },
      };

  Map<String, dynamic> tplCloudflareUdp() => {
        'description': 'Cloudflare UDP',
        'enabled': true,
        'vars': [
          {
            'name': 'outbound',
            'type': 'outbound',
            'default_value': 'direct-out',
          },
          {
            'name': 'dns_ip',
            'type': 'enum',
            'default_value': '1.1.1.1',
          },
        ],
        'server': {
          'type': 'udp',
          'tag': 'cloudflare_udp',
          'server_port': 53,
          'server': '@dns_ip',
          'detour': '@outbound',
        },
      };

  // Обёртка без vars — как local_dns_resolver в шаблоне.
  Map<String, dynamic> tplLocal() => {
        'description': 'System DNS',
        'enabled': true,
        'server': {'type': 'local', 'tag': 'local_dns_resolver'},
      };

  Map<String, dynamic> presetYandexUdp() => {
        'type': 'udp',
        'tag': 'yandex_udp',
        'server': '77.88.8.8',
        'server_port': 53,
        '_preset_label': 'ru-direct',
      };

  group('templateDnsServerTag', () {
    test('tag из server.tag; нет server → null', () {
      expect(templateDnsServerTag(tplGoogleUdp()), 'google_udp');
      expect(templateDnsServerTag(tplLocal()), 'local_dns_resolver');
      expect(templateDnsServerTag({'description': 'x'}), null);
      expect(templateDnsServerTag({'server': {}}), null);
    });
  });

  group('resolveTemplateDnsServerBody', () {
    test('дефолты vars подставлены', () {
      final body = resolveTemplateDnsServerBody(tplGoogleUdp());
      expect(body, isNotNull);
      expect(body!['tag'], 'google_udp');
      expect(body['server'], '8.8.8.8');
      expect(body['detour'], 'direct-out'); // normalize — зона caller'а
    });

    test('varValues юзера бьют дефолты', () {
      final body = resolveTemplateDnsServerBody(
        tplGoogleUdp(),
        varValues: {'outbound': 'vpn-1', 'dns_ip': '8.8.4.4'},
      );
      expect(body!['detour'], 'vpn-1');
      expect(body['server'], '8.8.4.4');
    });

    test('обёртка без vars → чистая копия server', () {
      final body = resolveTemplateDnsServerBody(tplLocal());
      expect(body, {'type': 'local', 'tag': 'local_dns_resolver'});
    });

    test('пустой default без значения юзера → ключ с @var выпадает', () {
      final wrapper = {
        'server': {
          'type': 'udp',
          'tag': 't',
          'server': '9.9.9.9',
          'detour': '@outbound',
        },
        'vars': [
          {'name': 'outbound', 'type': 'outbound', 'default_value': ''},
        ],
      };
      final body = resolveTemplateDnsServerBody(wrapper);
      expect(body!.containsKey('detour'), false);
    });
  });

  group('resolveDnsServersList', () {
    test('Empty storage → auto-discovery populates template + preset entries',
        () async {
      // SettingsStorage starts empty.
      final result = await resolveDnsServersList(
        templateServers: [tplGoogleUdp(), tplCloudflareUdp()],
        presetServersByTag: {'yandex_udp': presetYandexUdp()},
      );

      expect(result.length, 3);
      expect(result.whereType<DnsServerPreset>().length, 1);
      expect(result.whereType<DnsServerTemplate>().length, 2);

      // Preset идёт перед template (priority order).
      expect(result[0], isA<DnsServerPreset>());
      expect(result[0].tag, 'yandex_udp');
      // §117: tag берётся из server.tag обёртки.
      expect(result[1].tag, 'google_udp');
    });

    test(
        'форма до §043 (без kind) — наверх не отдаётся, в хранении остаётся; '
        'auto-discovery добавляет template ref', () async {
      final legacy = {
        'type': 'udp',
        'tag': 'google_udp',
        'server': '8.8.4.4',
        'server_port': 53,
        'detour': 'vpn-1',
        'enabled': true,
      };
      File('${tmp.path}/lxbox_settings.json').writeAsStringSync(jsonEncode({
        'storage_version': 1,
        'dns': {
          'servers': [legacy],
        },
      }));

      final result = await resolveDnsServersList(
        templateServers: [tplGoogleUdp()],
        presetServersByTag: {},
      );

      expect(result,
          [const DnsServerTemplate(enabled: true, tag: 'google_udp')]);
      final raw = await SettingsStorage.exportRaw();
      final servers = (raw['dns'] as Map)['servers'] as List;
      expect(servers, [
        legacy,
        {'kind': 'template', 'tag': 'google_udp', 'enabled': true},
      ]);
    });

    test('Orphan cleanup: kind:template ref на удалённый tag → drop', () async {
      // §117: удалённые из шаблона теги (quad9_dot и т.п.) орфан-чистятся.
      await SettingsStorage.saveDnsServers([
        const DnsServerTemplate(enabled: true, tag: 'quad9_dot'),
        const DnsServerTemplate(enabled: true, tag: 'google_udp'),
      ]);

      final result = await resolveDnsServersList(
        templateServers: [tplGoogleUdp()], // quad9_dot отсутствует
        presetServersByTag: {},
      );

      final tags = result.map((s) => s.tag).toList();
      expect(tags, contains('google_udp'));
      expect(tags, isNot(contains('quad9_dot')));
    });

    test('Orphan cleanup: kind:preset ref когда preset deactivated → drop',
        () async {
      await SettingsStorage.saveDnsServers([
        const DnsServerPreset(enabled: true, tag: 'orphan_preset_tag'),
      ]);

      final result = await resolveDnsServersList(
        templateServers: [],
        presetServersByTag: {}, // нет active preset с этим tag
      );

      final tags = result.map((s) => s.tag).toList();
      expect(tags, isNot(contains('orphan_preset_tag')));
    });

    test('kind:inline preserved at all costs (даже без canonical)', () async {
      await SettingsStorage.saveDnsServers([
        const DnsServerInline(
          enabled: true,
          tag: 'my-dns',
          body: {'type': 'udp', 'server': '192.168.1.1', 'server_port': 53},
        ),
      ]);

      final result = await resolveDnsServersList(
        templateServers: [],
        presetServersByTag: {},
      );

      expect(result.length, 1);
      expect(result.first, isA<DnsServerInline>());
      expect(result.first.tag, 'my-dns');
    });

    test('varValues в template ref переживают resolve + orphan cleanup',
        () async {
      await SettingsStorage.saveDnsServers([
        const DnsServerTemplate(
          enabled: true,
          tag: 'google_udp',
          varValues: {'outbound': 'vpn-1'},
        ),
      ]);

      final result = await resolveDnsServersList(
        templateServers: [tplGoogleUdp(), tplCloudflareUdp()],
        presetServersByTag: {},
      );

      final google = result.firstWhere((s) => s.tag == 'google_udp');
      expect((google as DnsServerTemplate).varValues, {'outbound': 'vpn-1'});
    });

    test('Already-migrated storage (есть kind) — enabled flag preserved',
        () async {
      await SettingsStorage.saveDnsServers([
        const DnsServerTemplate(enabled: false, tag: 'google_udp'),
      ]);

      final result = await resolveDnsServersList(
        templateServers: [tplGoogleUdp(), tplCloudflareUdp()],
        presetServersByTag: {},
      );

      // google_udp user-disabled flag preserved
      final google = result.firstWhere((s) => s.tag == 'google_udp');
      expect(google.enabled, false);
      // cloudflare_udp auto-discovered
      final cf = result.firstWhere((s) => s.tag == 'cloudflare_udp');
      expect(cf, isA<DnsServerTemplate>());
      expect(cf.enabled, true);
    });
  });

  group('resolveDnsServersBodies', () {
    test('kind:template → server.tag, дефолты vars, direct-out стёрт', () {
      final out = resolveDnsServersBodies(
        resolved: [
          const DnsServerTemplate(enabled: true, tag: 'google_udp'),
        ],
        templateByTag: {'google_udp': tplGoogleUdp()},
        presetServersByTag: {},
      );
      expect(out.length, 1);
      expect(out.first['tag'], 'google_udp');
      expect(out.first['type'], 'udp');
      expect(out.first['server'], '8.8.8.8'); // default подставлен
      // detour=direct-out (default) → ключ не пишется (§117 решение №2)
      expect(out.first.containsKey('detour'), false);
      // Mutable стрипнуты
      expect(out.first.containsKey('enabled'), false);
      expect(out.first.containsKey('description'), false);
    });

    test('кейс репортёра: outbound=Направление → detour: "<Направление>" в конфиге', () {
      final out = resolveDnsServersBodies(
        resolved: [
          const DnsServerTemplate(
            enabled: true,
            tag: 'google_udp',
            varValues: {'outbound': 'vpn-1', 'dns_ip': '8.8.4.4'},
          ),
        ],
        templateByTag: {'google_udp': tplGoogleUdp()},
        presetServersByTag: {},
        knownOutboundTags: {'direct-out', 'vpn-1', '✨auto'},
      );
      expect(out.first['detour'], 'vpn-1');
      expect(out.first['server'], '8.8.4.4');
    });

    test('detour на исчезнувшее Направление → ключ не пишется (решение №2)', () {
      final out = resolveDnsServersBodies(
        resolved: [
          const DnsServerTemplate(
            enabled: true,
            tag: 'google_udp',
            varValues: {'outbound': 'vpn-3'},
          ),
        ],
        templateByTag: {'google_udp': tplGoogleUdp()},
        presetServersByTag: {},
        knownOutboundTags: {'direct-out', 'vpn-1'}, // vpn-3 выключен
      );
      expect(out.first.containsKey('detour'), false);
    });

    test('inline body с dangling detour тоже чистится', () {
      final out = resolveDnsServersBodies(
        resolved: [
          const DnsServerInline(
            enabled: true,
            tag: 'my-dns',
            body: {
              'type': 'udp',
              'server': '192.168.1.1',
              'server_port': 53,
              'detour': 'gone-direction',
            },
          ),
        ],
        templateByTag: {},
        presetServersByTag: {},
        knownOutboundTags: {'direct-out', 'vpn-1'},
      );
      expect(out.first.containsKey('detour'), false);
    });

    test('обёртка без vars (local) резолвится', () {
      final out = resolveDnsServersBodies(
        resolved: [
          const DnsServerTemplate(enabled: true, tag: 'local_dns_resolver'),
        ],
        templateByTag: {'local_dns_resolver': tplLocal()},
        presetServersByTag: {},
      );
      expect(out.length, 1);
      expect(out.first, {'type': 'local', 'tag': 'local_dns_resolver'});
    });

    test('kind:preset ref → body из presetServersByTag', () {
      final out = resolveDnsServersBodies(
        resolved: [
          const DnsServerPreset(enabled: true, tag: 'yandex_udp'),
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
          const DnsServerInline(
            enabled: true,
            tag: 'my-dns',
            body: {
              'type': 'udp',
              'tag': 'my-dns',
              'server': '192.168.1.1',
              'server_port': 53,
            },
          ),
        ],
        templateByTag: {},
        presetServersByTag: {},
      );
      expect(out.length, 1);
      expect(out.first['server'], '192.168.1.1');
    });

    test('disabled refs filtered out', () {
      final out = resolveDnsServersBodies(
        resolved: [
          const DnsServerTemplate(enabled: false, tag: 'google_udp'),
          const DnsServerTemplate(enabled: true, tag: 'cloudflare_udp'),
        ],
        templateByTag: {
          'google_udp': tplGoogleUdp(),
          'cloudflare_udp': tplCloudflareUdp(),
        },
        presetServersByTag: {},
      );
      expect(out.length, 1);
      expect(out.first['tag'], 'cloudflare_udp');
    });

    test(
        '§117 lifecycle: disabled сервер, реферимый активным пресетом — '
        'force-include', () {
      final out = resolveDnsServersBodies(
        resolved: [
          const DnsServerPreset(enabled: false, tag: 'yandex_udp'),
        ],
        templateByTag: {},
        presetServersByTag: {'yandex_udp': presetYandexUdp()},
      );
      // DNS-правило пресета ссылается на сервер — выключить нельзя (битый
      // конфиг), build делает force-include (defense-in-depth к UI-локу).
      expect(out.length, 1);
      expect(out.first['tag'], 'yandex_udp');
    });

    test('Orphan ref (canonical missing) → silently skipped', () {
      final out = resolveDnsServersBodies(
        resolved: [
          const DnsServerTemplate(enabled: true, tag: 'deleted_tag'),
        ],
        templateByTag: {},
        presetServersByTag: {},
      );
      expect(out.length, 0);
    });

    test('Tag dedup: первый wins', () {
      final out = resolveDnsServersBodies(
        resolved: [
          const DnsServerInline(
            enabled: true,
            tag: 'google_udp',
            body: {
              'type': 'udp',
              'tag': 'google_udp',
              'server': '8.8.4.4',
              'server_port': 53,
            },
          ),
          // Тот же tag второй раз — skipped
          const DnsServerTemplate(enabled: true, tag: 'google_udp'),
        ],
        templateByTag: {'google_udp': tplGoogleUdp()},
        presetServersByTag: {},
      );
      expect(out.length, 1);
      expect(out.first['server'], '8.8.4.4'); // inline wins
    });
  });
}
