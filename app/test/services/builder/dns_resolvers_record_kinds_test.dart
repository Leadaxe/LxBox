import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:lxbox/models/dns_ref.dart';
import 'package:lxbox/services/builder/post_steps.dart';
import 'package:lxbox/services/settings_storage.dart';

/// §439 §4.2, §2.3 п. 6 — записи `dns{}` всех видов формы 1.0 переживают оба
/// резолвера: `resolveDnsServersList` и `resolveDnsRulesList` отдают тот же
/// состав в том же порядке и не переписывают файл. Ловушка, которую держит
/// тест: резолвер, выбрасывающий незнакомый ему вид и сохраняющий результат,
/// стёр бы DNS-записи пользователя на первом входе в экран или сборке.
void main() {
  late Directory tmp;
  const channel = MethodChannel('plugins.flutter.io/path_provider');

  File settings() => File('${tmp.path}/lxbox_settings.json');

  setUp(() async {
    TestWidgetsFlutterBinding.ensureInitialized();
    tmp = await Directory.systemTemp.createTemp('lxbox_dns_record_kinds_');
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
    SettingsStorage.resetCacheForTesting();
    if (tmp.existsSync()) await tmp.delete(recursive: true);
  });

  // Серверы: пользовательские вперемешку с template и preset — резолвер
  // хранит порядок пользователя.
  const serverRecords = [
    {
      'kind': 'user',
      'tag': 'my-doh',
      'enabled': true,
      'body': {'type': 'https', 'server': 'dns.example', 'detour': 'vpn-1'},
      'description': 'Mine',
    },
    {
      'kind': 'template',
      'tag': 'google_udp',
      'enabled': false,
      'vars': {'outbound': 'vpn-1', 'dns_ip': '8.8.4.4'},
      'description': 'Google, via VPN',
    },
    {'kind': 'preset', 'ref': 'ru-direct:yandex_udp', 'enabled': true},
    {
      'kind': 'user',
      'tag': 'dns-group',
      'enabled': true,
      'body': {
        'type': 'group',
        'servers': ['my-doh', 'ru-direct:yandex_udp'],
      },
    },
  ];

  // Правила: все четыре вида, включая виды LxBox (srs, template).
  const ruleRecords = [
    {
      'kind': 'user',
      'name': 'corp',
      'enabled': false,
      'body': {
        'domain_suffix': ['.corp'],
        'server': 'my-doh',
      },
    },
    {'kind': 'preset', 'ref': 'ru-direct', 'enabled': true},
    {
      'kind': 'srs',
      'name': 'geo',
      'id': 'ds_geo',
      'body': {
        'server': 'google_udp',
        'query_type': ['A'],
      },
    },
    {
      'kind': 'srs',
      'name': 'legacy-top',
      'id': 'ds_top',
      'srsUrl': 'https://example.com/geo.srs',
      'server': 'my-doh',
      'rule': {
        'query_type': ['AAAA'],
      },
      'enabled': false,
    },
    {'kind': 'template', 'name': 'Default → Google', 'enabled': true},
  ];

  Map<String, dynamic> templateGoogleUdp() => {
        'description': 'Google DNS',
        'enabled': true,
        'vars': [
          {
            'name': 'outbound',
            'type': 'outbound',
            'default_value': 'direct-out',
          },
          {'name': 'dns_ip', 'type': 'enum', 'default_value': '8.8.8.8'},
        ],
        'server': {
          'type': 'udp',
          'tag': 'google_udp',
          'server': '@dns_ip',
          'detour': '@outbound',
        },
      };

  // Ключ — тег конфига: сборка кладёт серверы пресета в пространство его id
  // (`namespacePresetTags`), и `ref` записи — та же строка.
  const presetServersByTag = {
    'ru-direct:yandex_udp': {
      'type': 'udp',
      'tag': 'ru-direct:yandex_udp',
      'server': '77.88.8.8',
    },
  };

  Future<void> seedFile() => settings().writeAsString(
        const JsonEncoder.withIndent('  ').convert({
          'storage_version': 1,
          'dns': {'servers': serverRecords, 'rules': ruleRecords},
        }),
      );

  test('серверы всех видов: состав, порядок и поля не меняются, файл не '
      'переписан', () async {
    await seedFile();
    final before = await settings().readAsString();
    final beforeStat = settings().statSync().modified;

    final resolved = await resolveDnsServersList(
      templateServers: [templateGoogleUdp()],
      presetServersByTag: presetServersByTag,
      presetIdByTag: const {'ru-direct:yandex_udp': 'ru-direct'},
    );

    expect(resolved, const <DnsServerRef>[
      DnsServerInline(
        enabled: true,
        tag: 'my-doh',
        body: {'type': 'https', 'server': 'dns.example', 'detour': 'vpn-1'},
        description: 'Mine',
      ),
      DnsServerTemplate(
        enabled: false,
        tag: 'google_udp',
        varValues: {'outbound': 'vpn-1', 'dns_ip': '8.8.4.4'},
        description: 'Google, via VPN',
      ),
      DnsServerPreset(
          enabled: true, tag: 'ru-direct:yandex_udp', presetId: 'ru-direct'),
      DnsServerInline(
        enabled: true,
        tag: 'dns-group',
        body: {
          'type': 'group',
          'servers': ['my-doh', 'ru-direct:yandex_udp'],
        },
      ),
    ]);
    expect(await settings().readAsString(), before);
    expect(settings().statSync().modified, beforeStat);

    // Повторный проход (экран после сборки) — то же самое.
    SettingsStorage.resetCacheForTesting();
    final again = await resolveDnsServersList(
      templateServers: [templateGoogleUdp()],
      presetServersByTag: presetServersByTag,
      presetIdByTag: const {'ru-direct:yandex_udp': 'ru-direct'},
    );
    expect(again, resolved);
    expect(await settings().readAsString(), before);
  });

  test('правила всех видов: состав, порядок и поля не меняются, файл не '
      'переписан', () async {
    await seedFile();
    final before = await settings().readAsString();

    final resolved = await resolveDnsRulesList(
      templateRules: const [
        {
          'name': 'Default → Google',
          'enabled_default': true,
          'server': 'google_udp',
        },
      ],
      activePresetIdsWithDnsRule: const {'ru-direct'},
    );

    expect(resolved, const <DnsRuleRef>[
      DnsRuleInline(
        name: 'corp',
        enabled: false,
        rule: {
          'domain_suffix': ['.corp'],
          'server': 'my-doh',
        },
      ),
      DnsRulePreset(presetId: 'ru-direct', enabled: true),
      DnsRuleSrs(
        name: 'geo',
        id: 'ds_geo',
        body: {
          'server': 'google_udp',
          'query_type': ['A'],
        },
      ),
      DnsRuleSrs(
        name: 'legacy-top',
        id: 'ds_top',
        srsUrl: 'https://example.com/geo.srs',
        server: 'my-doh',
        rule: {
          'query_type': ['AAAA'],
        },
        enabled: false,
      ),
      DnsRuleTemplate(name: 'Default → Google', enabled: true),
    ]);
    expect(await settings().readAsString(), before);
  });

  test('сохранение резолвером (изменился состав) не теряет полей записей',
      () async {
    await seedFile();

    // Шаблон принёс новый template-сервер и новое template-правило: оба
    // резолвера дописывают и сохраняют.
    final servers = await resolveDnsServersList(
      templateServers: [
        templateGoogleUdp(),
        {
          'enabled': false,
          'server': {'type': 'udp', 'tag': 'quad9_udp', 'server': '9.9.9.9'},
        },
      ],
      presetServersByTag: presetServersByTag,
      presetIdByTag: const {'ru-direct:yandex_udp': 'ru-direct'},
    );
    expect(servers.map((s) => s.tag), [
      'my-doh',
      'google_udp',
      'ru-direct:yandex_udp',
      'dns-group',
      'quad9_udp',
    ]);

    await resolveDnsRulesList(
      templateRules: const [
        {'name': 'Default → Google', 'server': 'google_udp'},
        {'name': 'Fresh', 'enabled_default': false, 'server': 'quad9_udp'},
      ],
      activePresetIdsWithDnsRule: const {'ru-direct'},
    );

    final dns = (jsonDecode(await settings().readAsString())
        as Map<String, dynamic>)['dns'] as Map<String, dynamic>;
    expect(dns['servers'], [
      ...serverRecords,
      {'kind': 'template', 'tag': 'quad9_udp', 'enabled': false},
    ]);
    expect(dns['rules'], [
      ...ruleRecords,
      {'kind': 'template', 'name': 'Fresh', 'enabled': false},
    ]);
  });
}
