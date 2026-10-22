import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lxbox/controllers/subscription_controller.dart';
import 'package:lxbox/models/node_spec.dart';
import 'package:lxbox/models/server_list.dart';
import 'package:lxbox/screens/subscription_detail_screen.dart';
import 'package:lxbox/services/settings_storage.dart';

import '../parser/engine_test_setup.dart';
import '../probe/probe_session_fake.dart';

/// §669 — Stop в Test servers: «Stopping…» и неактивная кнопка, пока старый
/// прогон не дошёл до конца (обрыв замеров + закрытие сессии); затем Start
/// снова доступен и новый прогон идёт в своей сессии.
///
/// Реальный I/O SettingsStorage (mock path_provider) резолвится только вне
/// fake-async — поэтому ожидание через `runAsync` (грабля update_snackbar_test).
NodeSpec _node(String label) => VlessSpec(
      id: label,
      tag: label,
      label: label,
      server: '$label.example.com',
      port: 443,
      rawSource: '',
      uuid: '00000000-0000-0000-0000-000000000000',
    );

Future<void> _until(WidgetTester tester, bool Function() cond,
    {String what = ''}) async {
  // Хотя бы один кадр: условие может стать истинным ещё внутри tap().
  await tester.pump();
  for (var i = 0; i < 300 && !cond(); i++) {
    await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 5)));
    await tester.pump();
  }
  expect(cond(), isTrue, reason: 'не дождались: $what');
}

void main() {
  setUpAll(loadEngineSections);

  const methods = MethodChannel('com.leadaxe.lxbox/methods');
  const ppChannel = MethodChannel('plugins.flutter.io/path_provider');
  late FakeProbeSession fake;
  late Directory tmp;

  setUp(() async {
    tmp = await Directory.systemTemp.createTemp('lxbox_probe_stop_');
    fake = FakeProbeSession();
    final m = TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    m.setMockMethodCallHandler(ppChannel, (call) async => tmp.path);
    m.setMockMethodCallHandler(methods, fake.handle);
    SettingsStorage.resetCacheForTesting();
  });

  tearDown(() async {
    final m = TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    m.setMockMethodCallHandler(ppChannel, null);
    m.setMockMethodCallHandler(methods, null);
    SettingsStorage.resetCacheForTesting();
    await tmp.delete(recursive: true);
  });

  testWidgets('Stop → Stopping… → прогон завершён → Start снова доступен',
      (tester) async {
    final entry = SubscriptionEntry(
      list: SubscriptionServers(
        id: 'sub-1',
        name: 'Sub',
        enabled: true,
        tagPrefix: '',
        detourPolicy: DetourPolicy.defaults,
        url: 'https://example.com/sub',
        nodes: [for (var i = 1; i <= 8; i++) _node('n$i')],
      ),
    );
    final c = SubscriptionController()..debugSetEntries([entry]);
    await tester.pumpWidget(MaterialApp(
      home: SubscriptionDetailScreen(entry: entry, controller: c),
    ));
    await tester.pumpAndSettle();

    await tester.tap(find.byIcon(Icons.speed));
    await _until(tester, () => fake.pendingCount == 6, what: 'замеры в полёте');
    expect(find.textContaining('Testing…'), findsOneWidget);

    // closeService «долгий»: probeStop висит, пока тест его не отпустит.
    fake.stopGate = Completer<void>();
    await tester.tap(find.byIcon(Icons.stop_circle_outlined));
    await _until(tester, () => fake.callsOf('probeStop') == 1,
        what: 'старый прогон дошёл до probeStop');
    expect(fake.runIdsOf('probeCancel'), [1], reason: 'замеры оборваны');
    expect(find.text('Stopping…'), findsOneWidget);

    // Кнопка неактивна: повторный тап новую сессию не поднимает.
    await tester.tap(find.byIcon(Icons.stop_circle_outlined),
        warnIfMissed: false);
    await tester.pump();
    expect(fake.callsOf('probeStart'), 1);

    // Сессия закрылась → прогон завершён → Start доступен.
    fake.stopGate!.complete();
    fake.stopGate = null;
    await _until(tester, () => find.byIcon(Icons.speed).evaluate().isNotEmpty,
        what: 'Start снова доступен');
    expect(find.text('Stopping…'), findsNothing);

    // Новый прогон — своя сессия; старый его индикатор не гасит.
    await tester.tap(find.byIcon(Icons.speed));
    await _until(tester, () => fake.pendingCount == 6,
        what: 'новый прогон в полёте');
    expect(fake.live, 2);
    expect(find.textContaining('Testing…'), findsOneWidget);

    fake.holdUrlTests = false;
    fake.releaseOk();
    await _until(tester, () => fake.live == null, what: 'новый прогон завершён');
    await tester.pump(const Duration(milliseconds: 200));
    expect(find.textContaining('8 ok'), findsOneWidget);
  });
}
