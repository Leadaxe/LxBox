import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lxbox/config/consts.dart';
import 'package:lxbox/models/custom_rule.dart';
import 'package:lxbox/models/node_spec.dart';
import 'package:lxbox/models/parser_config.dart';
import 'package:lxbox/models/server_list.dart';
import 'package:lxbox/services/builder/build_config.dart';
import 'package:lxbox/services/builder/core_chain_capability.dart';
import 'package:lxbox/services/settings_storage.dart';

import '../parser/engine_test_setup.dart';

/// §578 — пресет `tailscale` с `for_each` при сборке: записи на каждый узел
/// Tailscale, попавший в конфиг, в порядке конфига.
void main() {
  setUpAll(loadEngineSections);

  // DNS-шаг сборки пишет в хранение: временный каталог вместо документов.
  late Directory tmp;
  const channel = MethodChannel('plugins.flutter.io/path_provider');
  setUp(() async {
    TestWidgetsFlutterBinding.ensureInitialized();
    tmp = await Directory.systemTemp.createTemp('lxbox_ts_preset_');
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async => tmp.path);
    SettingsStorage.resetCacheForTesting();
  });
  tearDown(() async {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null);
    try {
      if (tmp.existsSync()) await tmp.delete(recursive: true);
    } catch (_) {}
  });

  final shipped = jsonDecode(
          File('assets/wizard_template.json').readAsStringSync())
      as Map<String, dynamic>;
  final preset = SelectableRule.fromJson((shipped['selectable_rules'] as List)
      .cast<Map<String, dynamic>>()
      .singleWhere((r) => r['preset_id'] == 'tailscale'));

  final template = WizardTemplate(
    parserConfig: ParserConfigBlock(),
    groupTemplates: GroupTemplates(
      direction: DirectionTemplate(
        include: const ['direct', 'auto'],
        options: const {'interrupt_exist_connections': true},
      ),
      auto: AutoTemplate(options: const {'url': 'https://x', 'interval': '30s'}),
      defaultDirections: [
        DefaultDirection(tag: 'vpn-1', label: 'vpn-1', defaultEnabled: true),
      ],
    ),
    vars: const [],
    varSections: const [],
    config: {
      'outbounds': [
        {'tag': 'direct-out', 'type': 'direct'},
      ],
      'route': {'rules': []},
    },
    selectableRules: [preset],
    dnsOptions: const {},
    pingOptions: const {},
    speedTestOptions: const {},
  );

  BuildSettings settingsWith({
    bool presetOn = true,
    Set<String>? coreBuildTags = kCoreBuildTags,
  }) =>
      BuildSettings(
        enabledGroups: const {'vpn-1', kAutoOutboundTag},
        coreBuildTags: coreBuildTags,
        customRules: [
          if (presetOn)
            CustomRulePreset(
                name: 'Tailscale networks',
                presetId: 'tailscale',
                orderNum: 945),
        ],
      );

  TailscaleSpec ts(String tag) => TailscaleSpec(
        id: 'ts-$tag',
        tag: tag,
        label: tag,
        body: {'auth_key': 'tskey'},
      );

  UserServer user(NodeSpec node, {bool enabled = true, bool skip = false}) =>
      UserServer(
        id: 'u-${node.tag}',
        name: '',
        enabled: enabled,
        tagPrefix: '',
        detourPolicy: DetourPolicy.defaults,
        origin: UserSource.manual,
        rawBody: node.toUri(),
        skipPresets: skip,
        nodes: [node],
      );

  List<Map<String, dynamic>> rules(BuildResult r) =>
      ((r.config['route'] as Map)['rules'] as List).cast<Map<String, dynamic>>();
  List<Map<String, dynamic>> dnsServers(BuildResult r) =>
      (((r.config['dns'] as Map?)?['servers'] as List?) ?? const [])
          .cast<Map<String, dynamic>>();
  List<Map<String, dynamic>> dnsRules(BuildResult r) =>
      (((r.config['dns'] as Map?)?['rules'] as List?) ?? const [])
          .cast<Map<String, dynamic>>();
  List<Map<String, dynamic>> byPreferred(List<Map<String, dynamic>> xs) =>
      [for (final x in xs) if (x.containsKey('preferred_by')) x];

  test('два узла: записи из таблицы спеки, порядок конфига', () async {
    final folder = FolderServers(
      id: 'f1',
      name: 'F',
      enabled: true,
      tagPrefix: '',
      detourPolicy: DetourPolicy.defaults,
      members: [FolderMember(raw: ts('work-ts').toUri())],
    );
    final r = await buildConfig(
      lists: [user(ts('home-ts')), folder],
      template: template,
      settings: settingsWith(),
    );
    expect(r.validation.isOk, isTrue, reason: r.validation.issues.join('\n'));
    expect(byPreferred(rules(r)), [
      {
        'preferred_by': ['home-ts'],
        'action': 'resolve',
        'server': 'home-ts-dns',
      },
      {
        'preferred_by': ['home-ts'],
        'outbound': 'home-ts',
      },
      {
        'preferred_by': ['work-ts'],
        'action': 'resolve',
        'server': 'work-ts-dns',
      },
      {
        'preferred_by': ['work-ts'],
        'outbound': 'work-ts',
      },
    ]);
    final servers = [
      for (final s in dnsServers(r))
        if (s['type'] == 'tailscale') s,
    ];
    expect(servers.map((s) => (s['tag'], s['endpoint'])),
        [('home-ts-dns', 'home-ts'), ('work-ts-dns', 'work-ts')]);
    expect(byPreferred(dnsRules(r)), [
      {
        'preferred_by': ['home-ts-dns'],
        'server': 'home-ts-dns',
      },
      {
        'preferred_by': ['work-ts-dns'],
        'server': 'work-ts-dns',
      },
    ]);
    // Ядро ищет preferred_by DNS-правила среди DNS-серверов
    // (rule_item_preferred_by_dns.go): тег узла там валит старт.
    final serverTags = {for (final s in dnsServers(r)) s['tag']};
    for (final x in byPreferred(dnsRules(r))) {
      expect(x['preferred_by'], [x['server']]);
      expect(serverTags, contains(x['server']));
    }
  });

  test('skip_presets и выключенный узел не обслуживаются', () async {
    final r = await buildConfig(
      lists: [
        user(ts('home-ts'), skip: true),
        user(ts('off-ts'), enabled: false),
        user(ts('work-ts')),
      ],
      template: template,
      settings: settingsWith(),
    );
    expect(r.validation.isOk, isTrue, reason: r.validation.issues.join('\n'));
    final served = {
      for (final x in byPreferred(rules(r))) ...(x['preferred_by'] as List),
    };
    expect(served, {'work-ts'});
  });

  test('узел снят гейтом ядра — пресет его не видит', () async {
    final r = await buildConfig(
      lists: [user(ts('home-ts'))],
      template: template,
      settings: settingsWith(
          coreBuildTags: kCoreBuildTags.difference({'with_tailscale'})),
    );
    expect(r.validation.isOk, isTrue, reason: r.validation.issues.join('\n'));
    expect(byPreferred(rules(r)), isEmpty);
    expect(dnsServers(r).where((s) => s['type'] == 'tailscale'), isEmpty);
  });

  test('без узлов Tailscale конфиг байт в байт прежний', () async {
    final vless = UserServer(
      id: 'v',
      name: '',
      enabled: true,
      tagPrefix: '',
      detourPolicy: DetourPolicy.defaults,
      origin: UserSource.manual,
      rawBody: 'vless://11111111-1111-1111-1111-111111111111@1.2.3.4:443'
          '?security=none#v1',
    );
    final withPreset = await buildConfig(
        lists: [vless], template: template, settings: settingsWith());
    final without = await buildConfig(
        lists: [vless],
        template: template,
        settings: settingsWith(presetOn: false));
    expect(jsonEncode(withPreset.config), jsonEncode(without.config));
  });
}
