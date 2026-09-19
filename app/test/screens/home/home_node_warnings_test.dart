import 'package:flutter_test/flutter_test.dart';
import 'package:lxbox/controllers/subscription_controller.dart';
import 'package:lxbox/models/config_node.dart';
import 'package:lxbox/models/core_reject_verdict.dart';
import 'package:lxbox/models/node_spec.dart';
import 'package:lxbox/models/node_warning.dart';
import 'package:lxbox/models/server_list.dart';
import 'package:lxbox/screens/home/node_list_presenter.dart';
import 'package:lxbox/screens/subscriptions_screen/entry_warnings.dart';
import 'package:lxbox/services/node_hash.dart';
import 'package:lxbox/services/parser/uri_parsers.dart';

import '../../parser/engine_test_setup.dart';

/// §502 — уведомления узла на главном экране: старший уровень и источники.
void main() {
  setUpAll(loadEngineSections);
  tearDownAll(unloadEngineSections);

  ShadowsocksSpec ssNode({String tag = 'MySS'}) {
    final n = parseUri(
        'ss://YWVzLTI1Ni1nY206dGVzdA==@example.com:8388#$tag')! as ShadowsocksSpec;
    return n;
  }

  const infoOnly = RegistryWarning(
    code: 'tls_insecure',
    path: 'tls.insecure',
    value: 'true',
  );
  const warn = RegistryWarning(
    code: 'transport_unsupported',
    path: 'transport.type',
    params: {'transport': 'quic', 'fallback': 'ws'},
  );

  group('topWarningSeverity', () {
    test('info / warning / error / пусто', () {
      expect(topWarningSeverity(const []), isNull);
      expect(topWarningSeverity(const [infoOnly]), WarningSeverity.info);
      expect(topWarningSeverity(const [infoOnly, warn]), WarningSeverity.warning);
      expect(
        topWarningSeverity([
          infoOnly,
          warn,
          StoredWarning.coreRejected('bad key').toWarning(),
        ]),
        WarningSeverity.error,
      );
    });
  });

  group('warningsForEmittedNode', () {
    test('подписка: разбор + core_rejected из хранилища', () {
      final node = ssNode();
      node.warnings.add(warn);
      final id = sourceNodeIdentities([node])[node]!;
      final entries = [
        SubscriptionEntry(
          list: SubscriptionServers(
            id: 'sub1',
            name: 'sub',
            enabled: true,
            tagPrefix: 'p',
            detourPolicy: DetourPolicy.defaults,
            url: 'https://example.com/sub',
            nodes: [node],
            nodeWarnings: {
              id: [StoredWarning.coreRejected('bad key length')],
            },
          ),
          nodeCount: 1,
        ),
      ];

      final ws = warningsForEmittedNode(node, entries);
      expect(ws.any((w) => w.severity == WarningSeverity.error), isTrue);
      expect(ws.any((w) => w.severity == WarningSeverity.warning), isTrue);
      expect(topWarningSeverity(ws), WarningSeverity.error);
    });

    test('одиночный сервер: warnings на записи', () {
      final node = ssNode();
      final entries = [
        SubscriptionEntry(
          list: UserServer(
            id: 'u1',
            name: '',
            enabled: false,
            tagPrefix: '',
            detourPolicy: DetourPolicy.defaults,
            rawBody: 'ss://YWVzLTI1Ni1nY206dGVzdA==@example.com:8388#MySS',
            warnings: [StoredWarning.coreRejected('kernel said no')],
            nodes: [node],
          ),
          nodeCount: 1,
        ),
      ];

      final ws = warningsForEmittedNode(node, entries);
      expect(topWarningSeverity(ws), WarningSeverity.error);
    });
  });

  group('NodeListData.topWarningSeverityOf', () {
    test('presenter отдаёт старший уровень по тегу', () {
      final data = NodeListData(
        cache: const ParsedConfig.empty(),
        matchingSet: {},
        displayList: [],
        emojis: [],
        availableProtocols: [],
        availableVariants: [],
        sourceOptions: [],
        warningsByTag: {
          'a': [infoOnly],
          'b': [warn],
          'c': <NodeWarning>[],
        },
      );

      expect(data.topWarningSeverityOf('a'), WarningSeverity.info);
      expect(data.topWarningSeverityOf('b'), WarningSeverity.warning);
      expect(data.topWarningSeverityOf('c'), isNull);
      expect(data.topWarningSeverityOf('missing'), isNull);
    });
  });
}
