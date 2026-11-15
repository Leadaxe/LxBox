import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lxbox/controllers/subscription_controller.dart';
import 'package:lxbox/models/node_link.dart';
import 'package:lxbox/models/node_spec.dart';
import 'package:lxbox/models/server_list.dart';
import 'package:lxbox/screens/subscription_detail_screen.dart';
import 'package:lxbox/services/settings_storage.dart';

import '../parser/engine_test_setup.dart';
import '../probe/probe_session_fake.dart';

/// §730 — пометка под панелью «Тест серверов» на экране подписки: нет
/// detour → пометки нет; detour на Направление → «не учтён»; detour на узел
/// одиночного сервера → «Tested through …», и проба идёт через цель.
NodeSpec _node(String label) => VlessSpec(
      id: label,
      tag: label,
      label: label,
      server: '${label.toLowerCase()}.example.com',
      port: 443,
      rawSource: '',
      uuid: '00000000-0000-0000-0000-000000000000',
    );

const _unapplied =
    'Detour of this source is not applied in the test — nodes are checked directly.';

Future<void> _until(WidgetTester tester, bool Function() cond,
    {String what = ''}) async {
  await tester.pump();
  for (var i = 0; i < 300 && !cond(); i++) {
    await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 5)));
    await tester.pump();
  }
  expect(cond(), isTrue, reason: 'не дождались: $what');
  await tester.pump();
}

void main() {
  setUpAll(loadEngineSections);

  const methods = MethodChannel('com.leadaxe.lxbox/methods');
  const ppChannel = MethodChannel('plugins.flutter.io/path_provider');
  late FakeProbeSession fake;
  late Directory tmp;

  setUp(() async {
    tmp = await Directory.systemTemp.createTemp('lxbox_probe_detour_');
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

  Future<SubscriptionEntry> pumpWith(
      WidgetTester tester, DetourPolicy policy) async {
    final sub = SubscriptionEntry(
      list: SubscriptionServers(
        id: 'sub-1',
        name: 'Sub',
        enabled: true,
        tagPrefix: '',
        detourPolicy: policy,
        url: 'https://example.com/sub',
        nodes: [_node('A'), _node('B')],
      ),
    );
    final proxy = SubscriptionEntry(
      list: UserServer(
        id: 'srv',
        name: 'Proxy',
        enabled: true,
        tagPrefix: '',
        detourPolicy: DetourPolicy.defaults,
        nodes: [_node('Proxy')],
      ),
    );
    final c = SubscriptionController()..debugSetEntries([sub, proxy]);
    await tester.pumpWidget(MaterialApp(
      home: SubscriptionDetailScreen(entry: sub, controller: c),
    ));
    await tester.pumpAndSettle();
    return sub;
  }

  testWidgets('detour не задан — пометки нет', (tester) async {
    await pumpWith(tester, DetourPolicy.defaults);
    expect(find.text(_unapplied), findsNothing);
    expect(find.textContaining('Tested through'), findsNothing);
  });

  testWidgets('detour на Направление — «не учтён», видна до прогона',
      (tester) async {
    await pumpWith(tester,
        const DetourPolicy(overrideDetour: NodeLink(tag: 'vpn-1')));
    expect(find.text(_unapplied), findsOneWidget);
  });

  testWidgets('выбор detour в настройках — пометка появляется сразу',
      (tester) async {
    final sub = await pumpWith(tester, DetourPolicy.defaults);
    expect(find.textContaining('Tested through'), findsNothing);
    sub.overrideDetour = const NodeLink(tag: 'Proxy');
    await tester.pump();
    expect(find.text('Tested through Proxy.'), findsOneWidget);
  });

  testWidgets(
      'хвост None (use_detour_servers=false + override, APPEND) — пометки '
      'нет, и Settings не рисует путь через цель', (tester) async {
    await pumpWith(
        tester,
        const DetourPolicy(
            useDetourServers: false, overrideDetour: NodeLink(tag: 'Proxy')));
    expect(find.textContaining('Tested through'), findsNothing);
    expect(find.text(_unapplied), findsNothing);
    await tester.tap(find.text('Settings'));
    await tester.pumpAndSettle();
    expect(find.text('None — nodes connect directly'), findsOneWidget);
    expect(find.textContaining('Phone →'), findsNothing);
  });

  testWidgets('detour на узел сервера — «Tested through», проба через цель',
      (tester) async {
    await pumpWith(tester,
        const DetourPolicy(overrideDetour: NodeLink(tag: 'Proxy')));
    expect(find.text('Tested through Proxy.'), findsOneWidget);
    expect(find.text(_unapplied), findsNothing);

    fake.holdUrlTests = false;
    await tester.tap(find.byIcon(Icons.speed));
    await _until(tester, () => fake.callsOf('probeStart') == 1,
        what: 'probe-сессия поднята');
    final start = fake.calls.firstWhere((c) => c.method == 'probeStart');
    final cfg = jsonDecode((start.arguments as Map)['config'] as String)
        as Map<String, dynamic>;
    final out = (cfg['outbounds'] as List).cast<Map<String, dynamic>>();
    Map<String, dynamic> byTag(String t) =>
        out.firstWhere((o) => o['tag'] == t);
    expect(byTag('A')['detour'], 'Proxy');
    expect(byTag('B')['detour'], 'Proxy-2');
    expect(byTag('Proxy-2')['type'], 'vless');
    await _until(tester, () => fake.live == null, what: 'прогон завершён');
    // Пометка остаётся и после прогона.
    expect(find.text('Tested through Proxy.'), findsOneWidget);
  });
}
