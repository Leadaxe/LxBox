// §503 — поиск узла листа страховки по идентичности вердикта.
import 'package:flutter_test/flutter_test.dart';
import 'package:lxbox/controllers/subscription_controller/core_reject_ops.dart';
import 'package:lxbox/models/core_reject_verdict.dart';
import 'package:lxbox/models/node_spec.dart';
import 'package:lxbox/models/server_list.dart';
import 'package:lxbox/services/core_reject/core_reject_guard.dart';
import 'package:lxbox/services/node_hash.dart';
import 'package:lxbox/services/parser/uri_parsers.dart';
import 'package:lxbox/services/tag_resolver.dart';

import '../parser/engine_test_setup.dart';

void main() {
  setUpAll(loadEngineSections);

  VlessSpec node({String tag = 'Frankfurt'}) => VlessSpec(
        id: tag,
        tag: tag,
        label: tag,
        server: 'example.com',
        port: 443,
        rawSource: '',
        uuid: '00000000-0000-0000-0000-000000000000',
        warnings: const [],
      );

  List<(int, String, ServerList)> entriesOf(ServerList list) => [(0, list.id, list)];

  group('resolveCoreRejectNode', () {
    test('по ref вердикта — одиночный сервер без карты сборки', () {
      final n = node(tag: 'bad-ss2022');
      final list = UserServer(
        id: 'srv-1',
        name: '',
        enabled: false,
        tagPrefix: '',
        detourPolicy: DetourPolicy.defaults,
        rawBody: '{}',
        warnings: [
          StoredWarning.coreRejected(
            'bad key length, required 32, got 5',
            ref: CoreRejectNodeRef(sourceId: 'srv-1', nodeKey: 'bad-ss2022'),
          ),
        ],
        nodes: [n],
      );
      const disabled = DisabledNode(
        tag: 'bad-ss2022',
        reason: 'bad key length, required 32, got 5',
        ref: CoreRejectNodeRef(sourceId: 'srv-1', nodeKey: 'bad-ss2022'),
      );

      final hit = resolveCoreRejectNode(entriesOf(list), disabled);
      expect(hit, isNotNull);
      expect(hit!.entryIndex, 0);
      expect(hit.memberIndex, isNull);
      expect(hit.source.tag, 'bad-ss2022');
      expect(hit.list, list);
    });

    test('по ref вердикта — узел подписки', () {
      final n = node();
      final id = sourceNodeIdentities([n])[n]!;
      final list = SubscriptionServers(
        id: 'sub-1',
        name: 'sub',
        enabled: true,
        tagPrefix: 'vpn-1',
        detourPolicy: DetourPolicy.defaults,
        url: 'https://example.com/sub',
        nodes: [n],
        disabledHashes: {id: DateTime.utc(2026, 9, 19)},
        nodeWarnings: {
          id: [
            StoredWarning.coreRejected(
              'parse encryption: bad',
              ref: CoreRejectNodeRef(sourceId: 'sub-1', nodeKey: id),
            ),
          ],
        },
      );
      final disabled = DisabledNode(
        tag: 'vpn-1 Frankfurt',
        reason: 'parse encryption: bad',
        ref: CoreRejectNodeRef(sourceId: 'sub-1', nodeKey: id),
      );

      final hit = resolveCoreRejectNode(entriesOf(list), disabled);
      expect(hit?.source.tag, 'Frankfurt');
    });

    test('по ref вердикта — член папки', () {
      final n = node(tag: 'member-1');
      final list = FolderServers(
        id: 'f-1',
        name: 'folder',
        enabled: true,
        tagPrefix: '',
        detourPolicy: DetourPolicy.defaults,
        createdAt: DateTime.utc(2026, 9, 19),
        members: [
          FolderMember(
            raw: 'uri',
            enabled: false,
            warnings: [
              StoredWarning.coreRejected(
                'bad key',
                ref: CoreRejectNodeRef(sourceId: 'f-1', nodeKey: 'member-1'),
              ),
            ],
            node: n,
          ),
        ],
      );
      const disabled = DisabledNode(
        tag: 'member-1',
        reason: 'bad key',
        ref: CoreRejectNodeRef(sourceId: 'f-1', nodeKey: 'member-1'),
      );

      final hit = resolveCoreRejectNode(entriesOf(list), disabled);
      expect(hit?.memberIndex, 0);
      expect(hit?.source.tag, 'member-1');
    });

    test('старый вердикт без ref — поиск по тегу среди выключенных', () {
      final n = node(tag: 'bad-ss2022');
      final list = UserServer(
        id: 'srv-1',
        name: '',
        enabled: false,
        tagPrefix: '',
        detourPolicy: DetourPolicy.defaults,
        rawBody: '{}',
        warnings: [
          StoredWarning.coreRejected('bad key length, required 32, got 5'),
        ],
        nodes: [n],
      );
      const disabled = DisabledNode(
        tag: 'bad-ss2022',
        reason: 'bad key length, required 32, got 5',
      );

      final hit = resolveCoreRejectNode(entriesOf(list), disabled);
      expect(hit?.source.tag, 'bad-ss2022');
    });

    test('старая подписка без ref — по emitted-тегу с префиксом', () {
      final n = node();
      final hash = sourceNodeIdentities([n])[n]!;
      final list = SubscriptionServers(
        id: 'sub-1',
        name: 'sub',
        enabled: true,
        tagPrefix: '🇩🇪',
        detourPolicy: DetourPolicy.defaults,
        url: 'https://example.com/sub',
        nodes: [n],
        disabledHashes: {hash: DateTime.utc(2026, 9, 19)},
        nodeWarnings: {
          hash: [StoredWarning.coreRejected('parse encryption: bad')],
        },
      );
      final emitted = TagResolver.displayTag('🇩🇪', n.tag);
      final disabled = DisabledNode(
        tag: emitted,
        reason: 'parse encryption: bad',
      );

      final hit = resolveCoreRejectNode(entriesOf(list), disabled);
      expect(hit?.source.tag, 'Frankfurt');
    });

    test('хоп цепочки — владелец по тегу хопа', () {
      final hop = node(tag: 'hop-link');
      final owner = withChained(node(tag: 'Main'), hop);
      final hash = sourceNodeIdentities([owner])[owner]!;
      final list = SubscriptionServers(
        id: 'sub-1',
        name: 'sub',
        enabled: true,
        tagPrefix: '',
        detourPolicy: DetourPolicy.defaults,
        url: 'https://example.com/sub',
        nodes: [owner],
        disabledHashes: {hash: DateTime.utc(2026, 9, 19)},
        nodeWarnings: {
          hash: [
            StoredWarning.coreRejected(
              'parse encryption: bad',
              ref: CoreRejectNodeRef(sourceId: 'sub-1', nodeKey: hash),
            ),
          ],
        },
      );
      final disabled = DisabledNode(
        tag: 'hop-link',
        reason: 'parse encryption: bad',
        ref: CoreRejectNodeRef(sourceId: 'sub-1', nodeKey: hash),
      );

      final hit = resolveCoreRejectNode(entriesOf(list), disabled);
      expect(hit?.source.tag, 'Main');
    });

    test('узел удалён — null', () {
      const disabled = DisabledNode(tag: 'gone', reason: 'bad');
      expect(resolveCoreRejectNode(const [], disabled), isNull);
    });
  });

  group('nodeRefFor', () {
    test('ручной сервер', () {
      final n = parseUri(
              'vless://11111111-1111-1111-1111-111111111111@h:443?type=ws&security=tls#S')!;
      final list = UserServer(
        id: 'u1',
        name: '',
        enabled: true,
        tagPrefix: '',
        detourPolicy: DetourPolicy.defaults,
        rawBody: 'uri',
        nodes: [n],
      );
      expect(
        nodeRefFor(list, n),
        CoreRejectNodeRef(sourceId: 'u1', nodeKey: 'S'),
      );
    });
  });
}
