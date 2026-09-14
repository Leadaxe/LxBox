import 'package:flutter_test/flutter_test.dart';
import 'package:lxbox/models/custom_rule.dart';
import 'package:lxbox/models/dns_ref.dart';
import 'package:lxbox/models/node_sections.dart';
import 'package:lxbox/models/server_list.dart';

/// §435 — секции узла: форма ONE_NAMESPACE §2, плейсхолдер `@self`,
/// хранение у UserServer / FolderMember.
void main() {
  Map<String, dynamic> canonical() => {
        'rules': [
          {
            'kind': 'inline',
            'id': 'r1',
            'name': '@{self} network',
            'enabled': true,
            'num': 945,
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
              'name': '',
              'enabled': true,
              'body': {
                'domain_suffix': ['.ts.net'],
                'server': '@{self}-dns',
              },
            },
          ],
        },
      };

  group('§435 NodeSections', () {
    test('round-trip формы §2 байт-в-байт', () {
      final s = NodeSections.fromJson(canonical())!;
      expect(s.rules, hasLength(1));
      expect(s.dnsServers, hasLength(1));
      expect(s.dnsRules, hasLength(1));
      expect(s.toJson(), canonical());
    });

    test('пустое = отсутствие поля', () {
      expect(NodeSections.fromJson(null), isNull);
      expect(NodeSections.fromJson({}), isNull);
      expect(NodeSections.fromJson({'rules': [], 'dns': {}}), isNull);
      expect(NodeSections.fromJson('x'), isNull);
      expect(const NodeSections().toJson(), isEmpty);
    });

    test('чужой kind внутри секции отбрасывается, остальные живут', () {
      final dropped = <String>[];
      final s = NodeSections.fromJson({
        'rules': [
          {'kind': 'preset', 'name': 'p', 'ref': 'x'},
          {'kind': 'json', 'name': 'j', 'json': '{}'},
          {'kind': 'inline', 'name': 'ok', 'body': {'outbound': '@self'}},
          'garbage',
        ],
        'dns': {
          'servers': [
            {'kind': 'template', 'tag': 't'},
            {'kind': 'user', 'tag': 'u', 'body': {'type': 'udp', 'server': '1.1.1.1'}},
          ],
          'rules': [
            {'kind': 'preset', 'ref': 'p'},
            {'kind': 'user', 'body': {'server': 'u'}},
          ],
        },
      }, dropped: dropped)!;
      expect(s.rules.map((r) => r.name), ['ok']);
      expect(s.dnsServers.map((r) => r.tag), ['u']);
      expect(s.dnsRules, hasLength(1));
      expect(dropped, hasLength(5));
      expect(dropped[0], contains('preset'));
      expect(dropped[1], contains('json'));
      expect(dropped[2], contains('not an object'));
      expect(dropped[3], contains('template'));
      expect(dropped[4], contains('preset'));
    });

    test('незнакомый ключ body (rule_set, process_name) → запись отброшена целиком (B3)', () {
      final unknown = <String>[];
      final dropped = <String>[];
      final s = NodeSections.fromJson({
        'rules': [
          {'kind': 'inline', 'name': 'a', 'body': {'process_name': ['x'], 'outbound': '@self'}},
          {'kind': 'inline', 'name': 'b', 'body': {'rule_set': ['geo'], 'outbound': '@self'}},
          {'kind': 'inline', 'name': 'ok', 'body': {'ip_cidr': ['10.0.0.0/8'], 'outbound': '@self'}},
        ],
      }, unknownKeys: unknown, dropped: dropped)!;
      expect(s.rules.map((r) => r.name), ['ok']);
      expect(unknown, ['rules[0].body.process_name', 'rules[1].body.rule_set']);
      expect(dropped, hasLength(2));
      expect(dropped[1], contains('rule_set'));
    });

    test('запись без outbound и action получает outbound: @self (B5)', () {
      final s = NodeSections.fromJson({
        'rules': [
          {'kind': 'inline', 'name': 'a', 'body': {'ip_cidr': ['10.0.0.0/8']}},
          {'kind': 'inline', 'name': 'b', 'body': {'ip_cidr': ['10.0.0.0/8'], 'action': 'reject'}},
        ],
      })!;
      expect((s.rules[0] as CustomRuleInline).outbound, '@self');
      expect((s.rules[1] as CustomRuleInline).outbound, kOutboundReject);
      expect((s.toJson()['rules'] as List)[0]['body']['outbound'], '@self');
    });

    test('substituteSelf: обе формы, ключи не трогаются, не-плейсхолдеры целы', () {
      final s = NodeSections.fromJson({
        'rules': [
          {
            'kind': 'inline',
            'name': '@{self} network',
            'body': {
              'ip_cidr': ['100.64.0.0/10'],
              'domain': ['@selfish', '@self_dns', 'x@{self}y@{self}'],
              'outbound': '@self',
            },
          },
        ],
        'dns': {
          'servers': [
            {'kind': 'user', 'tag': '@{self}-dns', 'body': {'type': 'tailscale', 'endpoint': '@self'}},
          ],
          'rules': [
            {'kind': 'user', 'body': {'server': '@{self}-dns'}},
          ],
        },
      })!;
      final r = s.substituteSelf('🇩🇪 home-ts');
      final rule = r.rules.single as CustomRuleInline;
      expect(rule.name, '🇩🇪 home-ts network');
      expect(rule.outbound, '🇩🇪 home-ts');
      expect(rule.domains, ['@selfish', '@self_dns', 'x🇩🇪 home-tsy🇩🇪 home-ts']);
      expect(r.dnsServers.single.tag, '🇩🇪 home-ts-dns');
      expect(r.dnsServers.single.body['endpoint'], '🇩🇪 home-ts');
      expect(r.dnsRules.single.rule['server'], '🇩🇪 home-ts-dns');
      // Исходник не тронут — в состоянии плейсхолдеры лежат как есть.
      expect((s.rules.single as CustomRuleInline).outbound, '@self');
      expect(containsSelfPlaceholder(s.toJson()), isTrue);
      expect(containsSelfPlaceholder(r.toJson()), isFalse);
    });

    test('substituteSelfPlaceholder: ключи объектов не подставляются', () {
      final out = substituteSelfPlaceholder({'@self': '@self', '@{self}-k': ['@{self}']}, 'T');
      expect(out, {'@self': 'T', '@{self}-k': ['T']});
    });
  });

  group('§435 хранение у контейнеров', () {
    UserServer user({NodeSections? sections}) => UserServer(
          id: 'u1',
          name: '',
          enabled: true,
          tagPrefix: '',
          detourPolicy: DetourPolicy.defaults,
          origin: UserSource.manual,
          createdAt: DateTime.utc(2026, 9, 14),
          rawBody: '{"type":"tailscale","tag":"ts","auth_key":"k"}',
          sections: sections,
        );

    test('UserServer: sections пишется только непустым и переживает round-trip', () {
      final empty = user();
      expect(empty.toJson().containsKey('sections'), isFalse);
      expect(user(sections: const NodeSections()).sections, isNull);

      final us = user(sections: NodeSections.fromJson(canonical()));
      final json = us.toJson();
      expect(json['sections'], canonical());
      final back = ServerList.fromJson(json) as UserServer;
      expect(back.sections!.toJson(), canonical());
      expect(back.nodes.single.protocol, 'tailscale');
    });

    test('UserServer.copyWith: сохраняет, заменяет, снимает', () {
      final us = user(sections: NodeSections.fromJson(canonical()));
      expect(us.copyWith(enabled: false).sections, isNotNull);
      expect(us.copyWith(clearSections: true).sections, isNull);
      final other = NodeSections(rules: [CustomRuleInline(name: 'x', domains: ['a'])]);
      expect(us.copyWith(sections: other).sections!.rules.single.name, 'x');
    });

    test('FolderMember: то же трио toJson/fromJson/copyWith', () {
      final m = FolderMember(
        raw: '{"type":"tailscale","tag":"ts","auth_key":"k"}',
        sections: NodeSections.fromJson(canonical()),
      );
      expect(m.node!.protocol, 'tailscale');
      final json = m.toJson();
      expect(json['sections'], canonical());
      final back = FolderMember.fromJson(json);
      expect(back.sections!.toJson(), canonical());
      // Смена raw секции не трогает (голое тело — NODE_SECTIONS.md §7).
      expect(back.copyWith(raw: '{"type":"tailscale","tag":"ts2"}').sections, isNotNull);
      expect(back.copyWith(clearSections: true).sections, isNull);
      expect(FolderMember(raw: 'x').toJson().containsKey('sections'), isFalse);
    });

    test('DnsRuleInline.enabled: false пишется, отсутствие = true', () {
      const on = DnsRuleInline(name: 'a', rule: {'server': 'x'});
      expect(on.toJson().containsKey('enabled'), isFalse);
      const off = DnsRuleInline(name: 'a', rule: {'server': 'x'}, enabled: false);
      expect(off.toJson()['enabled'], false);
      expect((DnsRuleRef.fromJson(off.toJson()) as DnsRuleInline).enabled, isFalse);
      expect((DnsRuleRef.fromJson(on.toJson()) as DnsRuleInline).enabled, isTrue);
    });
  });
}
