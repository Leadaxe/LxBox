import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:lxbox/models/codec/chain_record.dart';
import 'package:lxbox/models/codec/source_record.dart';
import 'package:lxbox/models/import_rule.dart';
import 'package:lxbox/models/node_link.dart';
import 'package:lxbox/models/node_sections.dart';
import 'package:lxbox/models/server_list.dart';
import 'package:lxbox/models/source_chain.dart';
import 'package:lxbox/models/subscription_meta.dart';

import '../parser/engine_test_setup.dart';

/// §439 §4.2 — кодек записей `sources[]`: подписка, одиночный сервер, папка и
/// цепочка. Главное свойство — `fromRecord(toRecord(x)) == x` через JSON-текст
/// файла: на нём держится совпадение `config.json` до и после миграции.

const _uriAlpha = 'vless://11111111-1111-1111-1111-111111111111@198.51.100.1:443'
    '?type=ws&security=tls#Alpha';
const _uriBeta = 'vless://22222222-2222-2222-2222-222222222222@198.51.100.2:443'
    '?type=ws&security=tls#Beta';
const _wgIni = '[Interface]\n'
    'PrivateKey = aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaA=\n'
    'Address = 10.0.0.2/32\n'
    '\n'
    '[Peer]\n'
    'PublicKey = bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbA=\n'
    'Endpoint = node.example.com:51820\n';
const _jsonOutbound = '{"type":"tailscale","tag":"ts","auth_key":"k"}';

/// Запись как её видит следующая загрузка: через текст файла.
Map<String, dynamic> _viaFile(Map<String, dynamic> record) =>
    jsonDecode(jsonEncode(record)) as Map<String, dynamic>;

ServerList _sourceRoundTrip(ServerList l) {
  final read = sourceFromRecord(_viaFile(sourceToRecord(l)));
  expect(read.dropped, isNull);
  expect(read.unknownKeys, isEmpty,
      reason: 'кодек читает всё, что сам пишет');
  return read.value!;
}

SourceChain _chainRoundTrip(SourceChain c) {
  final read = chainFromRecord(_viaFile(chainToRecord(c)));
  expect(read.dropped, isNull);
  expect(read.unknownKeys, isEmpty);
  return read.value!;
}

NodeSections _sections() => NodeSections.fromJson({
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
    })!;

SubscriptionServers _richSubscription() => SubscriptionServers(
      id: 'sub-1',
      name: 'Proton',
      enabled: false,
      tagPrefix: 'PR',
      detourPolicy: const DetourPolicy(
        registerDetourServers: true,
        registerDetourInAuto: true,
        useDetourServers: false,
        overrideDetour: NodeLink(tag: 'vpn-2'),
        replaceDetourChain: true,
      ),
      url: 'https://example.com/sub?token=test',
      meta: const SubscriptionMeta(
        uploadBytes: 100,
        downloadBytes: 2000,
        totalBytes: 107374182400,
        expireTimestamp: 1893456000,
        profileTitle: 'Test Profile',
      ),
      lastUpdated: DateTime.utc(2026, 4, 18, 10),
      lastUpdateAttempt: DateTime.utc(2026, 4, 18, 11, 30),
      lastUpdateStatus: UpdateStatus.failed,
      updateIntervalHours: 12,
      lastNodeCount: 42,
      consecutiveFails: 3,
      disabledHashes: {
        'NL-42': DateTime.utc(2026, 7, 18, 10),
        'DE-1': DateTime.utc(2026, 7, 1, 8, 30, 15),
      },
      identity: const SubscriptionIdentityOverride(
        userAgent: 'Panel/1',
        sendHwid: true,
        hwid: 'HW-42',
        deviceOs: 'harmonyos',
        verOs: '4.2',
        deviceModel: 'P60',
      ),
      importRules: const [
        ImportRule(
          conditions: [
            ImportRuleCondition(
              path: 'tls.utls.fingerprint',
              op: ImportRuleOperator.contains,
              pattern: 'hellochrome_120',
            ),
          ],
          action: ImportRuleAction.replace,
          targetPath: 'tls.utls.fingerprint',
          replacement: 'chrome',
        ),
        ImportRule(
          conditions: [
            ImportRuleCondition(
              path: 'tag',
              op: ImportRuleOperator.matches,
              pattern: r'.*Netherlands.*',
              caseSensitive: true,
            ),
          ],
          action: ImportRuleAction.disable,
        ),
      ],
      importRulesEnabled: false,
      onUpdateAction: SubscriptionOnUpdateAction.reload,
    );

void main() {
  // §480 — разбор исполняет секции реестра; без них конвейера нет вовсе
  // (критерий 7 спеки 480).
  setUpAll(loadEngineSections);

  group('круг кодека: fromRecord(toRecord(x)) == x', () {
    test('подписка со всеми полями L и рантаймом', () {
      final s = _richSubscription();
      final back = _sourceRoundTrip(s) as SubscriptionServers;
      expect(back, s);
      // Поля, которые равенство сравнивает косвенно, — явно.
      expect(back.importRules, hasLength(2));
      expect(back.importRules[1].conditions.single.caseSensitive, isTrue);
      expect(back.identity, s.identity);
      expect(back.meta, s.meta);
      expect(back.disabledHashes, s.disabledHashes);
    });

    test('подписка с умолчаниями: лишних полей в записи нет', () {
      final s = SubscriptionServers(
        id: 'sub-2',
        name: 'Plain',
        enabled: true,
        tagPrefix: '',
        detourPolicy: DetourPolicy.defaults,
        url: 'https://example.com/plain',
      );
      final record = sourceToRecord(s);
      expect(record.keys.toSet(),
          {'kind', 'id', 'name', 'enabled', 'url', 'update'});
      expect(_sourceRoundTrip(s), s);
    });

    test('сервер с sections, detour и флагами политики', () {
      final u = UserServer(
        id: 'srv-1',
        name: '',
        enabled: true,
        tagPrefix: 'T',
        detourPolicy: const DetourPolicy(
          overrideDetour: NodeLink(tag: 'Jump'),
          useDetourServers: false,
        ),
        rawBody: _jsonOutbound,
        sections: _sections(),
      );
      final back = _sourceRoundTrip(u) as UserServer;
      expect(back, u);
      expect(back.sections!.toJson(), u.sections!.toJson());
      expect(back.nodes.single.tag, 'ts');
    });

    test('сервер из нескольких узлов остаётся одной записью', () {
      final u = UserServer(
        id: 'srv-multi',
        name: '',
        enabled: true,
        tagPrefix: '',
        detourPolicy: DetourPolicy.defaults,
        rawBody: '$_uriAlpha\n$_uriBeta',
      );
      final record = sourceToRecord(u);
      expect(record['tag'], 'Alpha', reason: 'тег первого узла');
      expect((record['origin'] as Map)['raw'], u.rawBody,
          reason: 'исходник целиком');
      final back = _sourceRoundTrip(u) as UserServer;
      expect(back, u);
      expect(back.nodes.map((n) => n.tag), ['Alpha', 'Beta']);
    });

    test('папка: unsupported-член, личный detour, секции члена, префикс с '
        'пробелом, ping, created_at', () {
      final f = FolderServers(
        id: 'fold-1',
        name: 'Личные',
        enabled: true,
        // Префикс, заданный через Debug API, с хвостовым пробелом.
        tagPrefix: 'F ',
        detourPolicy: const DetourPolicy(
            overrideDetour: NodeLink(tag: 'vpn-1'), registerDetourServers: true),
        createdAt: DateTime.utc(2026, 7, 4, 12, 30, 1, 250),
        pingUrl: 'http://1.1.1.1/cdn-cgi/trace',
        pingTimeoutMs: 3000,
        members: [
          FolderMember(raw: _uriAlpha, detour: NodeLink(tag: 'Beta')),
          FolderMember(raw: _uriBeta, enabled: false),
          FolderMember(raw: 'foo://not-a-node'),
          FolderMember(raw: _jsonOutbound, sections: _sections()),
          // §456 — тег INI-члена живёт в записи и возвращается nameHint'ом.
          FolderMember(raw: _wgIni, nameHint: 'WireGuard'),
        ],
      );
      final record = sourceToRecord(f);
      expect((record['tag_policy'] as Map)['prefix'], 'F  ',
          reason: 'разделитель дописан к префиксу модели');
      final nodes = (record['nodes'] as List).cast<Map<String, dynamic>>();
      expect(nodes.map((n) => n['kind']),
          ['server', 'server', 'unsupported', 'server', 'server']);
      expect(nodes[2]['reason'], kMemberUnparsedReason);
      expect(nodes[0]['detour'], {'tag': 'Beta'});

      final back = _sourceRoundTrip(f) as FolderServers;
      expect(back, f);
      expect(back.tagPrefix, 'F ');
      expect(back.members[2].node, isNull);
      expect(back.nodes.map((n) => n.tag), ['Alpha', 'ts', _wgTagOf(back)]);
    });

    test('цепочка с rewrite, strip, strip_evasion и label', () {
      const c = SourceChain(
        tag: 'chain-1',
        label: 'Work',
        enabled: false,
        hops: [NodeLink(tag: 'PR NL-1'), NodeLink(tag: 'Tokyo'), NodeLink(tag: 'vpn-1')],
        idleTimeout: '5m',
        stripEvasion: false,
        strip: {'tls.utls': true, 'tls.fragment': false},
        rewrite: {
          'vless': {'flow': null, 'packet_encoding': 'xudp'},
        },
      );
      final back = _chainRoundTrip(c);
      expect(back, c);
      expect((back.rewrite['vless'] as Map).containsKey('flow'), isTrue);
    });

    test('toRecord стабилен: запись после круга та же', () {
      final all = <Object>[
        _richSubscription(),
        UserServer(
          id: 'u',
          name: '',
          enabled: true,
          tagPrefix: '',
          detourPolicy: DetourPolicy.defaults,
          rawBody: _wgIni,
        ),
        FolderServers(
          id: 'f',
          name: 'F',
          enabled: true,
          tagPrefix: '',
          detourPolicy: DetourPolicy.defaults,
          createdAt: DateTime.utc(2026),
          members: [FolderMember(raw: 'garbage')],
        ),
        const SourceChain(tag: 'c', hops: [NodeLink(tag: 'a'), NodeLink(tag: 'b')]),
      ];
      for (final x in all) {
        final first = x is SourceChain
            ? chainToRecord(x)
            : sourceToRecord(x as ServerList);
        final second = x is SourceChain
            ? chainToRecord(_chainRoundTrip(x))
            : sourceToRecord(_sourceRoundTrip(x as ServerList));
        expect(jsonEncode(second), jsonEncode(first), reason: '$x');
      }
    });
  });

  group('форма записи', () {
    test('подписка: tag_policy, update, disabled в unix seconds, detour-ссылка',
        () {
      final record = sourceToRecord(_richSubscription());
      expect(record['kind'], 'subscription');
      expect(record['tag_policy'], {'prefix': 'PR '});
      expect(record['update'], {'interval_hours': 12});
      expect(record['disabled'], {
        'NL-42': DateTime.utc(2026, 7, 18, 10).millisecondsSinceEpoch ~/ 1000,
        'DE-1': DateTime.utc(2026, 7, 1, 8, 30, 15).millisecondsSinceEpoch ~/
            1000,
      });
      expect(record['detour'], {'tag': 'vpn-2'});
      expect((record['detour_policy'] as Map).containsKey('override_detour'),
          isFalse);
      expect(record.containsKey('nodes'), isFalse,
          reason: 'узлы подписки живут в sub_cache/');
      for (final old in ['type', 'tag_prefix', 'update_interval_hours',
        'disabled_hashes']) {
        expect(record.containsKey(old), isFalse, reason: old);
      }
    });

    test('отметка disabled теряет доли секунды, равенство это учитывает', () {
      final withMs = SubscriptionServers(
        id: 's',
        name: 'S',
        enabled: true,
        tagPrefix: '',
        detourPolicy: DetourPolicy.defaults,
        url: 'https://e.com/sub',
        disabledHashes: {'a': DateTime.utc(2026, 7, 18, 10, 0, 0, 999)},
      );
      final back = _sourceRoundTrip(withMs) as SubscriptionServers;
      expect(back.disabledHashes['a'], DateTime.utc(2026, 7, 18, 10));
      expect(back, withMs);
    });

    test('сервер: tag из узла, origin.kind по тексту; name, origin модели и '
        'created_at не пишутся', () {
      UserServer server(String raw) => UserServer(
            id: 'u',
            name: 'Legacy name',
            enabled: true,
            tagPrefix: '',
            detourPolicy: DetourPolicy.defaults,
            origin: UserSource.paste,
            rawBody: raw,
          );
      final uri = sourceToRecord(server(_uriAlpha));
      expect(uri['kind'], 'server');
      expect(uri['tag'], 'Alpha');
      expect(uri['origin'], {'kind': 'uri', 'raw': _uriAlpha});
      expect(uri.keys.toSet(), {'kind', 'id', 'tag', 'enabled', 'origin'});
      expect((sourceToRecord(server(_wgIni))['origin'] as Map)['kind'],
          'wg_ini');
      expect((sourceToRecord(server(_jsonOutbound))['origin'] as Map)['kind'],
          'json');

      final back = _sourceRoundTrip(server(_uriAlpha)) as UserServer;
      expect(back.name, '');
      expect(back.origin, UserSource.manual);
    });

    test('цепочка: настройки в body, позиции ссылками, поля позиции нет', () {
      final record = chainToRecord(const SourceChain(
          tag: 'c', label: 'L', hops: [NodeLink(tag: 'a'), NodeLink(tag: 'b')], idleTimeout: '1m'));
      expect(record, {
        'kind': 'chain',
        'tag': 'c',
        'enabled': true,
        'label': 'L',
        'body': {'type': 'chain', 'idle_timeout': '1m'},
        'hops': [
          {'tag': 'a'},
          {'tag': 'b'},
        ],
      });
    });
  });

  group('терпимое чтение', () {
    test('ссылка строкой читается корневой ссылкой', () {
      final l = sourceFromRecord({
        'kind': 'server',
        'id': 'u',
        'detour': 'vpn-1',
        'origin': {'kind': 'uri', 'raw': _uriAlpha},
      }).value!;
      expect(l.detourPolicy.overrideDetour, const NodeLink(tag: 'vpn-1'));
    });

    test('ссылка на член папки читается парой как есть, без отметки', () {
      // D-112 — пара — рабочая форма ссылки; разбирает её сборка.
      final notes = <String>[];
      final l = sourceFromRecord({
        'kind': 'server',
        'id': 'u',
        'detour': {'folder_id': ' f1 ', 'tag': 'Alpha'},
        'origin': {'kind': 'uri', 'raw': _uriBeta},
      }, notes: notes).value!;
      expect(l.detourPolicy.overrideDetour,
          const NodeLink(folderId: 'f1', tag: 'Alpha'));
      expect(notes, isEmpty);
    });

    test('незнакомые ключи — путями в unknownKeys, запись живёт', () {
      final read = sourceFromRecord({
        'kind': 'subscription',
        'id': 's',
        'url': 'https://e.com',
        'fold': true,
        'tag_policy': {'prefix': 'A ', 'postfix': 'x'},
        'identity': {'hwid': 'h', 'hash_device_model': true},
        'update': {'interval_hours': 6, 'jitter': 1},
      });
      expect(read.value, isNotNull);
      expect(read.unknownKeys, [
        'fold',
        'identity.hash_device_model',
        'tag_policy.postfix',
        'update.jitter',
      ]);
      expect((read.value! as SubscriptionServers).updateIntervalHours, 6);
    });

    test('тег записи разошёлся с текстом — побеждает текст, отметка в notes',
        () {
      final notes = <String>[];
      final u = sourceFromRecord({
        'kind': 'server',
        'id': 'u',
        'tag': 'Stale',
        'origin': {'kind': 'uri', 'raw': _uriAlpha},
      }, notes: notes).value!;
      expect(u.nodes.single.tag, 'Alpha');
      expect(notes.single, contains('Stale'));
    });

    test('запись без исходника: body с тегом записи становится JSON-текстом',
        () {
      final u = sourceFromRecord({
        'kind': 'server',
        'id': 'u',
        'tag': 'ts',
        'body': {'type': 'tailscale', 'auth_key': 'k', 'detour': 'x'},
      }).value! as UserServer;
      expect(u.nodes.single.tag, 'ts');
      expect(jsonDecode(u.rawBody), {
        'tag': 'ts',
        'type': 'tailscale',
        'auth_key': 'k',
      });
    });

    test('без kind, без id, чужой вид и цепочка — отброс с причиной', () {
      expect(sourceFromRecord({'id': 'x'}).dropped, contains('without kind'));
      expect(sourceFromRecord({'kind': 'server'}).dropped,
          contains('without id'));
      expect(sourceFromRecord({'kind': 'auto', 'id': 'x'}).dropped,
          contains('auto'));
      expect(sourceFromRecord({'kind': 'chain', 'tag': 'c'}).dropped,
          contains('chain'));
      expect(chainFromRecord({'kind': 'chain'}).dropped, contains('tag'));
      expect(chainFromRecord({'kind': 'server', 'tag': 'c'}).dropped,
          contains('not a chain'));
    });

    test('член папки чужого вида и не объект — отброшены с отметкой', () {
      final notes = <String>[];
      final f = sourceFromRecord({
        'kind': 'folder',
        'id': 'f',
        'nodes': [
          {'kind': 'chain', 'tag': 'c'},
          'text',
          {'kind': 'server', 'origin': {'kind': 'uri', 'raw': _uriAlpha}},
        ],
      }, notes: notes).value! as FolderServers;
      expect(f.members.single.node!.tag, 'Alpha');
      expect(notes, hasLength(2));
    });

    test('префикс: снимается ровно один хвостовой пробел', () {
      String prefixOf(String p) => sourceFromRecord({
            'kind': 'folder',
            'id': 'f',
            'tag_policy': {'prefix': p},
          }).value!.tagPrefix;
      expect(prefixOf('F '), 'F');
      expect(prefixOf('F  '), 'F ');
      expect(prefixOf('F'), 'F');
    });

    test('disabled: не число и пустой ключ пропускаются', () {
      final s = sourceFromRecord({
        'kind': 'subscription',
        'id': 's',
        'disabled': {'good': 1784368800, 'bad': '2026-07-18', '': 1},
      }).value! as SubscriptionServers;
      expect(s.disabledHashes.keys, ['good']);
    });
  });

  group('модель', () {
    test('§289 copyWith(clearIdentity) снимает слепок в null', () {
      final s = _richSubscription();
      expect(s.copyWith(name: 'Y').identity, isNotNull);
      expect(s.copyWith(clearIdentity: true).identity, isNull);
    });

    test('copyWith других полей сохраняет id, отметки и importRules', () {
      final s = _richSubscription();
      final updated = s.copyWith(name: 'renamed', lastNodeCount: 9);
      expect(updated.id, s.id);
      expect(updated.disabledHashes, s.disabledHashes);
      expect(updated.importRules, s.importRules);
    });

    test('равенство не видит кэш узлов подписки', () {
      final a = _richSubscription();
      final b = _richSubscription().copyWith(nodes: const []);
      a.nodes.addAll(sourceFromRecord({
        'kind': 'server',
        'id': 'x',
        'origin': {'kind': 'uri', 'raw': _uriAlpha},
      }).value!.nodes);
      expect(a.nodes, isNotEmpty);
      expect(a, b);
    });
  });

  group('§456 — wg_ini: тег записи применяется', () {
    test('одиночный сервер: тег записи становится именем узла', () {
      final notes = <String>[];
      final read = sourceFromRecord({
        'kind': 'server',
        'id': 's-ini',
        'tag': 'Proton CH',
        'enabled': true,
        'origin': {'kind': 'wg_ini', 'raw': _wgIni},
      }, notes: notes);
      final srv = read.value! as UserServer;
      expect(srv.nodes.single.tag, 'Proton CH');
      expect(srv.rawBody, _wgIni, reason: 'INI сохранён байт в байт');
      expect(notes, isEmpty, reason: 'у wg_ini расхождения нет — тег применён');
      expect(sourceToRecord(srv)['tag'], 'Proton CH');
    });

    test('член папки: тег записи переживает перечитывание через nameHint', () {
      final f = sourceFromRecord({
        'kind': 'folder',
        'id': 'f-ini',
        'nodes': [
          {
            'kind': 'server',
            'tag': 'Home WG',
            'enabled': true,
            'origin': {'kind': 'wg_ini', 'raw': _wgIni},
          },
        ],
      }).value! as FolderServers;
      expect(f.members.single.nameHint, 'Home WG');
      expect(f.members.single.node!.tag, 'Home WG');
    });
  });
}

String _wgTagOf(FolderServers f) => f.members.last.node!.tag;
