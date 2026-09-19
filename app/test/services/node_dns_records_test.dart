import 'package:flutter_test/flutter_test.dart';
import 'package:lxbox/models/dns_ref.dart';
import 'package:lxbox/models/node_sections.dart';
import 'package:lxbox/models/node_spec.dart';
import 'package:lxbox/models/server_list.dart';
import 'package:lxbox/services/dns/node_dns_records.dart';

import '../parser/engine_test_setup.dart';

/// §435 — деривация DNS-записей узлов для экрана DNS Settings (спека §9.2)
/// и опций `endpoint` формы сервера `tailscale` (§9.4): чистая функция над
/// `List<ServerList>`, без storage.
void main() {
  // §480 W7 — эмит ссылки исполняет секции реестра; рукописного `toUri` у
  // схем не осталось.
  setUpAll(loadEngineSections);

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
              'name': '',
              'enabled': true,
              'body': {
                'domain_suffix': ['.ts.net'],
                'server': '@{self}-dns',
              },
            },
          ],
        },
      })!;

  TailscaleSpec ts(String tag) => TailscaleSpec(
        id: 'ts-$tag',
        tag: tag,
        label: tag,
        body: const {'auth_key': 'tskey'},
      );

  SocksSpec socks(String tag) => SocksSpec(
        id: 'socks-$tag',
        tag: tag,
        label: tag,
        server: '10.0.0.1',
        port: 1080,
        rawSource: 'socks://10.0.0.1:1080#$tag',
      );

  UserServer user(
    NodeSpec node, {
    NodeSections? sections,
    bool enabled = true,
    String prefix = '',
    bool withNodes = true,
  }) =>
      UserServer(
        id: 'u-${node.tag}',
        name: '',
        enabled: enabled,
        tagPrefix: prefix,
        detourPolicy: DetourPolicy.defaults,
        origin: UserSource.manual,
        rawBody: node.toUri(),
        sections: sections,
        nodes: withNodes ? [node] : const [],
      );

  FolderServers folder(List<FolderMember> members,
          {bool enabled = true, String prefix = ''}) =>
      FolderServers(
        id: 'f-${members.length}',
        name: 'F',
        enabled: enabled,
        tagPrefix: prefix,
        detourPolicy: DetourPolicy.defaults,
        members: members,
      );

  test('пустой вход → пустые списки', () {
    final r = collectNodeDnsRecords(const []);
    expect(r.isEmpty, isTrue);
  });

  test('UserServer с секциями: сервер и правило после подстановки @self',
      () {
    final r = collectNodeDnsRecords([user(ts('home-ts'), sections: canonical())]);

    expect(r.servers, hasLength(1));
    final s = r.servers.single;
    expect(s.nodeTag, 'home-ts');
    expect(s.nodeEnabled, isTrue);
    expect(s.server.tag, 'home-ts-dns');
    expect(s.server.body, {'type': 'tailscale', 'endpoint': 'home-ts'});

    expect(r.rules, hasLength(1));
    final rule = r.rules.single;
    expect(rule.nodeTag, 'home-ts');
    expect(rule.rule.rule, {
      'domain_suffix': ['.ts.net'],
      'server': 'home-ts-dns',
    });
    expect(rule.rule.enabled, isTrue);

    // Узел Tailscale — опция endpoint.
    expect(r.tailscaleEndpoints.map((o) => o.tag), ['home-ts']);
    expect(r.tailscaleEndpoints.single.enabled, isTrue);
  });

  test('tag_prefix папки входит в подстановку (display-тег)', () {
    final r = collectNodeDnsRecords([
      folder([FolderMember(raw: ts('home-ts').toUri(), sections: canonical())],
          prefix: 'P'),
    ]);
    expect(r.servers.single.nodeTag, 'P home-ts');
    expect(r.servers.single.server.tag, 'P home-ts-dns');
    expect(r.servers.single.server.body['endpoint'], 'P home-ts');
    expect(r.rules.single.rule.rule['server'], 'P home-ts-dns');
    expect(r.tailscaleEndpoints.single.tag, 'P home-ts');
  });

  test('выключенный источник / член — записи остаются с nodeEnabled: false',
      () {
    final r = collectNodeDnsRecords([
      user(ts('off-user'), sections: canonical(), enabled: false),
      folder([
        FolderMember(
            raw: ts('off-member').toUri(),
            sections: canonical(),
            enabled: false),
        FolderMember(raw: ts('on-member').toUri(), sections: canonical()),
      ]),
      folder([FolderMember(raw: ts('in-off-folder').toUri(), sections: canonical())],
          enabled: false),
    ]);

    final byTag = {for (final s in r.servers) s.nodeTag: s.nodeEnabled};
    expect(byTag, {
      'off-user': false,
      'off-member': false,
      'on-member': true,
      'in-off-folder': false,
    });
    final epByTag = {for (final o in r.tailscaleEndpoints) o.tag: o.enabled};
    expect(epByTag, {
      'off-user': false,
      'off-member': false,
      'on-member': true,
      'in-off-folder': false,
    });
    // Порядок хранения сохраняется.
    expect(r.rules.map((x) => x.nodeTag).toList(),
        ['off-user', 'off-member', 'on-member', 'in-off-folder']);
  });

  test('узел без секций даёт только опцию endpoint; не-Tailscale — ничего',
      () {
    final r = collectNodeDnsRecords([
      user(ts('bare-ts')),
      user(socks('proxy')),
    ]);
    expect(r.servers, isEmpty);
    expect(r.rules, isEmpty);
    expect(r.tailscaleEndpoints.map((o) => o.tag), ['bare-ts']);
  });

  test('не-Tailscale узел с секциями: записи есть, опции endpoint нет', () {
    final sections = NodeSections(
      dnsServers: const [
        DnsServerInline(
          enabled: true,
          tag: '@{self}-dns',
          body: {'type': 'udp', 'server': '10.0.0.53', 'detour': '@self'},
        ),
      ],
      dnsRules: const [
        DnsRuleInline(
          name: 'lan',
          rule: {'domain_suffix': ['.lan'], 'server': '@{self}-dns'},
          enabled: false,
        ),
      ],
    );
    final r = collectNodeDnsRecords([user(socks('proxy'), sections: sections)]);
    expect(r.tailscaleEndpoints, isEmpty);
    expect(r.servers.single.server.body['detour'], 'proxy');
    // `enabled: false` записи переживает подстановку (round-trip кодека).
    expect(r.rules.single.rule.enabled, isFalse);
    expect(r.rules.single.rule.name, 'lan');
  });

  test('узел без распарсенного NodeSpec пропускается (тега нет)', () {
    final r = collectNodeDnsRecords([
      user(ts('ghost'), sections: canonical(), withNodes: false),
      folder([FolderMember(raw: 'not a node', sections: canonical())]),
    ]);
    expect(r.isEmpty, isTrue);
  });

  test('дубль display-тега Tailscale — одна опция (первый побеждает)', () {
    final r = collectNodeDnsRecords([
      user(ts('dup'), enabled: false),
      user(ts('dup')),
    ]);
    expect(r.tailscaleEndpoints, hasLength(1));
    expect(r.tailscaleEndpoints.single.enabled, isFalse);
  });

  test('подписки не участвуют', () {
    final sub = SubscriptionServers(
      id: 's1',
      name: 'S',
      enabled: true,
      tagPrefix: '',
      detourPolicy: DetourPolicy.defaults,
      url: 'https://example.com/sub',
      nodes: [ts('sub-ts')],
    );
    final r = collectNodeDnsRecords([sub]);
    expect(r.isEmpty, isTrue);
  });
}
