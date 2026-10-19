import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lxbox/models/node_spec.dart';
import 'package:lxbox/services/tailscale_network.dart' show TailscalePathKind;
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

/// §645 — опрос `getStatus`: счётчик вызовов, ответ [reply] / [result],
/// [hold] — вызов не возвращается, пока его не завершат.
class _PollActions extends TailscaleNetworkActions {
  int calls = 0;
  CcTailscaleStatus? reply;
  CcTailscaleStatusPoll? result;
  Completer<CcTailscaleStatusPoll>? hold;

  @override
  Future<CcTailscaleStatusPoll> getStatus(String tag) async {
    calls++;
    final h = hold;
    if (h != null) return h.future;
    final r = reply;
    if (r != null) return CcTailscaleStatusPoll(status: r);
    return result ?? CcTailscaleStatusPoll.skip;
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
    Future<void> Function(Map<String, Object?>)? onSaveFields,
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
          onSaveFields: onSaveFields,
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
    bool has(String name, String text) => find
        .descendant(
          of: find.widgetWithText(ListTile, name).last,
          matching: find.textContaining(text),
        )
        .evaluate()
        .isNotEmpty;
    expect(has('nas', 'key expired'), isTrue);
    expect(has('nas', 'online'), isFalse);
    expect(has('gw', 'exit node'), isTrue);
    expect(has('gw', '100.64.0.2'), isTrue);
    expect(has('gw', 'gw.tail.ts.net'), isFalse);
    expect(has('shared-box', 'shared'), isTrue);
    expect(has('zeta', 'last seen'), isTrue);
    // Заголовок: в сети 2 из 4.
    expect(find.textContaining('2 online / 4'), findsOneWidget);
    // Один владелец — без заголовков групп.
    expect(find.text('Alice'), findsNothing);
  });

  group('§645 — адреса и путь', () {
    const multi = CcTailscalePeer(
      stableId: 'm1',
      hostName: 'router',
      dnsName: 'router.tail.ts.net.',
      online: true,
      path: 'direct',
      endpoint: '198.51.100.7:41641',
      ips: ['100.64.0.9', 'fd7a::9', '10.0.0.9'],
    );
    CcTailscaleStatus st() => const CcTailscaleStatus(
          tag: 'ts',
          backendState: 'Running',
          stateText: '',
          self: CcTailscalePeer(
              hostName: 'phone', ips: ['100.64.0.1', 'fd7a::1']),
          userGroups: [
            CcTailscaleUserGroup(peers: [multi]),
          ],
        );

    testWidgets('This device: один заголовок Address, адреса столбиком',
        (tester) async {
      await pump(tester, data: [st()]);
      expect(find.text('Address'), findsOneWidget);
      expect(find.text('100.64.0.1'), findsOneWidget);
      expect(find.text('fd7a::1'), findsOneWidget);
    });

    testWidgets('+N раскрывает и сворачивает адреса сверх двух',
        (tester) async {
      await tester.binding.setSurfaceSize(const Size(800, 2400));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      await pump(tester, data: [st()]);
      expect(find.text('fd7a::9'), findsOneWidget);
      expect(find.text('+1'), findsOneWidget);
      expect(find.text('10.0.0.9'), findsNothing);
      expect(find.byIcon(Icons.bolt), findsOneWidget);
      final more = find.byKey(const ValueKey('tailscale-more-m1'));
      await tester.tap(more);
      await tester.pump();
      expect(find.text('10.0.0.9'), findsOneWidget);
      expect(find.byIcon(Icons.expand_less), findsOneWidget);
      // Меню строки при раскрытии не открылось.
      expect(find.text('Ping'), findsNothing);
      await tester.tap(more);
      await tester.pump();
      expect(find.text('10.0.0.9'), findsNothing);
    });

    testWidgets('меню: MagicDNS-имя и пункт на каждый адрес',
        (tester) async {
      await tester.binding.setSurfaceSize(const Size(800, 2400));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      await pump(tester, data: [st()]);
      await tester.tap(find.widgetWithText(ListTile, 'router').last);
      await tester.pumpAndSettle();
      expect(find.text('Copy name'), findsOneWidget);
      expect(find.text('Copy MagicDNS name'), findsOneWidget);
      expect(find.text('Copy address'), findsNothing);
      for (final ip in multi.ips) {
        expect(find.text('Copy $ip'), findsOneWidget);
      }
      expect(find.text('Ping'), findsOneWidget);
    });

    test('иконка пути: напрямую зелёная, посредники оранжевые, нет — нет', () {
      expect(tailscalePathIcon(TailscalePathKind.direct),
          (icon: Icons.bolt, color: Colors.green));
      expect(tailscalePathIcon(TailscalePathKind.derp),
          (icon: Icons.cloud_outlined, color: Colors.orange));
      expect(tailscalePathIcon(TailscalePathKind.peerRelay),
          (icon: Icons.device_hub, color: Colors.orange));
      expect(tailscalePathIcon(null), isNull);
    });
  });

  group('§645 — опрос статуса', () {
    Future<void> pumpPoll(
      WidgetTester tester,
      _PollActions actions, {
      bool vpnUp = true,
      StreamController<List<CcTailscaleStatus>>? ctrl,
    }) async {
      final c = ctrl ?? StreamController<List<CcTailscaleStatus>>();
      addTearDown(c.close);
      await tester.pumpWidget(MaterialApp(
        home: Scaffold(
          body: TailscaleNetworkTab(
            key: const ValueKey('tab'),
            liveTag: 'ts',
            body: const {},
            statusSource: c.stream,
            vpnUp: vpnUp,
            actions: actions,
          ),
        ),
      ));
      await tester.pump();
    }

    testWidgets('первый вызов сразу, ответ строит вкладку, дальше раз в 3 с',
        (tester) async {
      final a = _PollActions()..reply = _status();
      await pumpPoll(tester, a);
      expect(a.calls, 1);
      expect(find.text('This device'), findsOneWidget);
      await tester.pump(const Duration(seconds: 3));
      expect(a.calls, 2);
      await tester.pump(const Duration(seconds: 3));
      expect(a.calls, 3);
    });

    testWidgets('VPN выключен — опроса нет', (tester) async {
      final a = _PollActions();
      await pumpPoll(tester, a, vpnUp: false);
      await tester.pump(const Duration(seconds: 7));
      expect(a.calls, 0);
    });

    testWidgets('вкладка ушла с экрана — опрос стоит, вернулась — сразу',
        (tester) async {
      // С данными: без них крутится индикатор и переход не «оседает».
      final a = _PollActions()..reply = _status();
      await pumpPoll(tester, a);
      expect(a.calls, 1);
      final ctx = tester.element(find.byKey(const ValueKey('tab')));
      unawaited(Navigator.of(ctx).push(MaterialPageRoute<void>(
        builder: (_) => const Scaffold(body: Text('over')),
      )));
      await tester.pumpAndSettle();
      final before = a.calls;
      await tester.pump(const Duration(seconds: 7));
      expect(a.calls, before);
      Navigator.of(tester.element(find.text('over'))).pop();
      await tester.pumpAndSettle();
      expect(a.calls, before + 1);
    });

    testWidgets('вкладка закрыта — таймер снят', (tester) async {
      final a = _PollActions();
      await pumpPoll(tester, a);
      await tester.pumpWidget(const MaterialApp(home: SizedBox()));
      await tester.pump(const Duration(seconds: 7));
      expect(a.calls, 1);
    });

    testWidgets('ядро без метода — опрос остановлен, поток работает',
        (tester) async {
      final a = _PollActions()..result = CcTailscaleStatusPoll.notSupported;
      final ctrl = StreamController<List<CcTailscaleStatus>>();
      await pumpPoll(tester, a, ctrl: ctrl);
      await tester.pump(const Duration(seconds: 7));
      expect(a.calls, 1);
      ctrl.add([_status()]);
      await tester.pump();
      expect(find.text('This device'), findsOneWidget);
    });

    testWidgets('вызов не вернулся — тик пропускается', (tester) async {
      final a = _PollActions()..hold = Completer<CcTailscaleStatusPoll>();
      await pumpPoll(tester, a);
      await tester.pump(const Duration(seconds: 7));
      expect(a.calls, 1);
      a.hold!.complete(CcTailscaleStatusPoll.skip);
      a.hold = null;
      await tester.pump();
      await tester.pump(const Duration(seconds: 3));
      expect(a.calls, 2);
    });

    testWidgets('на экране — пришедшая последней запись', (tester) async {
      final a = _PollActions()..result = CcTailscaleStatusPoll.skip;
      final ctrl = StreamController<List<CcTailscaleStatus>>();
      await pumpPoll(tester, a, ctrl: ctrl);
      ctrl.add(const [
        CcTailscaleStatus(
            tag: 'ts', backendState: 'NeedsLogin', stateText: ''),
      ]);
      await tester.pump();
      expect(find.text('sign-in needed'), findsOneWidget);
      a.reply = _status();
      await tester.pump(const Duration(seconds: 3));
      await tester.pump(const Duration(seconds: 1));
      expect(find.text('running'), findsOneWidget);
    });
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
    SwitchListTile tile(WidgetTester tester, String key) =>
        tester.widget<SwitchListTile>(find.byKey(ValueKey(key)));

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

    testWidgets('выход есть и в Devices, из его строки доступен пинг',
        (tester) async {
      await tester.binding.setSurfaceSize(const Size(800, 2400));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      await pump(tester, data: [_status(exit: _gw)]);
      expect(find.widgetWithText(RadioListTile<String>, 'gw'), findsOneWidget);
      // Пункт Exit node (RadioListTile строится на ListTile) и строка Devices.
      final rows = find.widgetWithText(ListTile, 'gw');
      expect(rows, findsNWidgets(2));
      await tester.tap(rows.last);
      await tester.pumpAndSettle();
      expect(find.text('Ping'), findsOneWidget);
    });

    testWidgets('Settings без выхода: advertise пишется, LAN-переключателя нет',
        (tester) async {
      await tester.binding.setSurfaceSize(const Size(800, 2400));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      final saved = <Map<String, Object?>>[];
      await pump(tester,
          data: [_status()], onSaveFields: (f) async => saved.add(f));
      expect(find.byKey(const ValueKey('tailscale-exit-lan')), findsNothing);
      await tester.tap(find.byKey(const ValueKey('tailscale-advertise-exit')));
      await tester.pump();
      expect(saved, [
        {'advertise_exit_node': true},
      ]);
    });

    testWidgets('Settings с записанным выходом: advertise заблокирован',
        (tester) async {
      await tester.binding.setSurfaceSize(const Size(800, 2400));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      await pump(tester,
          data: [_status()],
          body: const {'exit_node': 'gw'},
          onSaveFields: (f) async {});
      expect(tile(tester, 'tailscale-advertise-exit').onChanged, isNull);
      expect(find.byKey(const ValueKey('tailscale-exit-lan')), findsNothing);
    });

    testWidgets('узел подписки — блока Settings нет', (tester) async {
      await pump(tester, data: [_status()]);
      expect(
          find.byKey(const ValueKey('tailscale-advertise-exit')), findsNothing);
    });
  });
}
