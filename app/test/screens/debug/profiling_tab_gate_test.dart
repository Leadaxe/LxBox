import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lxbox/screens/debug/profiling_tab.dart';

/// §013-DIAGNOSTICS P24 — профилировочный снимок берётся только при живом
/// ядре: без поднятого туннеля `_capture` не должен дёргать native
/// `pprofProfile`, только показать снэк "VPN must be running…" и выйти.
///
/// Mutation, которую тест обязан ловить: гейт снят (снимок берётся
/// независимо от статуса VPN) — тогда `pprofProfile` будет вызван.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const channel = MethodChannel('com.leadaxe.lxbox/methods');
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  final calls = <MethodCall>[];

  setUp(() {
    calls.clear();
    messenger.setMockMethodCallHandler(channel, (call) async {
      calls.add(call);
      switch (call.method) {
        case 'getVpnStatus':
          // native отдаёт "Stopped" → TunnelStatus.disconnected, isUp=false.
          return {'status': 'Stopped', 'revoked': false};
        case 'pprofProfile':
          // Если это когда-либо вызвано при выключенном VPN — гейт сломан.
          return Uint8List(0);
        default:
          return null;
      }
    });
  });

  tearDown(() {
    messenger.setMockMethodCallHandler(channel, null);
  });

  testWidgets(
      'P24: capture button does not call pprofProfile when VPN is down',
      (tester) async {
    await tester.pumpWidget(const MaterialApp(
      home: Scaffold(body: ProfilingTab()),
    ));
    await tester.pumpAndSettle();

    final captureButtons = find.byType(OutlinedButton);
    expect(captureButtons, findsWidgets);

    await tester.tap(captureButtons.first);
    // getVpnStatus — async native call, дать ему разрешиться.
    await tester.pumpAndSettle();

    expect(
      calls.map((c) => c.method),
      isNot(contains('pprofProfile')),
      reason: 'snapshot must not be taken without a live core (P24)',
    );
    expect(calls.map((c) => c.method), contains('getVpnStatus'));

    // Gate feedback — the "VPN must be running…" snack is shown.
    expect(find.text('VPN must be running to capture a profile.'),
        findsOneWidget);
  });
}
