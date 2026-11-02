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
  final applied = <String>[];
  TailscaleKeyApply apply = TailscaleKeyApply.signingIn;

  /// §706 — состояние узла в ядре и журнал выключателя.
  final changes = ValueNotifier<int>(0);
  final states = <String, String>{};
  final toggles = <bool>[];
  final toggleCodes = <String?>[];
  Completer<void>? toggleHold;

  @override
  Future<String?> setExitNode(String tag, String stableId) async {
    chosen.add(stableId);
    return null;
  }

  @override
  Future<TailscaleKeyApply> applyNewKey(String tag, String authKey) async {
    applied.add('$tag:$authKey');
    return apply;
  }

  @override
  Listenable get endpointChanges => changes;

  @override
  String? endpointState(String tag) => states[tag];

  @override
  Future<String?> setEndpointEnabled(String tag, bool enabled) async {
    toggles.add(enabled);
    await toggleHold?.future;
    final code = toggleCodes.isEmpty ? null : toggleCodes.removeAt(0);
    if (code == null) {
      states[tag] = enabled ? CcEndpointState.up : CcEndpointState.disabled;
      changes.value++;
    }
    return code;
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


/// §707 — действия Taildrop: журнал вызовов, ответы по умолчанию — успех.
class _DropActions extends TailscaleNetworkActions {
  final calls = <String>[];
  CcTaildropResult saveResult =
      const CcTaildropResult(status: 'saved', where: 'downloads');
  CcTaildropResult sendResult = const CcTaildropResult(status: 'started');

  @override
  Future<void> startInbox(String tag) async => calls.add('start:$tag');

  @override
  Future<void> stopInbox() async => calls.add('stop');

  @override
  Future<String?> markInboxRead(String tag) async {
    calls.add('read:$tag');
    return null;
  }

  @override
  Future<CcTaildropResult> saveFile(String tag, String name) async {
    calls.add('save:$name');
    return saveResult;
  }

  @override
  Future<String?> deleteFile(String tag, String name) async {
    calls.add('delete:$name');
    return null;
  }

  @override
  Future<String?> cancelReceiving(
      String tag, String senderId, String name) async {
    calls.add('cancel:$senderId/$name');
    return null;
  }

  @override
  Future<CcTaildropResult> sendFiles(String tag, CcTailscalePeer peer) async {
    calls.add('send:${peer.stableId}');
    return sendResult;
  }
}

const _laptop = CcTailscalePeer(
  stableId: 'n5',
  hostName: 'laptop',
  online: true,
  canReceiveFiles: true,
  ips: ['100.64.0.5'],
);

CcTailscaleStatus _dropStatus({bool canShare = true}) => CcTailscaleStatus(
      tag: 'ts',
      backendState: 'Running',
      stateText: '',
      canShareFiles: canShare,
      userGroups: const [
        CcTailscaleUserGroup(displayName: 'Alice', peers: [
          _laptop,
          // В сети, но не принимает файлы; расшаренный; не в сети.
          CcTailscalePeer(stableId: 'n6', hostName: 'tv', online: true),
          CcTailscalePeer(
              stableId: 'n7',
              hostName: 'guest',
              online: true,
              canReceiveFiles: true,
              shareeNode: true),
          CcTailscalePeer(
              stableId: 'n8', hostName: 'desk', canReceiveFiles: true),
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
    Future<bool> Function(Map<String, Object?>)? onSaveFields,
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
          data: [_status()],
          onSaveFields: (f) async {
            saved.add(f);
            return true;
          });
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
          onSaveFields: (f) async => true);
      expect(tile(tester, 'tailscale-advertise-exit').onChanged, isNull);
      expect(find.byKey(const ValueKey('tailscale-exit-lan')), findsNothing);
    });

    testWidgets('узел подписки — блока Settings нет', (tester) async {
      await pump(tester, data: [_status()]);
      expect(
          find.byKey(const ValueKey('tailscale-advertise-exit')), findsNothing);
    });
  });

  group('§706 — узел вне сети', () {
    const offline = CcTailscaleStatus(
      tag: 'ts',
      backendState: 'NeedsLogin',
      stateText: '',
      keyAuth: true,
      self: CcTailscalePeer(hostName: 'localhost'),
      health: [
        'You are logged out. The last login error was: invalid key: API key does not exist',
      ],
    );
    final replace = find.byKey(const ValueKey('tailscale-replace-key'));
    final saveKey = find.byKey(const ValueKey('tailscale-replace-key-save'));

    Future<void> big(WidgetTester tester) async {
      await tester.binding.setSurfaceSize(const Size(800, 2400));
      addTearDown(() => tester.binding.setSurfaceSize(null));
    }

    testWidgets('записанный exit node — строкой, без выбора и Save choice',
        (tester) async {
      await big(tester);
      await pump(tester,
          data: const [offline],
          body: const {'exit_node': 'gw'},
          onSave: (_) async {},
          onSaveFields: (_) async => true);
      expect(find.byType(RadioListTile<String>), findsNothing);
      expect(find.text('Save choice'), findsNothing);
      expect(find.byKey(const ValueKey('exit-node-warning')), findsNothing);
      expect(find.byKey(const ValueKey('tailscale-saved-exit-node')),
          findsOneWidget);
      expect(find.text('Saved: gw'), findsOneWidget);
    });

    testWidgets('exit node не записан — блока нет', (tester) async {
      await big(tester);
      await pump(tester, data: const [offline]);
      expect(find.text('Exit node'), findsNothing);
      expect(find.byType(RadioListTile<String>), findsNothing);
    });

    testWidgets('чипа «signed in with a key» нет, имя — прочерк',
        (tester) async {
      await big(tester);
      await pump(tester, data: const [offline]);
      expect(find.text('signed in with a key'), findsNothing);
      expect(find.text('localhost'), findsNothing);
      expect(find.text('—'), findsOneWidget);
    });

    testWidgets('редактируемый узел — Replace key есть', (tester) async {
      await big(tester);
      await pump(tester,
          data: const [offline], onSaveFields: (_) async => true);
      expect(replace, findsOneWidget);
    });

    testWidgets('узел подписки — Replace key нет', (tester) async {
      await big(tester);
      await pump(tester, data: const [offline]);
      expect(replace, findsNothing);
    });

    testWidgets('пустой ключ — Save неактивна', (tester) async {
      await big(tester);
      await pump(tester,
          data: const [offline], onSaveFields: (_) async => true);
      await tester.tap(replace);
      await tester.pumpAndSettle();
      expect(tester.widget<FilledButton>(saveKey).onPressed, isNull);
      await tester.enterText(
          find.byKey(const ValueKey('tailscale-replace-key-field')), '   ');
      await tester.pump();
      expect(tester.widget<FilledButton>(saveKey).onPressed, isNull);
    });

    testWidgets('Save пишет auth_key и применяет ключ', (tester) async {
      await big(tester);
      final actions = _FakeActions();
      final saved = <Map<String, Object?>>[];
      await pump(tester,
          data: const [offline],
          actions: actions,
          onSaveFields: (f) async {
            saved.add(f);
            return true;
          });
      await tester.tap(replace);
      await tester.pumpAndSettle();
      await tester.enterText(
          find.byKey(const ValueKey('tailscale-replace-key-field')),
          ' tskey-auth-new ');
      await tester.pump();
      await tester.tap(saveKey);
      await tester.pumpAndSettle();
      expect(saved, [
        {'auth_key': 'tskey-auth-new'},
      ]);
      expect(actions.applied, ['ts:tskey-auth-new']);
      expect(find.text('Signing in with the new key…'), findsOneWidget);
    });

    Future<void> enterKey(WidgetTester tester, _FakeActions actions) async {
      await pump(tester,
          data: const [offline],
          actions: actions,
          onSaveFields: (_) async => true);
      await tester.tap(replace);
      await tester.pumpAndSettle();
      await tester.enterText(
          find.byKey(const ValueKey('tailscale-replace-key-field')), 'k');
      await tester.pump();
      await tester.tap(saveKey);
      await tester.pumpAndSettle();
      expect(actions.applied, ['ts:k']);
    }

    testWidgets('туннель не поднят — ключ применится при старте VPN',
        (tester) async {
      await big(tester);
      await enterKey(
          tester, _FakeActions()..apply = TailscaleKeyApply.deferred);
      expect(find.text('Key saved. It applies when the VPN starts.'),
          findsOneWidget);
    });

    testWidgets('отказ ядра у выключенного узла — «сначала включить»',
        (tester) async {
      await big(tester);
      final actions = _FakeActions()
        ..apply = const TailscaleKeyApply.failed('failed_precondition')
        ..states['ts'] = CcEndpointState.disabled;
      await enterKey(tester, actions);
      expect(find.text('Turn the node on first.'), findsOneWidget);
    });

    testWidgets('прочий отказ ядра — «не удалось войти»', (tester) async {
      await big(tester);
      await enterKey(tester,
          _FakeActions()..apply = const TailscaleKeyApply.failed('not_found'));
      expect(find.text('Could not sign in with the new key.'), findsOneWidget);
    });

    testWidgets('запись не удалась — ключ не применяется', (tester) async {
      await big(tester);
      final actions = _FakeActions();
      await pump(tester,
          data: const [offline],
          actions: actions,
          onSaveFields: (_) async => false);
      await tester.tap(replace);
      await tester.pumpAndSettle();
      await tester.enterText(
          find.byKey(const ValueKey('tailscale-replace-key-field')), 'k');
      await tester.pump();
      await tester.tap(saveKey);
      await tester.pumpAndSettle();
      expect(actions.applied, isEmpty);
    });

    testWidgets('Running — чип, выбор, имя и без Replace key',
        (tester) async {
      await big(tester);
      const running = CcTailscaleStatus(
        tag: 'ts',
        backendState: 'Running',
        stateText: '',
        keyAuth: true,
        self: CcTailscalePeer(hostName: 'phone', ips: ['100.64.0.1']),
        userGroups: [
          CcTailscaleUserGroup(peers: [_gw]),
        ],
      );
      await pump(tester,
          data: const [running],
          body: const {'exit_node': '100.64.0.2'},
          onSave: (_) async {},
          onSaveFields: (_) async => true);
      expect(find.text('signed in with a key'), findsOneWidget);
      expect(find.byType(RadioListTile<String>), findsWidgets);
      expect(find.text('phone'), findsOneWidget);
      expect(replace, findsNothing);
      expect(find.byKey(const ValueKey('tailscale-saved-exit-node')),
          findsNothing);
    });
  });

  group('§706 — выключатель и перезапуск узла', () {
    final toggle = find.byKey(const ValueKey('tailscale-node-enabled'));
    final restart = find.byKey(const ValueKey('tailscale-restart-node'));

    Future<_FakeActions> pumpNode(WidgetTester tester, String? state) async {
      await tester.binding.setSurfaceSize(const Size(800, 2400));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      final actions = _FakeActions();
      if (state != null) actions.states['ts'] = state;
      await pump(tester, data: [_status()], actions: actions);
      return actions;
    }

    testWidgets('ядро не отдало состояние — ни выключателя, ни Restart',
        (tester) async {
      await pumpNode(tester, null);
      expect(toggle, findsNothing);
      expect(restart, findsNothing);
    });

    testWidgets('VPN выключен — ни выключателя, ни Restart', (tester) async {
      final actions = _FakeActions()..states['ts'] = CcEndpointState.up;
      await pump(tester, vpnUp: false, data: [_status()], actions: actions);
      expect(toggle, findsNothing);
      expect(restart, findsNothing);
    });

    testWidgets('узел работает — включён, Restart есть', (tester) async {
      await pumpNode(tester, CcEndpointState.up);
      expect(tester.widget<SwitchListTile>(toggle).value, isTrue);
      expect(restart, findsOneWidget);
    });

    testWidgets('выключатель гасит узел — Restart пропадает', (tester) async {
      final actions = await pumpNode(tester, CcEndpointState.up);
      await tester.tap(toggle);
      await tester.pumpAndSettle();
      expect(actions.toggles, [false]);
      expect(tester.widget<SwitchListTile>(toggle).value, isFalse);
      expect(restart, findsNothing);
    });

    testWidgets('отказ выключателя — текст отказа', (tester) async {
      final actions = await pumpNode(tester, CcEndpointState.up);
      actions.toggleCodes.add('failed_precondition');
      await tester.tap(toggle);
      await tester.pumpAndSettle();
      expect(find.text('VPN is not running or is restarting. Try again.'),
          findsOneWidget);
      expect(tester.widget<SwitchListTile>(toggle).value, isTrue);
    });

    testWidgets('Restart — выкл, затем вкл; на время вызова неактивна',
        (tester) async {
      final actions = await pumpNode(tester, CcEndpointState.up);
      final hold = Completer<void>();
      actions.toggleHold = hold;
      await tester.tap(restart);
      await tester.pump();
      expect(tester.widget<OutlinedButton>(restart).onPressed, isNull);
      actions.toggleHold = null;
      hold.complete();
      await tester.pumpAndSettle();
      expect(actions.toggles, [false, true]);
      expect(find.text('Node restarted.'), findsOneWidget);
      expect(tester.widget<OutlinedButton>(restart).onPressed, isNotNull);
    });

    testWidgets('Restart: выключение отказало — включения нет',
        (tester) async {
      final actions = await pumpNode(tester, CcEndpointState.up);
      actions.toggleCodes.add('not_found');
      await tester.tap(restart);
      await tester.pumpAndSettle();
      expect(actions.toggles, [false]);
      expect(find.text('Node restarted.'), findsNothing);
    });
  });

  group('§707 — Taildrop', () {
    Future<StreamController<CcTaildropInbox>> pumpDrop(
      WidgetTester tester,
      _DropActions actions, {
      bool canShare = true,
    }) async {
      await tester.binding.setSurfaceSize(const Size(800, 3000));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      final status = StreamController<List<CcTailscaleStatus>>();
      final inbox = StreamController<CcTaildropInbox>();
      addTearDown(status.close);
      addTearDown(inbox.close);
      await tester.pumpWidget(MaterialApp(
        home: Scaffold(
          body: TailscaleNetworkTab(
            liveTag: 'ts',
            body: const {},
            statusSource: status.stream,
            inboxSource: inbox.stream,
            vpnUp: true,
            actions: actions,
          ),
        ),
      ));
      status.add([_dropStatus(canShare: canShare)]);
      await tester.pump();
      return inbox;
    }

    test('цель отправки: в сети, принимает файлы, не расшарен', () {
      final targets = _dropStatus()
          .peers
          .where((p) => p.isTaildropTarget)
          .map((p) => p.hostName);
      expect(targets, ['laptop']);
    });

    test('разбор входящих и статуса из канала', () {
      final inbox = CcTaildropInbox.fromMap({
        'tag': 'ts',
        'files': [
          {'name': 'a.jpg', 'size': 2048, 'sender_name': 'laptop', 'modified_at': 5},
        ],
        'receiving': [
          {'name': 'b.zip', 'size': 100, 'received_bytes': 25, 'sender_id': 's1', 'sender_name': 'desk'},
        ],
      });
      expect(inbox.files.single.size, 2048);
      expect(inbox.receiving.single.progress, 0.25);
      final st = CcTailscaleStatus.fromMap({
        'tag': 'ts',
        'can_share_files': false,
        'unread_file_count': 3,
      });
      expect(st.canShareFiles, isFalse);
      expect(st.unreadFileCount, 3);
      // Нет поля — право не отрицается.
      expect(CcTailscaleStatus.fromMap({'tag': 'ts'}).canShareFiles, isTrue);
      expect(
          CcTailscalePeer.fromMap({'can_receive_files': true}).canReceiveFiles,
          isTrue);
    });

    testWidgets('подписка на входящие с вкладкой; пусто — блока нет',
        (tester) async {
      final actions = _DropActions();
      final inbox = await pumpDrop(tester, actions);
      expect(actions.calls, ['start:ts']);
      inbox.add(const CcTaildropInbox(tag: 'ts'));
      await tester.pump();
      await tester.pump(); // снапшот приходит микрозадачей после кадра
      expect(find.text('Inbox'), findsNothing);
      await tester.pumpWidget(const SizedBox());
      expect(actions.calls.last, 'stop');
    });

    testWidgets('принятый файл: строка, Save и Delete, просмотр отмечен',
        (tester) async {
      final actions = _DropActions();
      final inbox = await pumpDrop(tester, actions);
      inbox.add(const CcTaildropInbox(tag: 'other', files: [
        CcTaildropFile(name: 'alien.txt'),
      ]));
      await tester.pump();
      await tester.pump(); // снапшот приходит микрозадачей после кадра
      expect(find.text('alien.txt'), findsNothing);
      inbox.add(const CcTaildropInbox(tag: 'ts', files: [
        CcTaildropFile(name: 'photo.jpg', size: 2048, senderName: 'laptop'),
      ]));
      await tester.pump();
      await tester.pump(); // снапшот приходит микрозадачей после кадра
      expect(find.text('Inbox'), findsOneWidget);
      expect(find.text('photo.jpg'), findsOneWidget);
      expect(actions.calls, contains('read:ts'));
      await tester.tap(find.byTooltip('Save'));
      await tester.pump();
      expect(actions.calls, contains('save:photo.jpg'));
      expect(find.text('Saved to Downloads'), findsOneWidget);
      await tester.tap(find.byTooltip('Delete'));
      await tester.pump();
      expect(actions.calls, contains('delete:photo.jpg'));
    });

    testWidgets('файл в приёме: прогресс и Cancel', (tester) async {
      final actions = _DropActions();
      final inbox = await pumpDrop(tester, actions);
      inbox.add(const CcTaildropInbox(tag: 'ts', receiving: [
        CcTaildropReceiving(
            name: 'big.iso', size: 100, receivedBytes: 40, senderId: 's1'),
      ]));
      await tester.pump();
      await tester.pump(); // снапшот приходит микрозадачей после кадра
      final bar = tester.widget<LinearProgressIndicator>(
          find.byType(LinearProgressIndicator));
      expect(bar.value, 0.4);
      await tester.tap(find.widgetWithText(TextButton, 'Cancel'));
      await tester.pump();
      expect(actions.calls, contains('cancel:s1/big.iso'));
    });

    testWidgets('Taildrop выключен в tailnet — причина, Send file… нет',
        (tester) async {
      final actions = _DropActions();
      await pumpDrop(tester, actions, canShare: false);
      expect(find.byKey(const ValueKey('taildrop-sharing-off')), findsOneWidget);
      await tester.tap(find.widgetWithText(ListTile, 'laptop').last);
      await tester.pumpAndSettle();
      expect(find.text('Send file…'), findsNothing);
    });

    testWidgets('Send file… только у цели отправки', (tester) async {
      final actions = _DropActions();
      await pumpDrop(tester, actions);
      await tester.tap(find.widgetWithText(ListTile, 'tv').last);
      await tester.pumpAndSettle();
      expect(find.text('Send file…'), findsNothing);
      await tester.tapAt(const Offset(10, 10));
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(ListTile, 'laptop').last);
      await tester.pumpAndSettle();
      await tester.tap(find.text('Send file…'));
      await tester.pumpAndSettle();
      expect(actions.calls, contains('send:n5'));
      expect(find.text('Sending to laptop'), findsOneWidget);
    });
  });
}
