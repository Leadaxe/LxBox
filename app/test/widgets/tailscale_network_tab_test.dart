import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lxbox/models/node_spec.dart';
import 'package:lxbox/vpn/cc_channel.dart';
import 'package:lxbox/widgets/node_diagnostics_tab.dart';
import 'package:lxbox/widgets/tailscale_network_tab.dart';

/// Задача 581 — вкладка Network (состояния без данных, блок Exit node,
/// устройства) и правка вкладки Diagnostics.
class _FakeActions extends TailscaleNetworkActions {
  final chosen = <String>[];

  @override
  Future<String?> setExitNode(String tag, String stableId) async {
    chosen.add(stableId);
    return null;
  }
}

const _gw = CcTailscalePeer(
  stableId: 'n2',
  hostName: 'gw',
  dnsName: 'gw.tail.ts.net.',
  online: true,
  exitNodeOption: true,
  ips: ['100.64.0.2'],
);

CcTailscaleStatus _status({CcTailscalePeer? exit}) => CcTailscaleStatus(
      tag: 'ts',
      backendState: 'Running',
      stateText: '',
      self: const CcTailscalePeer(hostName: 'phone', ips: ['100.64.0.1']),
      exitNode: exit,
      userGroups: const [
        CcTailscaleUserGroup(displayName: 'Alice', peers: [
          CcTailscalePeer(
              hostName: 'zeta', online: false, lastSeen: 1700000000),
          CcTailscalePeer(hostName: 'nas', online: true, expired: true),
          _gw,
          CcTailscalePeer(hostName: 'shared-box', shareeNode: true),
        ]),
      ],
    );

void main() {
  Future<void> pump(
    WidgetTester tester, {
    bool vpnUp = true,
    List<CcTailscaleStatus>? data,
    Map<String, dynamic> body = const {},
    Future<void> Function(String?)? onSave,
    TailscaleNetworkActions actions = const TailscaleNetworkActions(),
  }) async {
    final ctrl = StreamController<List<CcTailscaleStatus>>();
    addTearDown(ctrl.close);
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: TailscaleNetworkTab(
          liveTag: 'ts',
          body: body,
          onSaveExitNode: onSave,
          statusSource: ctrl.stream,
          vpnUp: vpnUp,
          actions: actions,
        ),
      ),
    ));
    if (data != null) ctrl.add(data);
    await tester.pump();
  }

  group('без данных', () {
    testWidgets('VPN выключен', (tester) async {
      await pump(tester, vpnUp: false);
      expect(find.text('Start VPN to see the network.'), findsOneWidget);
    });

    testWidgets('данных от ядра ещё нет — ожидание', (tester) async {
      await pump(tester);
      expect(find.byType(CircularProgressIndicator), findsOneWidget);
    });

    testWidgets('узла нет в работающем конфиге', (tester) async {
      await pump(tester, data: const [
        CcTailscaleStatus(tag: 'other', backendState: 'Running', stateText: ''),
      ]);
      expect(find.text('The node is not in the running config.'),
          findsOneWidget);
    });
  });

  group('Exit node', () {
    final warn = find.byKey(const ValueKey('exit-node-warning'));
    final save = find.text('Save choice');

    testWidgets('совпадают — знака и кнопки нет', (tester) async {
      await pump(tester,
          data: [_status(exit: _gw)],
          body: const {'exit_node': '100.64.0.2'},
          onSave: (_) async {});
      expect(warn, findsNothing);
      expect(save, findsNothing);
    });

    testWidgets('различаются — знак и Save choice, запись адреса',
        (tester) async {
      String? saved = 'untouched';
      await pump(tester,
          data: [_status(exit: _gw)], onSave: (v) async => saved = v);
      expect(warn, findsOneWidget);
      expect(
          find.text(
              'Not saved. Traffic is not routed through this node until you save the choice.'),
          findsOneWidget);
      await tester.ensureVisible(save);
      await tester.tap(save);
      await tester.pump();
      expect(saved, '100.64.0.2');
    });

    testWidgets('снят на ходу — Save choice пишет пусто', (tester) async {
      String? saved = 'untouched';
      await pump(tester,
          data: [_status()],
          body: const {'exit_node': 'gw'},
          onSave: (v) async => saved = v);
      await tester.ensureVisible(save);
      await tester.tap(save);
      await tester.pump();
      expect(saved, isNull);
    });

    testWidgets('узел подписки — знак есть, Save choice нет', (tester) async {
      await pump(tester, data: [_status(exit: _gw)]);
      expect(warn, findsOneWidget);
      expect(save, findsNothing);
    });

    testWidgets('выбор пункта переключает на ходу, тело не трогает',
        (tester) async {
      final actions = _FakeActions();
      var saves = 0;
      await pump(tester,
          data: [_status()], actions: actions, onSave: (_) async => saves++);
      await tester.tap(find.widgetWithText(RadioListTile<String>, 'gw'));
      await tester.pump();
      expect(actions.chosen, ['n2']);
      expect(saves, 0);
    });
  });

  testWidgets('устройства: порядок и отметки', (tester) async {
    await tester.binding.setSurfaceSize(const Size(800, 2400));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await pump(tester, data: [_status()]);
    final names = ['gw', 'nas', 'shared-box', 'zeta'];
    final ys = [
      for (final n in names)
        tester.getTopLeft(find.widgetWithText(ListTile, n).last).dy,
    ];
    expect(ys, [...ys]..sort());
    String sub(String name) => (tester
            .widget<ListTile>(find.widgetWithText(ListTile, name).last)
            .subtitle as Text)
        .data!;
    expect(sub('nas'), contains('key expired'));
    expect(sub('nas'), contains('online'));
    expect(sub('gw'), contains('exit node'));
    expect(sub('shared-box'), contains('shared'));
    expect(sub('zeta'), contains('last seen'));
    // Один владелец — без заголовков групп.
    expect(find.text('Alice'), findsNothing);
  });

  group('Diagnostics у узла Tailscale', () {
    Future<void> pumpDiag(WidgetTester tester, CcTailscaleStatus s) async {
      final ctrl = StreamController<List<CcTailscaleStatus>>();
      addTearDown(ctrl.close);
      await tester.pumpWidget(MaterialApp(
        home: Scaffold(
          body: NodeDiagnosticsTab(
            liveTag: 'ts',
            node: TailscaleSpec(id: '1', tag: 'ts', label: 'ts'),
            tailscaleStatusSource: ctrl.stream,
            vpnUp: true,
          ),
        ),
      ));
      ctrl.add([s]);
      await tester.pump();
    }

    testWidgets('выхода нет — проверка скрыта, строка вместо неё',
        (tester) async {
      await pumpDiag(tester, _status());
      expect(find.byKey(const ValueKey('tailscale-no-exit')), findsOneWidget);
      expect(find.text('Check'), findsNothing);
    });

    testWidgets('выход есть — проверка доступна', (tester) async {
      await pumpDiag(tester, _status(exit: _gw));
      expect(find.byKey(const ValueKey('tailscale-no-exit')), findsNothing);
      expect(find.text('Check'), findsOneWidget);
    });
  });

  group('§613', () {
    final health = find.byKey(const ValueKey('tailscale-health'));

    testWidgets('health пуст — блока нет', (tester) async {
      await pump(tester, data: [_status()]);
      expect(health, findsNothing);
    });

    testWidgets('health — блок вверху, по строке на запись', (tester) async {
      await pump(tester, data: const [
        CcTailscaleStatus(
          tag: 'ts',
          backendState: 'Running',
          stateText: '',
          health: ['no home relay'],
        ),
      ]);
      expect(health, findsOneWidget);
      expect(find.text('no home relay'), findsOneWidget);
    });

    testWidgets('выход не дублируется в Devices', (tester) async {
      await tester.binding.setSurfaceSize(const Size(800, 2400));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      await pump(tester, data: [_status(exit: _gw)]);
      expect(find.widgetWithText(RadioListTile<String>, 'gw'), findsOneWidget);
      // Единственная плитка с именем — пункт Exit node (RadioListTile
      // строится на ListTile); в Devices строки нет.
      expect(find.widgetWithText(ListTile, 'gw'), findsOneWidget);
    });
  });
}
