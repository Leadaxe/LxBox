import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lxbox/vpn/cc_openconnect.dart';
import 'package:lxbox/widgets/openconnect_status_tab.dart';

/// §764 — вкладка Network узла OpenConnect.
CcOpenConnectSnapshot _snap(CcOpenConnectStatus s) =>
    CcOpenConnectSnapshot(endpoints: {s.tag: s});

void main() {
  group('rows', () {
    test('since: same day → HH:mm, other day → date', () {
      final d = DateTime(2026, 11, 26, 14, 20);
      final secs = d.millisecondsSinceEpoch ~/ 1000;
      expect(openConnectSinceLabel(secs, now: DateTime(2026, 11, 26, 18)),
          '14:20');
      expect(openConnectSinceLabel(secs, now: DateTime(2026, 11, 27, 9)),
          '2026-11-26 14:20');
      expect(openConnectSinceLabel(0), '');
    });

    test('host prefix length dropped, others kept', () {
      expect(openConnectAddressLabel('10.0.0.5/32'), '10.0.0.5');
      expect(openConnectAddressLabel('fd00::5/128'), 'fd00::5');
      expect(openConnectAddressLabel('10.0.0.0/24'), '10.0.0.0/24');
      expect(openConnectAddressLabel('10.0.0.5'), '10.0.0.5');
    });

    test('connecting: tunnel fields not shown', () {
      final rows = openConnectStatusRows(const CcOpenConnectStatus(
        tag: 'oc',
        state: CcOpenConnectState.connecting,
        tunnel: CcOpenConnectTunnel(transport: 'TLS'),
      ));
      expect(rows, [(label: 'State', value: 'Connecting…')]);
    });

    test('auth pending → waiting for sign-in', () {
      final rows = openConnectStatusRows(const CcOpenConnectStatus(
        tag: 'oc',
        state: CcOpenConnectState.authPending,
      ));
      expect(rows.first, (label: 'State', value: 'Waiting for sign-in'));
    });

    test('unknown state → state text', () {
      final rows = openConnectStatusRows(const CcOpenConnectStatus(
        tag: 'oc',
        state: 'reconnecting',
      ));
      expect(rows, [(label: 'State', value: 'reconnecting')]);
    });
  });

  group('tab', () {
    Future<StreamController<CcOpenConnectSnapshot>> pump(
      WidgetTester tester, {
      bool vpnUp = true,
    }) async {
      final ctrl = StreamController<CcOpenConnectSnapshot>();
      addTearDown(ctrl.close);
      await tester.pumpWidget(MaterialApp(
        home: Scaffold(
          body: OpenConnectStatusTab(
            liveTag: 'oc',
            statusSource: ctrl.stream,
            vpnUp: vpnUp,
          ),
        ),
      ));
      return ctrl;
    }

    testWidgets('VPN off → empty state', (tester) async {
      await pump(tester, vpnUp: false);
      expect(find.text('Start VPN to see the network.'), findsOneWidget);
    });

    testWidgets('node not in snapshot → not in running config',
        (tester) async {
      final ctrl = await pump(tester);
      ctrl.add(CcOpenConnectSnapshot.empty);
      await tester.pump();
      expect(find.text('The node is not in the running config.'),
          findsOneWidget);
    });

    testWidgets('connected → all rows', (tester) async {
      final ctrl = await pump(tester);
      final since =
          DateTime.now().millisecondsSinceEpoch ~/ 1000 - 60;
      ctrl.add(_snap(CcOpenConnectStatus(
        tag: 'oc',
        state: CcOpenConnectState.connected,
        tunnel: CcOpenConnectTunnel(
          server: 'gw.example.com:42319',
          flavor: 'fortinet',
          transport: 'DTLS',
          mtu: 1350,
          connectedSince: since,
          ipv4: const ['10.212.134.5/32'],
          ipv6: const ['fd00::5/128'],
          dns: const ['10.0.0.1', '10.0.0.2'],
        ),
      )));
      await tester.pump();
      expect(find.textContaining('Connected · since '), findsOneWidget);
      expect(find.text('gw.example.com:42319 · fortinet'), findsOneWidget);
      expect(find.text('DTLS'), findsOneWidget);
      expect(find.text('10.212.134.5 · fd00::5'), findsOneWidget);
      expect(find.text('10.0.0.1, 10.0.0.2'), findsOneWidget);
      expect(find.text('1350'), findsOneWidget);
      for (final l in ['State', 'Gateway', 'Transport', 'Address', 'DNS', 'MTU']) {
        expect(find.text(l), findsOneWidget, reason: l);
      }
    });

    testWidgets('error → kernel error text', (tester) async {
      final ctrl = await pump(tester);
      ctrl.add(_snap(const CcOpenConnectStatus(
        tag: 'oc',
        state: CcOpenConnectState.error,
        stateText: 'error',
        error: 'login failed: bad credentials',
      )));
      await tester.pump();
      expect(find.text('login failed: bad credentials'), findsOneWidget);
      expect(find.text('Error'), findsNWidgets(2));
      expect(find.text('Gateway'), findsNothing);
    });
  });
}
