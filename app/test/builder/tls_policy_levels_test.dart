import 'package:flutter_test/flutter_test.dart';
import 'package:lxbox/config/consts.dart';
import 'package:lxbox/models/node_link.dart';
import 'package:lxbox/models/parser_config.dart';
import 'package:lxbox/models/server_list.dart';
import 'package:lxbox/models/tls_policy.dart';
import 'package:lxbox/services/builder/build_config.dart';
import 'package:lxbox/services/parser/uri_parsers.dart';

import '../parser/engine_test_setup.dart';

/// §636 — TLS-ручки на узле, папке и подписке: узел → источник → глобально,
/// по каждому полю отдельно; REALITY фрагментируется только от узлового
/// флага; mixed-case SNI на REALITY — никогда.
const _uuid = '11111111-2222-3333-4444-555555555555';

String _tlsUri(String tag, {String sni = 'a.example'}) =>
    'vless://$_uuid@h-$tag.example:443?security=tls&sni=$sni&type=tcp#$tag';

String _realityUri(String tag) =>
    'vless://$_uuid@r-$tag.example:443?security=reality&sni=r.example'
    '&pbk=2NtvNsBpKxbXdM10sXCDOedKkdZ3gwAs3WUnwqbv5Hs&sid=01bd983cc160a26a'
    '&fp=chrome&type=tcp#$tag';

UserServer _server(String id, String uri,
        {TlsPolicy tls = TlsPolicy.none,
        DetourPolicy detour = DetourPolicy.defaults}) =>
    UserServer(
      id: id,
      name: '',
      enabled: true,
      tagPrefix: '',
      detourPolicy: detour,
      tls: tls,
      rawBody: uri,
      nodes: [parseUri(uri)!],
    );

SubscriptionServers _sub(String id, List<String> uris,
        {TlsPolicy tls = TlsPolicy.none}) =>
    SubscriptionServers(
      id: id,
      name: id,
      enabled: true,
      tagPrefix: '',
      detourPolicy: DetourPolicy.defaults,
      tls: tls,
      url: 'https://$id.example/sub',
      nodes: [for (final u in uris) parseUri(u)!],
    );

FolderServers _folder(String id, List<FolderMember> members,
        {TlsPolicy tls = TlsPolicy.none}) =>
    FolderServers(
      id: id,
      name: id,
      enabled: true,
      tagPrefix: '',
      detourPolicy: DetourPolicy.defaults,
      tls: tls,
      members: members,
    );

final _template = WizardTemplate(
  groupTemplates: GroupTemplates(
    direction: DirectionTemplate(include: const ['direct', 'auto']),
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
      // Outbound шаблона — не из источника: только глобальный слой.
      {
        'tag': 'jump-out',
        'type': 'vless',
        'server': 'jump.example.com',
        'server_port': 443,
        'uuid': _uuid,
        'tls': {'enabled': true, 'server_name': 'jump.example.com'},
      },
    ],
    'route': {'rules': []},
  },
  selectableRules: const [],
  dnsOptions: const {},
  pingOptions: const {},
  speedTestOptions: const {},
);

Future<Map<String, Map<String, dynamic>>> _build(
  List<ServerList> lists, {
  Map<String, String> vars = const {},
}) async {
  final result = await buildConfig(
    lists: lists,
    template: _template,
    settings: BuildSettings(
      userVars: {'clash_api': '127.0.0.1:9090', ...vars},
      enabledGroups: const {'vpn-1', kAutoOutboundTag},
    ),
  );
  return {
    for (final o in result.config['outbounds'] as List)
      if (o is Map<String, dynamic> && o['tag'] is String)
        o['tag'] as String: o,
  };
}

Map<String, dynamic> _tls(Map<String, Map<String, dynamic>> obs, String tag) =>
    (obs[tag]!['tls'] as Map).cast<String, dynamic>();

const _on = {'tls_fragment': 'true'};

void main() {
  // Секции разбора и реестр (годность `tls.fragment` телу).
  setUpAll(loadEngineSections);

  test('узел Off при глобальном On — без флага, сосед с флагом', () async {
    final obs = await _build([
      _server('s1', _tlsUri('A'), tls: const TlsPolicy(fragment: false)),
      _server('s2', _tlsUri('B')),
    ], vars: _on);
    expect(_tls(obs, 'A').containsKey('fragment'), isFalse);
    expect(_tls(obs, 'A').containsKey('fragment_fallback_delay'), isFalse);
    expect(_tls(obs, 'B')['fragment'], isTrue);
  });

  test('узел On при глобальном Off', () async {
    final obs = await _build([
      _server('s1', _tlsUri('A'), tls: const TlsPolicy(fragment: true)),
      _server('s2', _tlsUri('B')),
    ]);
    expect(_tls(obs, 'A')['fragment'], isTrue);
    expect(_tls(obs, 'A')['fragment_fallback_delay'], '500ms');
    expect(_tls(obs, 'B').containsKey('fragment'), isFalse);
  });

  test('папка On, член Off', () async {
    final obs = await _build([
      _folder('f1', [
        FolderMember(
            raw: _tlsUri('M1'), tls: const TlsPolicy(fragment: false)),
        FolderMember(raw: _tlsUri('M2')),
      ], tls: const TlsPolicy(fragment: true)),
    ]);
    expect(_tls(obs, 'M1').containsKey('fragment'), isFalse);
    expect(_tls(obs, 'M2')['fragment'], isTrue);
  });

  test('подписка On — все её first-hop с флагом, чужая без', () async {
    final obs = await _build([
      _sub('p1', [_tlsUri('P1'), _tlsUri('P2')],
          tls: const TlsPolicy(recordFragment: true)),
      _sub('p2', [_tlsUri('Q1')]),
    ]);
    expect(_tls(obs, 'P1')['record_fragment'], isTrue);
    expect(_tls(obs, 'P2')['record_fragment'], isTrue);
    expect(_tls(obs, 'Q1').containsKey('record_fragment'), isFalse);
  });

  test('fallback_delay узла побеждает глобальную, негодная — 500ms',
      () async {
    final obs = await _build([
      _server('s1', _tlsUri('A'),
          tls: const TlsPolicy(fallbackDelay: '200ms')),
      _server('s2', _tlsUri('B'), tls: const TlsPolicy(fallbackDelay: 'fast')),
      _server('s3', _tlsUri('C')),
    ], vars: {..._on, 'tls_fragment_fallback_delay': '1s'});
    expect(_tls(obs, 'A')['fragment_fallback_delay'], '200ms');
    expect(_tls(obs, 'B')['fragment_fallback_delay'], '500ms');
    expect(_tls(obs, 'C')['fragment_fallback_delay'], '1s');
  });

  test('outbound не из источника — только глобальный слой', () async {
    final off = await _build([
      _sub('p1', [_tlsUri('P1')], tls: const TlsPolicy(fragment: false)),
    ], vars: _on);
    expect(_tls(off, 'jump-out')['fragment'], isTrue);
    expect(_tls(off, 'P1').containsKey('fragment'), isFalse);

    final on = await _build([
      _sub('p1', [_tlsUri('P1')], tls: const TlsPolicy(fragment: true)),
    ]);
    expect(_tls(on, 'jump-out').containsKey('fragment'), isFalse);
  });

  test('узел под detour не получает ничего', () async {
    final obs = await _build([
      _server('s1', _tlsUri('A'),
          tls: const TlsPolicy(
              fragment: true, recordFragment: true, mixedCaseSni: true),
          detour: const DetourPolicy(
              overrideDetour: NodeLink(tag: 'jump-out'))),
    ]);
    final a = obs['A']!;
    expect(a['detour'], 'jump-out');
    final tls = _tls(obs, 'A');
    expect(tls.containsKey('fragment'), isFalse);
    expect(tls.containsKey('record_fragment'), isFalse);
    expect(tls['server_name'], 'a.example');
  });

  group('REALITY', () {
    test('узловой On применяется', () async {
      final obs = await _build([
        _server('s1', _realityUri('R'),
            tls: const TlsPolicy(fragment: true)),
        _folder('f1', [
          FolderMember(
              raw: _realityUri('RM'),
              tls: const TlsPolicy(recordFragment: true)),
        ]),
      ]);
      expect(_tls(obs, 'R')['fragment'], isTrue);
      expect(_tls(obs, 'RM')['record_fragment'], isTrue);
    });

    test('подписка и папка On — пропуск', () async {
      final obs = await _build([
        _sub('p1', [_realityUri('RS')],
            tls: const TlsPolicy(fragment: true, recordFragment: true)),
        _folder('f1', [FolderMember(raw: _realityUri('RF'))],
            tls: const TlsPolicy(fragment: true)),
      ]);
      for (final tag in ['RS', 'RF']) {
        final tls = _tls(obs, tag);
        expect(tls.containsKey('fragment'), isFalse, reason: tag);
        expect(tls.containsKey('record_fragment'), isFalse, reason: tag);
        expect(tls.containsKey('fragment_fallback_delay'), isFalse,
            reason: tag);
      }
    });

    test('узловой On не тянет глобальный флаг другого поля', () async {
      final obs = await _build([
        _server('s1', _realityUri('R'),
            tls: const TlsPolicy(fragment: true)),
      ], vars: {'tls_record_fragment': 'true'});
      expect(_tls(obs, 'R')['fragment'], isTrue);
      expect(_tls(obs, 'R').containsKey('record_fragment'), isFalse);
    });

    test('mixed-case SNI — никогда, ни на каком уровне', () async {
      final obs = await _build([
        _server('s1', _realityUri('R'),
            tls: const TlsPolicy(mixedCaseSni: true)),
        _sub('p1', [_realityUri('RS')],
            tls: const TlsPolicy(mixedCaseSni: true)),
      ], vars: {'tls_mixed_case_sni': 'true'});
      expect(_tls(obs, 'R')['server_name'], 'r.example');
      expect(_tls(obs, 'RS')['server_name'], 'r.example');
    });
  });

  test('mixed-case SNI: узел On при глобальном Off, источник Off бьёт глобальный',
      () async {
    const sni = 'abcdefghijklmnopqrstuvwxyzabcdefgh.example';
    final obs = await _build([
      _server('s1', _tlsUri('A', sni: sni),
          tls: const TlsPolicy(mixedCaseSni: true)),
      _sub('p1', [_tlsUri('P1', sni: sni)],
          tls: const TlsPolicy(mixedCaseSni: false)),
    ]);
    final a = _tls(obs, 'A')['server_name'] as String;
    expect(a.toLowerCase(), sni);
    expect(a, isNot(sni));
    expect(_tls(obs, 'P1')['server_name'], sni);

    final g = await _build([
      _sub('p1', [_tlsUri('P1', sni: sni)],
          tls: const TlsPolicy(mixedCaseSni: false)),
    ], vars: {'tls_mixed_case_sni': 'true'});
    expect(_tls(g, 'P1')['server_name'], sni);
  });
}
