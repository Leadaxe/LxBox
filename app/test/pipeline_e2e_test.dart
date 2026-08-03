import 'package:flutter_test/flutter_test.dart';
import 'package:lxbox/config/consts.dart';
import 'package:lxbox/models/parser_config.dart';
import 'package:lxbox/models/server_list.dart';
import 'package:lxbox/services/builder/build_config.dart';
import 'package:lxbox/services/subscription/sources.dart';

/// E2E: тело подписки → parseFromSource → UserServer → ServerRegistry →
/// buildConfig → валидный sing-box config без fatal issues.
void main() {
  final template = WizardTemplate(
    parserConfig: ParserConfigBlock(),
    // §267 — group_templates: vpn-1 канал (direct+auto), auto-подгруппа.
    groupTemplates: GroupTemplates(
      channel: ChannelTemplate(
        include: const ['direct', 'auto'],
        options: const {'interrupt_exist_connections': true},
      ),
      auto: AutoTemplate(
        options: const {'url': 'https://example.com', 'interval': '30s'},
      ),
      defaultChannels: [
        DefaultChannel(tag: 'vpn-1', label: 'vpn-1', defaultEnabled: true),
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

    final userList = UserServer(
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
        enabledGroups: {'vpn-1', kAutoOutboundTag},
      ),
    );

    expect(result.validation.isOk, true,
        reason: result.validation.issues.join('\n'));

    final outs = result.config['outbounds'] as List;
    final tags = outs.map((o) => (o as Map)['tag']).toSet();
    expect(tags, containsAll(['VLESS', 'Trojan', 'SS', 'Hy2', 'TUIC']));
    expect(tags, contains('vpn-1'));
    expect(tags, contains('direct-out'));
    // §125 — глобальный ✨auto больше НЕ канал (Решение 3). vpn-1 имеет ✨auto в
    // add_outbounds → его auto-двойник теперь свой: vpn-1-auto (urltest по нодам
    // vpn-1). Глобального ✨auto в outbounds быть не должно.
    expect(tags, isNot(contains(kAutoOutboundTag)));
    expect(tags, contains('vpn-1-auto'));

    final vpn1 =
        outs.firstWhere((o) => (o as Map)['tag'] == 'vpn-1') as Map;
    expect(vpn1['outbounds'], containsAll(['VLESS', 'Trojan', 'SS', 'Hy2', 'TUIC']));
    // selector vpn-1 содержит свой auto-двойник опцией + direct-out (галка).
    expect(vpn1['outbounds'], contains('vpn-1-auto'));
    expect(vpn1['outbounds'], contains('direct-out'));

    // vpn-1-auto — чистый urltest по нодам канала, БЕЗ direct/auto-членов.
    final vpn1Auto =
        outs.firstWhere((o) => (o as Map)['tag'] == 'vpn-1-auto') as Map;
    expect(vpn1Auto['type'], 'urltest');
    expect(vpn1Auto['outbounds'],
        containsAll(['VLESS', 'Trojan', 'SS', 'Hy2', 'TUIC']));
    expect(vpn1Auto['outbounds'], isNot(contains('direct-out')));
  });

  test('disabled UserServer excluded from config', () async {
    final r = await parseFromSource(
      const InlineSource('vless://u@h.example:443#A\n'),
    );
    final list = UserServer(
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

  test('§097 — XHTTP node builds NATIVE xhttp transport (no fallback warning)',
      () async {
    final r = await parseFromSource(
      const InlineSource(
          'vless://u@h.example:443?type=xhttp&security=tls&path=/x&sni=h.example'
          '&mode=stream-one&xPaddingBytes=100-1000#XH\n'),
    );
    final list = UserServer(
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
    // §097 — больше нет fallback-warning про xhttp (нативный transport).
    expect(result.emitWarnings.any((w) => w.contains('xhttp')), false);
    // В конфиге — нативный `transport.type=xhttp` со своими полями.
    final outs = result.config['outbounds'] as List;
    final vless = outs.firstWhere((o) => (o as Map)['type'] == 'vless') as Map;
    final tr = vless['transport'] as Map;
    expect(tr['type'], 'xhttp');
    expect(tr['mode'], 'stream-one');
    expect(tr['x_padding_bytes'], '100-1000');
  });

  test('§368 — sing-box config body → nodes, group and detour chain', () async {
    // Полный конфиг, как его переносит пользователь с sing-box: секции
    // route/dns/inbounds присутствуют и должны быть проигнорированы.
    const body = '''
{
  "log": {"level": "info"},
  "dns": {"servers": [{"tag": "google", "address": "8.8.8.8"}]},
  "inbounds": [{"type": "tun", "tag": "tun-in"}],
  "outbounds": [
    {"type": "vless", "tag": "DE", "server": "de.example", "server_port": 443,
     "uuid": "uuid-de", "detour": "jump"},
    {"type": "trojan", "tag": "NL", "server": "nl.example", "server_port": 443,
     "password": "pass-nl"},
    {"type": "shadowsocks", "tag": "jump", "server": "jump.example",
     "server_port": 8388, "method": "aes-256-gcm", "password": "pass-jump"},
    {"type": "urltest", "tag": "Fastest", "outbounds": ["DE", "NL"],
     "interval": "5m", "tolerance": 100},
    {"type": "direct", "tag": "direct"},
    {"type": "block", "tag": "block"}
  ],
  "route": {"rules": [{"protocol": "dns", "outbound": "dns-out"}]}
}
''';

    final r = await parseFromSource(const InlineSource(body));
    // DE + NL + группа. `jump` — звено DE, служебные не в счёт.
    expect(r.nodes, hasLength(3));
    final de = r.nodes.firstWhere((n) => n.label == 'DE');
    expect(de.chained?.server, 'jump.example');

    final list = UserServer(
      id: 'sb',
      name: 'SB',
      enabled: true,
      tagPrefix: '',
      detourPolicy: DetourPolicy.defaults,
      origin: UserSource.paste,
      createdAt: DateTime.now(),
      rawBody: body,
      nodes: r.nodes,
    );

    final result = await buildConfig(
      lists: [list],
      template: template,
      settings: const BuildSettings(
        userVars: {'clash_api': '127.0.0.1:9090'},
        enabledGroups: {'vpn-1', kAutoOutboundTag},
      ),
    );

    expect(result.validation.isOk, true,
        reason: result.validation.issues.join('\n'));

    final outs = result.config['outbounds'] as List;
    final tags = outs.map((o) => (o as Map)['tag']).toSet();
    expect(tags, containsAll(['DE', 'NL', 'Fastest']));

    // Цепочка развернулась обратно в `detour`-поле, звено эмитится отдельным
    // outbound'ом (§018 round-trip).
    final deOut = outs.firstWhere((o) => (o as Map)['tag'] == 'DE') as Map;
    expect(deOut['detour'], isNotNull);
    expect(tags, contains(deOut['detour']));

    // Группа импортировалась как urltest и ссылается на существующие теги.
    final group = outs.firstWhere((o) => (o as Map)['tag'] == 'Fastest') as Map;
    expect(group['type'], 'urltest');
    expect(group['outbounds'], containsAll(['DE', 'NL']));
    expect(group['interval'], '5m');
    expect(group['tolerance'], 100);

    // Секции чужого конфига не переехали: маршруты/DNS наши.
    final route = result.config['route'] as Map;
    final rules = route['rules'] as List;
    expect(rules.any((r) => (r as Map)['outbound'] == 'dns-out'), isFalse);
  });
}
