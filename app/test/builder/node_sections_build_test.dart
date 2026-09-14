import 'package:flutter_test/flutter_test.dart';
import 'package:lxbox/config/consts.dart';
import 'package:lxbox/models/custom_rule.dart';
import 'package:lxbox/models/dns_ref.dart';
import 'package:lxbox/models/node_sections.dart';
import 'package:lxbox/models/node_spec.dart';
import 'package:lxbox/models/parser_config.dart';
import 'package:lxbox/models/server_list.dart';
import 'package:lxbox/models/tailscale_bundle.dart';
import 'package:lxbox/services/builder/build_config.dart';
import 'package:lxbox/services/builder/core_chain_capability.dart';
import 'package:lxbox/services/parser/uri_parsers.dart';

/// §435 / контракт ## 13 — инъекция секций узла при сборке
/// (NODE_SECTIONS.md §3), Tailscale (§6), гейт ядра.
void main() {
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
    selectableRules: const [],
    dnsOptions: const {},
    pingOptions: const {},
    speedTestOptions: const {},
  );

  const settings = BuildSettings(enabledGroups: {'vpn-1', kAutoOutboundTag});

  NodeSections canonical() => NodeSections.fromJson({
        'rules': [
          {
            'kind': 'inline',
            'name': '@{self} network',
            'enabled': true,
            'body': {
              'ip_cidr': ['100.64.0.0/10'],
              'outbound': '@self',
            },
          },
        ],
        'dns': {
          'servers': [
            {
              'kind': 'user',
              'tag': '@{self}-dns',
              'enabled': true,
              'body': {'type': 'tailscale', 'endpoint': '@self'},
            },
          ],
          'rules': [
            {
              'kind': 'user',
              'enabled': true,
              'body': {
                'domain_suffix': ['.ts.net'],
                'server': '@{self}-dns',
              },
            },
          ],
        },
      })!;

  TailscaleSpec ts({String tag = 'home-ts', String? exitNode}) => TailscaleSpec(
        id: 'ts-$tag',
        tag: tag,
        label: tag,
        body: {'auth_key': 'tskey', 'exit_node': ?exitNode},
      );

  UserServer user(NodeSpec node,
          {NodeSections? sections, bool enabled = true, String prefix = ''}) =>
      UserServer(
        id: 'u-${node.tag}',
        name: '',
        enabled: enabled,
        tagPrefix: prefix,
        detourPolicy: DetourPolicy.defaults,
        origin: UserSource.manual,
        createdAt: DateTime.utc(2026, 9, 14),
        rawBody: node.toUri(),
        sections: sections,
        nodes: [node],
      );

  List<Map<String, dynamic>> rules(BuildResult r) =>
      ((r.config['route'] as Map)['rules'] as List).cast<Map<String, dynamic>>();
  List<Map<String, dynamic>> endpoints(BuildResult r) =>
      ((r.config['endpoints'] as List?) ?? const []).cast<Map<String, dynamic>>();
  List<Map<String, dynamic>> dnsServers(BuildResult r) =>
      (((r.config['dns'] as Map?)?['servers'] as List?) ?? const [])
          .cast<Map<String, dynamic>>();
  List<Map<String, dynamic>> dnsRules(BuildResult r) =>
      (((r.config['dns'] as Map?)?['rules'] as List?) ?? const [])
          .cast<Map<String, dynamic>>();

  group('§435 инъекция секций', () {
    test('узел с секциями: правило на @self, DNS-сервер и правило в конце', () async {
      final r = await buildConfig(
        lists: [user(ts(), sections: canonical())],
        template: template,
        settings: settings,
      );
      expect(r.validation.isOk, isTrue, reason: r.validation.issues.join('\n'));
      expect(endpoints(r).single['tag'], 'home-ts');
      // Правило маршрута — headless rule_set с именем после подстановки.
      final rule = rules(r).where((x) => x['outbound'] == 'home-ts').single;
      expect(rule['rule_set'], 'home-ts network');
      final rs = ((r.config['route'] as Map)['rule_set'] as List)
          .cast<Map<String, dynamic>>()
          .where((x) => x['tag'] == 'home-ts network')
          .single;
      expect(rs['rules'], [
        {'ip_cidr': ['100.64.0.0/10']},
      ]);
      // DNS.
      expect(dnsServers(r).last, {'type': 'tailscale', 'endpoint': 'home-ts', 'tag': 'home-ts-dns'});
      expect(dnsRules(r).last, {'domain_suffix': ['.ts.net'], 'server': 'home-ts-dns'});
      expect(r.emitWarnings, isEmpty);
    });

    test('§437 связка v2: resolve через <тег>-dns перед терминальным правилом',
        () async {
      final r = await buildConfig(
        lists: [user(ts(), sections: canonicalTailscaleSections())],
        template: template,
        settings: settings,
      );
      expect(r.validation.isOk, isTrue, reason: r.validation.issues.join('\n'));
      // Один headless-набор на оба правила: `.ts.net` ИЛИ обе подсети tailnet.
      final rs = ((r.config['route'] as Map)['rule_set'] as List)
          .cast<Map<String, dynamic>>()
          .where((x) => x['tag'] == 'home-ts network')
          .single;
      expect(rs['rules'], [
        {
          'domain_suffix': ['.ts.net'],
          'ip_cidr': ['100.64.0.0/10', 'fd7a:115c:a1e0::/48'],
        },
      ]);
      // Нетерминальный resolve стоит ПЕРЕД маршрутом: без адреса ядро
      // отбрасывает UDP-поток к endpoint'у.
      final own = rules(r)
          .where((x) => x['rule_set'] == 'home-ts network')
          .toList();
      expect(own, hasLength(2));
      expect(own.first['action'], 'resolve');
      expect(own.first['server'], 'home-ts-dns');
      expect(own.first.containsKey('outbound'), isFalse);
      expect(own.last['outbound'], 'home-ts');
      expect(own.last.containsKey('action'), isFalse);
      final idx = rules(r).indexOf(own.first);
      expect(rules(r).indexOf(own.last), idx + 1);
      expect(dnsServers(r).last,
          {'type': 'tailscale', 'endpoint': 'home-ts', 'tag': 'home-ts-dns'});
      expect(dnsRules(r).last,
          {'domain_suffix': ['.ts.net'], 'server': 'home-ts-dns'});
      expect(r.emitWarnings, isEmpty);
    });

    test('префикс папки/списка попадает в @self', () async {
      final r = await buildConfig(
        lists: [user(ts(), sections: canonical(), prefix: '🇩🇪')],
        template: template,
        settings: settings,
      );
      expect(rules(r).where((x) => x['outbound'] == '🇩🇪 home-ts'), hasLength(1));
      expect(dnsServers(r).last['tag'], '🇩🇪 home-ts-dns');
      expect(dnsServers(r).last['endpoint'], '🇩🇪 home-ts');
    });

    test('член папки с секциями — то же, по финальному тегу члена', () async {
      final folder = FolderServers(
        id: 'f1',
        name: 'F',
        enabled: true,
        tagPrefix: 'P',
        detourPolicy: DetourPolicy.defaults,
        members: [
          FolderMember(raw: ts().toUri(), sections: canonical()),
          FolderMember(raw: ts(tag: 'other').toUri()),
        ],
      );
      final r = await buildConfig(lists: [folder], template: template, settings: settings);
      expect(rules(r).where((x) => x['outbound'] == 'P home-ts'), hasLength(1));
      expect(rules(r).where((x) => x['outbound'] == 'P other'), isEmpty);
    });

    test('ось num: без num → 945 — перед пользовательским правилом 1000', () async {
      final r = await buildConfig(
        lists: [user(ts(), sections: canonical())],
        template: template,
        settings: BuildSettings(
          enabledGroups: const {'vpn-1', kAutoOutboundTag},
          customRules: [
            CustomRuleInline(name: 'User', domains: ['a.com'], outbound: 'vpn-1', orderNum: 1000),
          ],
        ),
      );
      final order = rules(r).map((x) => x['rule_set']).whereType<String>().toList();
      expect(order.indexOf('home-ts network'), lessThan(order.indexOf('User')));
    });

    test('num из записи узла двигает правило по оси', () async {
      final s = canonical();
      s.rules.single.orderNum = 1050;
      final r = await buildConfig(
        lists: [user(ts(), sections: s)],
        template: template,
        settings: BuildSettings(
          enabledGroups: const {'vpn-1', kAutoOutboundTag},
          customRules: [
            CustomRuleInline(name: 'User', domains: ['a.com'], outbound: 'vpn-1', orderNum: 1000),
          ],
        ),
      );
      final order = rules(r).map((x) => x['rule_set']).whereType<String>().toList();
      expect(order.indexOf('home-ts network'), greaterThan(order.indexOf('User')));
    });

    test('enabled:false у записи — пропуск; выключенный узел — ничего', () async {
      final s = canonical().copyWith(
        rules: [canonical().rules.single.withEnabled(false)],
        dnsServers: [canonical().dnsServers.single.copyWith(enabled: false)],
        dnsRules: [canonical().dnsRules.single.copyWith(enabled: false)],
      );
      final r1 = await buildConfig(lists: [user(ts(), sections: s)], template: template, settings: settings);
      expect(rules(r1).where((x) => x['outbound'] == 'home-ts'), isEmpty);
      expect(dnsServers(r1).where((x) => x['type'] == 'tailscale'), isEmpty);
      expect(dnsRules(r1), isEmpty);

      final r2 = await buildConfig(
        lists: [user(ts(), sections: canonical(), enabled: false)],
        template: template,
        settings: settings,
      );
      expect(endpoints(r2), isEmpty);
      expect(rules(r2).where((x) => x['outbound'] == 'home-ts'), isEmpty);
      expect(dnsServers(r2), isEmpty);
    });

    test('инвариант: без секций конфиг байт-в-байт прежний', () async {
      final a = await buildConfig(lists: [user(ts())], template: template, settings: settings);
      final b = await buildConfig(
        lists: [user(ts(), sections: const NodeSections())],
        template: template,
        settings: settings,
      );
      expect(b.configJson, a.configJson);
    });
  });

  group('§435 DNS-санитайзер endpoint', () {
    test('DNS-сервер tailscale на отсутствующий endpoint выброшен вместе с правилом', () async {
      final vless = parseUri('vless://u1@h1.com:443?type=ws&security=tls#A')!;
      final r = await buildConfig(
        lists: [user(vless, sections: canonical())],
        template: template,
        settings: settings,
      );
      // Узел не tailscale: сервер `type: tailscale` с endpoint=A висит.
      expect(dnsServers(r).where((x) => x['type'] == 'tailscale'), isEmpty);
      expect(dnsRules(r), isEmpty);
      expect(r.emitWarnings.any((w) => w.contains('DNS server "A-dns" dropped')), isTrue);
      expect(r.emitWarnings.any((w) => w.contains('Node DNS rule dropped')), isTrue);
      // Правило маршрута при этом живёт.
      expect(rules(r).where((x) => x['outbound'] == 'A'), hasLength(1));
    });

    test('второй DNS-сервер на тот же endpoint выброшен (один на узел)', () async {
      final s = canonical().copyWith(dnsServers: [
        canonical().dnsServers.single,
        const DnsServerInline(
          enabled: true,
          tag: '@{self}-dns2',
          body: {'type': 'tailscale', 'endpoint': '@self'},
        ),
      ]);
      final r = await buildConfig(lists: [user(ts(), sections: s)], template: template, settings: settings);
      expect(dnsServers(r).where((x) => x['type'] == 'tailscale').map((x) => x['tag']), ['home-ts-dns']);
      expect(r.emitWarnings.any((w) => w.contains('already has a DNS server')), isTrue);
    });

    test('дубль тега DNS-сервера узла — первый побеждает', () async {
      final s = canonical().copyWith(dnsServers: [
        canonical().dnsServers.single,
        canonical().dnsServers.single.copyWith(body: const {'type': 'udp', 'server': '9.9.9.9'}),
      ]);
      final r = await buildConfig(lists: [user(ts(), sections: s)], template: template, settings: settings);
      expect(dnsServers(r).where((x) => x['tag'] == 'home-ts-dns'), hasLength(1));
      expect(dnsServers(r).where((x) => x['tag'] == 'home-ts-dns').single['type'], 'tailscale');
      expect(r.emitWarnings.any((w) => w.contains('already taken')), isTrue);
    });
  });

  group('§435 Tailscale — state_directory, гейт ядра, Направления', () {
    test('state_directory подставляется при известном корне, тело не трогается', () async {
      final node = ts(tag: '🇩🇪 home ts/1');
      final r = await buildConfig(
        lists: [user(node)],
        template: template,
        settings: const BuildSettings(
          enabledGroups: {'vpn-1', kAutoOutboundTag},
          tailscaleStateRoot: '/data/user/0/app/files',
        ),
      );
      expect(endpoints(r).single['state_directory'],
          '/data/user/0/app/files/tailscale/${tailscaleStateDirName('🇩🇪 home ts/1')}');
      // Флаг — два code point'а (regional indicators) → два `_`, как у Go по рунам.
      expect(tailscaleStateDirName('🇩🇪 home ts/1'), '___home_ts_1');
      expect(tailscaleStateDirName('///'), '___');
      expect(tailscaleStateDirName(''), 'tailscale');
      expect(node.body.containsKey('state_directory'), isFalse);
    });

    test('state_directory: без корня не пишется; своё значение не трогается', () async {
      final r1 = await buildConfig(lists: [user(ts())], template: template, settings: settings);
      expect(endpoints(r1).single.containsKey('state_directory'), isFalse);
      final own = TailscaleSpec(id: 'x', tag: 'x', label: 'x', body: {'state_directory': '/own'});
      final r2 = await buildConfig(
        lists: [user(own)],
        template: template,
        settings: const BuildSettings(enabledGroups: {'vpn-1'}, tailscaleStateRoot: '/root'),
      );
      expect(endpoints(r2).single['state_directory'], '/own');
    });

    test('гейт ядра: lx.36 → узел снят с warning, секции не инжектятся; lx.38 → эмиссия', () async {
      final old = await buildConfig(
        lists: [user(ts(), sections: canonical())],
        template: template,
        settings: const BuildSettings(enabledGroups: {'vpn-1'}, coreVersion: '1.14.0-lx.36'),
      );
      expect(endpoints(old), isEmpty);
      expect(rules(old).where((x) => x['outbound'] == 'home-ts'), isEmpty);
      expect(dnsServers(old), isEmpty);
      expect(old.emitWarnings.single, contains('Tailscale node "home-ts" was skipped'));
      expect(old.emitWarnings.single, contains('1.14.0-lx.36'));
      expect(old.validation.isOk, isTrue, reason: old.validation.issues.join('\n'));

      final fresh = await buildConfig(
        lists: [user(ts(), sections: canonical())],
        template: template,
        settings: const BuildSettings(enabledGroups: {'vpn-1'}, coreVersion: '1.14.0-lx.38'),
      );
      expect(endpoints(fresh).single['tag'], 'home-ts');
      expect(fresh.emitWarnings, isEmpty);
      // Неизвестная версия — поддержка есть (fail-open, как у chain).
      expect(coreVersionSupportsTailscale(''), isTrue);
      expect(coreVersionSupportsTailscale('garbage'), isTrue);
      expect(coreVersionSupportsTailscale('1.14.0-lx.37'), isFalse);
      expect(coreVersionSupportsTailscale('1.14.0-lx.38-rc.1'), isFalse);
      expect(coreVersionSupportsTailscale('1.14.0-lx.40'), isTrue);
    });

    test('без exit_node — не в пуле Направлений; с exit_node — кандидат', () async {
      final vless = parseUri('vless://u1@h1.com:443?type=ws&security=tls#A')!;
      final r = await buildConfig(
        lists: [user(ts()), user(vless), user(ts(tag: 'exit', exitNode: 'srv'))],
        template: template,
        settings: settings,
      );
      final outs = (r.config['outbounds'] as List).cast<Map<String, dynamic>>();
      final vpn1 = outs.firstWhere((o) => o['tag'] == 'vpn-1');
      final members = (vpn1['outbounds'] as List).cast<String>();
      expect(members, isNot(contains('home-ts')));
      expect(members, contains('A'));
      expect(members, contains('exit'));
      final auto = outs.firstWhere((o) => o['tag'] == 'vpn-1-auto');
      expect((auto['outbounds'] as List), isNot(contains('home-ts')));
      // Узел при этом эмитирован — законная цель detour.
      expect(endpoints(r).map((e) => e['tag']), containsAll(['home-ts', 'exit']));
    });
  });
}
