import 'package:flutter_test/flutter_test.dart';
import 'package:lxbox/controllers/home_controller.dart';
import 'package:lxbox/controllers/subscription_controller.dart';
import 'package:lxbox/models/core_reject_verdict.dart';
import 'package:lxbox/models/home_state.dart';
import 'package:lxbox/models/node_spec.dart';
import 'package:lxbox/models/node_warning.dart';
import 'package:lxbox/models/server_list.dart';
import 'package:lxbox/screens/home/node_filter_view_model.dart';
import 'package:lxbox/screens/home/node_list_presenter.dart';
import 'package:lxbox/screens/home/source_lookup.dart';
import 'package:lxbox/screens/subscriptions_screen/entry_warnings.dart';
import 'package:lxbox/services/node_hash.dart';
import 'package:lxbox/services/parser/uri_parsers.dart';

import '../../parser/engine_test_setup.dart';

/// §502/§505 — уведомления узла на главном экране: старший уровень и источники.
void main() {
  setUpAll(loadEngineSections);
  tearDownAll(unloadEngineSections);

  const testPriv = 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaA=';
  const testPub = 'bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbA=';

  ShadowsocksSpec ssNode({String tag = 'MySS'}) {
    final n = parseUri(
        'ss://YWVzLTI1Ni1nY206dGVzdA==@example.com:8388#$tag')! as ShadowsocksSpec;
    return n;
  }

  WireguardSpec awgHomeNode() {
    final spec = parseWireguardUri(
          'wireguard://$testPriv@h.example:51820'
          '?publickey=$testPub&address=10.0.0.2/32&jc=4&mtu=1420#awg2-home',
        )!;
    expect(
      spec.warnings.whereType<RegistryWarning>().map((w) => w.code),
      contains('awg_mtu_clamped'),
      reason: 'sanitizer должен поставить warning до сборки',
    );
    return spec;
  }

  SubscriptionEntry userServerEntry(WireguardSpec node) => SubscriptionEntry(
        list: UserServer(
          id: 'u1',
          name: 'home',
          enabled: true,
          tagPrefix: '🏠',
          detourPolicy: DetourPolicy.defaults,
          rawBody: node.rawSource,
          origin: UserSource.manual,
          nodes: [node],
        ),
        nodeCount: 1,
      );

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

  // §513 — отдельный `nodeSpecForConfigTag` снят: в lib/ его никто не звал,
  // главный экран ищет узел через `storedNodeOfEmittedTag` (§505). Кейс
  // «префикс записи → bare-тег» проверяется на реальном пути.
  group('storedNodeOfEmittedTag', () {
    test('одиночный сервер с префиксом — bare-тег', () {
      final node = awgHomeNode();
      final entries = [userServerEntry(node)];
      final found = storedNodeOfEmittedTag('🏠 awg2-home', entries);
      expect(found, isNotNull);
      expect(identical(found!.node, node), isTrue);
      expect(found.stored, isEmpty);
    });
  });

  group('warningsForConfigTag', () {
    test('холодный старт: AWG одиночный сервер — warning без BuildResult', () {
      final node = awgHomeNode();
      final entries = [userServerEntry(node)];

      final ws = warningsForConfigTag(
        '🏠 awg2-home',
        entries,
        emittedTagMap: const {},
      );
      expect(topWarningSeverity(ws), WarningSeverity.warning);
      expect(
        ws.whereType<RegistryWarning>().any((w) => w.code == 'awg_mtu_clamped'),
        isTrue,
      );
    });

    test('подписка: info без карты сборки', () {
      final node = ssNode(tag: 'p-node');
      node.warnings.add(infoOnly);
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
          ),
          nodeCount: 1,
        ),
      ];

      final ws = warningsForConfigTag('p p-node', entries);
      expect(topWarningSeverity(ws), WarningSeverity.info);
    });

    test('вердикт страховки — error', () {
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

      final ws = warningsForConfigTag('MySS', entries);
      expect(topWarningSeverity(ws), WarningSeverity.error);
    });

    test('устаревшая карта сборки не перебивает хранилище', () {
      final stored = awgHomeNode();
      final stale = ssNode(tag: 'other');
      final entries = [userServerEntry(stored)];

      final ws = warningsForConfigTag(
        '🏠 awg2-home',
        entries,
        emittedTagMap: {'🏠 awg2-home': stale},
      );
      expect(topWarningSeverity(ws), WarningSeverity.warning);
      expect(
        ws.whereType<RegistryWarning>().any((w) => w.code == 'awg_mtu_clamped'),
        isTrue,
      );
    });

    test('предупреждение сборки по тегу', () {
      final node = awgHomeNode();
      final entries = [userServerEntry(node)];
      const buildWarn = RegistryWarning(
        code: 'awg_mtu_clamped',
        path: 'mtu',
        value: '1420',
      );

      final ws = warningsForConfigTag(
        '🏠 awg2-home',
        entries,
        buildWarningsByTag: {
          '🏠 awg2-home': [buildWarn],
        },
      );
      expect(topWarningSeverity(ws), WarningSeverity.warning);
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

  group('NodeListPresenter §505', () {
    test('computeListData без карты сборки — warning по тегу AWG', () {
      final node = awgHomeNode();
      final subController = SubscriptionController();
      subController.debugSetLastEmittedTagMap(const {});
      subController.debugSetEntries([userServerEntry(node)]);

      final filter = NodeFilterViewModel();
      final presenter = NodeListPresenter(
        controller: HomeController(),
        subController: subController,
        filter: filter,
      );
      final state = HomeState(
        configRaw: '{}',
        nodes: const ['🏠 awg2-home'],
      );

      final data = presenter.computeListData(state);
      expect(
        data.topWarningSeverityOf('🏠 awg2-home'),
        WarningSeverity.warning,
      );

      filter.dispose();
    });

    test('устаревшая карта сборки — warning из хранилища', () {
      final node = awgHomeNode();
      final stale = ssNode(tag: 'stale');
      final subController = SubscriptionController();
      subController.debugSetEntries([userServerEntry(node)]);
      subController.debugSetLastEmittedTagMap({'🏠 awg2-home': stale});

      final filter = NodeFilterViewModel();
      final presenter = NodeListPresenter(
        controller: HomeController(),
        subController: subController,
        filter: filter,
      );
      final state = HomeState(
        configRaw: '{}',
        nodes: const ['🏠 awg2-home'],
      );

      expect(
        presenter.computeListData(state).topWarningSeverityOf('🏠 awg2-home'),
        WarningSeverity.warning,
      );

      filter.dispose();
    });

    // §511 M3 — тик статистики даёт новый HomeState с теми же узлами: уровни
    // не пересчитываются; смена записей или карты сборки — пересчёт.
    test('уведомления кэшируются по входам, тик статистики их не считает',
        () {
      final node = awgHomeNode();
      final subController = SubscriptionController();
      subController.debugSetLastEmittedTagMap(const {});
      subController.debugSetEntries([userServerEntry(node)]);

      final filter = NodeFilterViewModel();
      final presenter = NodeListPresenter(
        controller: HomeController(),
        subController: subController,
        filter: filter,
      );
      final state = HomeState(
        configRaw: '{}',
        nodes: const ['🏠 awg2-home'],
      );

      presenter.computeListData(state);
      final tick = presenter.computeListData(state.copyWith());
      expect(presenter.debugWarningsPasses, 1);
      expect(tick.topWarningSeverityOf('🏠 awg2-home'), WarningSeverity.warning);

      subController.debugSetEntries([userServerEntry(node)]);
      presenter.computeListData(state.copyWith());
      expect(presenter.debugWarningsPasses, 2, reason: 'сменились записи');

      subController.debugSetLastEmittedTagMap(const <String, NodeSpec>{});
      presenter.computeListData(state.copyWith());
      expect(presenter.debugWarningsPasses, 2,
          reason: 'та же константная карта — тот же объект');
      subController.debugSetLastEmittedTagMap({'x': ssNode()});
      presenter.computeListData(state.copyWith());
      expect(presenter.debugWarningsPasses, 3, reason: 'новая карта сборки');

      filter.dispose();
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
