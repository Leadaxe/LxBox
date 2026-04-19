import 'package:flutter_test/flutter_test.dart';
import 'package:lxbox/models/parser_config.dart';
import 'package:lxbox/models/server_list.dart';
import 'package:lxbox/services/builder/build_config.dart';
import 'package:lxbox/services/subscription/sources.dart';

/// E2E: тело подписки → parseFromSource → UserServers → ServerRegistry →
/// buildConfig → валидный sing-box config без fatal issues.
void main() {
  final template = WizardTemplate(
    parserConfig: ParserConfigBlock(),
    presetGroups: [
      PresetGroup(
        tag: 'vpn-1',
        type: 'selector',
        options: {'default': 'auto-proxy-out'},
        defaultEnabled: true,
        addOutbounds: ['direct-out', 'auto-proxy-out'],
      ),
      PresetGroup(
        tag: 'auto-proxy-out',
        type: 'urltest',
        options: {'url': 'https://example.com', 'interval': '30s'},
        defaultEnabled: true,
        addOutbounds: const [],
      ),
    ],
    vars: const [],
    varSections: const [],
    config: {
      'outbounds': [
        {'tag': 'direct-out', 'type': 'direct'},
      ],
      'route': {'rules': []},
    },
    selectableRules: const [],
    dnsOptions: const {},
    pingOptions: const {},
    speedTestOptions: const {},
  );

  test('multi-protocol subscription body → valid config', () async {
    const body = '''
vless://uuid-1@vless.example:443?type=ws&security=tls&path=/v&sni=vless.example#VLESS
trojan://pass-1@trojan.example:443?security=tls&sni=trojan.example#Trojan
ss://YWVzLTI1Ni1nY206cGFzcw@ss.example:8388#SS
hysteria2://hp@hy2.example:443?sni=hy2.example#Hy2
tuic://tuic-uuid:tuic-pass@tuic.example:443?congestion_control=bbr&alpn=h3&sni=tuic.example#TUIC
''';

    final r = await parseFromSource(const InlineSource(body));
    expect(r.nodes, hasLength(5));

    final userList = UserServers(
      id: 'e2e-1',
      name: 'E2E',
      enabled: true,
      tagPrefix: '',
      detourPolicy: DetourPolicy.defaults,
      origin: UserSource.paste,
      createdAt: DateTime.now(),
      rawBody: body,
      nodes: r.nodes,
    );

    final result = await buildConfig(
        lists: [userList],
        template: template,
        settings: const BuildSettings(
        userVars: {'clash_api': '127.0.0.1:9090'},
        enabledGroups: {'vpn-1', 'auto-proxy-out'},
      ),
    );

    expect(result.validation.isOk, true,
        reason: result.validation.issues.join('\n'));

    final outs = result.config['outbounds'] as List;
    final tags = outs.map((o) => (o as Map)['tag']).toSet();
    expect(tags, containsAll(['VLESS', 'Trojan', 'SS', 'Hy2', 'TUIC']));
    expect(tags, contains('vpn-1'));
    expect(tags, contains('auto-proxy-out'));
    expect(tags, contains('direct-out'));

    final vpn1 =
        outs.firstWhere((o) => (o as Map)['tag'] == 'vpn-1') as Map;
    expect(vpn1['outbounds'], containsAll(['VLESS', 'Trojan', 'SS', 'Hy2', 'TUIC']));
  });

  test('disabled UserServers excluded from config', () async {
    final r = await parseFromSource(
      const InlineSource('vless://u@h.example:443#A\n'),
    );
    final list = UserServers(
      id: 'disabled',
      name: 'D',
      enabled: false,
      tagPrefix: '',
      detourPolicy: DetourPolicy.defaults,
      origin: UserSource.paste,
      createdAt: DateTime.now(),
      nodes: r.nodes,
    );
    final result = await buildConfig(
        lists: [list],
        template: template,
        settings: const BuildSettings(userVars: {'clash_api': '127.0.0.1:9090'}),
    );
    final outs = result.config['outbounds'] as List;
    final tags = outs.map((o) => (o as Map)['tag']).toSet();
    expect(tags, isNot(contains('A')));
  });

  test('XHTTP node produces UI warning from builder', () async {
    final r = await parseFromSource(
      const InlineSource(
          'vless://u@h.example:443?type=xhttp&security=tls&path=/x&sni=h.example#XH\n'),
    );
    final list = UserServers(
      id: 'xh',
      name: 'XH',
      enabled: true,
      tagPrefix: '',
      detourPolicy: DetourPolicy.defaults,
      origin: UserSource.paste,
      createdAt: DateTime.now(),
      nodes: r.nodes,
    );
    final result = await buildConfig(
        lists: [list],
        template: template,
        settings: const BuildSettings(userVars: {'clash_api': '127.0.0.1:9090'}),
    );
    expect(
      result.emitWarnings.any((w) => w.contains('xhttp')),
      true,
      reason: 'expected xhttp warning in emitWarnings: ${result.emitWarnings}',
    );
  });
}
