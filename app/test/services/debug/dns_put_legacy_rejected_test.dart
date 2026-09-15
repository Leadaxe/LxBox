// ignore_for_file: depend_on_referenced_packages

import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:lxbox/models/dns_ref.dart';
import 'package:lxbox/services/debug/context.dart';
import 'package:lxbox/services/debug/contract/errors.dart';
import 'package:lxbox/services/debug/debug_registry.dart';
import 'package:lxbox/services/debug/handlers/settings.dart';
import 'package:lxbox/services/debug/transport/request.dart';
import 'package:lxbox/services/debug/transport/response.dart';
import 'package:lxbox/services/settings_storage.dart';
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';
import 'package:plugin_platform_interface/plugin_platform_interface.dart';

class _FakePathProvider extends PathProviderPlatform
    with MockPlatformInterfaceMixin {
  _FakePathProvider(this.root);
  final String root;
  @override
  Future<String?> getApplicationSupportPath() async => '$root/support';
  @override
  Future<String?> getApplicationDocumentsPath() async => '$root/docs';
}

/// §439 §3.4 — Debug `PUT /settings/dns_options/{servers,rules}` принимает
/// только записи `dns{}` формы 1.0. Формы 2.23.2 — 400 с образцом записи, и
/// хранение не трогается.
void main() {
  late Directory tmp;

  DebugContext ctx() => DebugContext(
        registry: DebugRegistry.I,
        appStartedAt: DateTime.utc(2026, 9, 15),
      );

  DebugRequest put(String path, Object body) => DebugRequest.forTest(
        method: 'PUT',
        path: path,
        body: utf8.encode(jsonEncode(body)),
      );

  Future<Map<String, dynamic>> fileDns() async {
    final raw = jsonDecode(
            await File('${tmp.path}/docs/lxbox_settings.json').readAsString())
        as Map<String, dynamic>;
    return (raw['dns'] as Map?)?.cast<String, dynamic>() ?? const {};
  }

  setUp(() async {
    TestWidgetsFlutterBinding.ensureInitialized();
    tmp = await Directory.systemTemp.createTemp('dns_put_legacy_');
    await Directory('${tmp.path}/docs').create();
    await Directory('${tmp.path}/support').create();
    PathProviderPlatform.instance = _FakePathProvider(tmp.path);
    SettingsStorage.resetCacheForTesting();
    await SettingsStorage.saveDnsServers(const [
      DnsServerInline(
          enabled: true, tag: 'keep', body: {'type': 'udp', 'server': '9.9.9.9'}),
    ]);
    await SettingsStorage.saveDnsRulesList(const [
      DnsRuleInline(name: 'keep', rule: {'server': 'keep'}),
    ]);
  });

  tearDown(() async {
    SettingsStorage.resetCacheForTesting();
    try {
      if (tmp.existsSync()) await tmp.delete(recursive: true);
    } on FileSystemException {
      // ignore
    }
  });

  /// 400 с образцом записи 1.0 в тексте; [field] — поле формы 2.23.2, которое
  /// ответ обязан назвать (у снимка без `kind` поля назвать нечем).
  Matcher badRequestWith(String? field) {
    var m = isA<BadRequest>()
        .having((e) => e.message, 'message', contains('"kind":"user"'));
    if (field != null) m = m.having((e) => e.message, 'message', contains(field));
    return throwsA(m);
  }

  group('PUT /settings/dns_options/servers', () {
    test('записи всех видов 1.0 принимаются и ложатся в dns.servers', () async {
      final records = [
        {
          'kind': 'user',
          'tag': 'my-doh',
          'enabled': true,
          'body': {'type': 'https', 'server': 'dns.example'},
        },
        {'kind': 'preset', 'ref': 'ru-direct:yandex_udp', 'enabled': false},
        {
          'kind': 'template',
          'tag': 'google_doh',
          'enabled': true,
          'vars': {'outbound': 'vpn-1'},
        },
      ];
      final r = await settingsHandler(
          put('/settings/dns_options/servers', {'servers': records}), ctx());
      expect(((r as JsonResponse).body as Map)['count'], 3);

      final servers = await SettingsStorage.getDnsServers();
      // Тег preset-сервера — тег конфига: `ref` целиком.
      expect(servers.map((s) => s.tag),
          ['my-doh', 'ru-direct:yandex_udp', 'google_doh']);
      expect((servers[1] as DnsServerPreset).presetId, 'ru-direct');
      expect((servers[2] as DnsServerTemplate).varValues, {'outbound': 'vpn-1'});
      expect((await fileDns())['servers'], records);
    });

    for (final (name, record, String? field) in [
      (
        'kind-ref inline',
        {
          'enabled': true,
          'kind': 'inline',
          'tag': 'x',
          'body': {'type': 'udp', 'server': '1.1.1.1'},
        },
        'inline',
      ),
      (
        'снимок сервера без kind (форма до §043)',
        {'tag': 'x', 'type': 'udp', 'server': '1.1.1.1'},
        null,
      ),
      (
        'template с varValues',
        {
          'enabled': true,
          'kind': 'template',
          'tag': 'google_doh',
          'varValues': {'outbound': 'vpn-1'},
        },
        'varValues',
      ),
      (
        'user без body',
        {'kind': 'user', 'tag': 'x', 'enabled': true},
        'body',
      ),
    ]) {
      test('$name → 400 с образцом записи, хранение не тронуто', () async {
        final before = await fileDns();
        await expectLater(
          settingsHandler(
              put('/settings/dns_options/servers', {
                'servers': [
                  {
                    'kind': 'user',
                    'tag': 'ok',
                    'body': {'type': 'udp', 'server': '8.8.8.8'},
                  },
                  record,
                ],
              }),
              ctx()),
          badRequestWith(field),
        );
        expect(await fileDns(), before);
        expect((await SettingsStorage.getDnsServers()).map((s) => s.tag),
            ['keep']);
      });
    }
  });

  group('PUT /settings/dns_options/rules', () {
    test('записи всех видов 1.0 принимаются и ложатся в dns.rules', () async {
      final records = [
        {
          'kind': 'user',
          'name': 'corp',
          'enabled': false,
          'body': {
            'domain_suffix': ['.corp'],
            'server': 'my-doh',
          },
        },
        {'kind': 'srs', 'name': 'geo', 'id': 'ds_geo', 'body': {'server': 'x'}},
        {'kind': 'preset', 'ref': 'ru-direct', 'enabled': true},
        {'kind': 'template', 'name': 'Default', 'enabled': true},
      ];
      final r = await settingsHandler(
          put('/settings/dns_options/rules', {'rules': records}), ctx());
      expect(((r as JsonResponse).body as Map)['count'], 4);

      final rules = await SettingsStorage.getDnsRulesList();
      expect(rules.map((x) => x.kind), ['inline', 'srs', 'preset', 'template']);
      expect((rules[0] as DnsRuleInline).enabled, isFalse);
      expect((rules[2] as DnsRulePreset).presetId, 'ru-direct');
      expect((await fileDns())['rules'], records);
    });

    for (final (name, Object body, String? field) in [
      (
        'kind-ref inline',
        {
          'rules': [
            {
              'kind': 'inline',
              'name': 'corp',
              'rule': {'server': 'x'},
            },
          ],
        },
        'inline',
      ),
      (
        'preset с presetId',
        {
          'rules': [
            {'kind': 'preset', 'presetId': 'ru-direct', 'enabled': true},
          ],
        },
        'presetId',
      ),
      (
        'user без body',
        {
          'rules': [
            {'kind': 'user', 'name': 'corp', 'enabled': true},
          ],
        },
        'body',
      ),
    ]) {
      test('$name → 400 с образцом записи, хранение не тронуто', () async {
        final before = await fileDns();
        await expectLater(
          settingsHandler(put('/settings/dns_options/rules', body), ctx()),
          badRequestWith(field),
        );
        expect(await fileDns(), before);
      });
    }

    test('строка rules_json → 400', () async {
      await expectLater(
        settingsHandler(
            put('/settings/dns_options/rules', {'rules': '[{"server":"x"}]'}),
            ctx()),
        throwsA(isA<BadRequest>()),
      );
      expect(
          ((await SettingsStorage.getDnsRulesList()).single as DnsRuleInline)
              .name,
          'keep');
    });
  });
}
