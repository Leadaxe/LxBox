import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lxbox/controllers/home_controller.dart';
import 'package:lxbox/controllers/subscription_controller.dart';
import 'package:lxbox/models/config_node.dart';
import 'package:lxbox/models/node_spec.dart';
import 'package:lxbox/models/server_list.dart';
import 'package:lxbox/screens/outbound_view_screen.dart';
import 'package:lxbox/widgets/tailscale_network_tab.dart';

/// Задача 581 — вкладка Network на экране просмотра узла: видимость,
/// начальная вкладка, Save choice только у записи своего сервера/папки.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  final tsBody = {'type': 'tailscale', 'tag': 'ts'};

  ParsedConfig configWith(Map<String, dynamic> endpoint) =>
      ParsedConfig.parse(jsonEncode({
        'outbounds': [
          {'type': 'vless', 'tag': 'v', 'server': 'v.example', 'server_port': 443},
        ],
        'endpoints': [endpoint],
      }));

  SubscriptionController subWith(ServerList list) {
    final sub = SubscriptionController();
    sub.debugSetEntries([SubscriptionEntry(list: list, nodeCount: 1)]);
    return sub;
  }

  UserServer userServer() => UserServer(
        id: 'u1',
        name: 'ts',
        enabled: true,
        tagPrefix: '',
        detourPolicy: DetourPolicy.defaults,
        origin: UserSource.paste,
        rawBody: jsonEncode(tsBody),
        nodes: [TailscaleSpec(id: 'n1', tag: 'ts', label: 'ts', body: tsBody)],
      );

  SubscriptionServers subscription() => SubscriptionServers(
        id: 's1',
        name: 'sub',
        enabled: true,
        tagPrefix: '',
        detourPolicy: DetourPolicy.defaults,
        url: 'https://example.com/sub',
        nodes: [TailscaleSpec(id: 'n1', tag: 'ts', label: 'ts', body: tsBody)],
      );

  Future<void> pump(
    WidgetTester tester, {
    required String tag,
    required SubscriptionController sub,
    bool openNetwork = false,
  }) async {
    final home = HomeController();
    addTearDown(home.dispose);
    await tester.pumpWidget(MaterialApp(
      home: OutboundViewScreen(
        tag: tag,
        kind: tag == 'ts' ? 'tailscale' : 'vless',
        json: '{}',
        detourCount: 0,
        onCopy: (_) {},
        config: configWith(tsBody),
        subController: sub,
        homeController: home,
        openNetwork: openNetwork,
      ),
    ));
    await tester.pump();
  }

  /// Без моста `getVpnStatus` вкладки Network ждёт ответа 3 с: снять экран
  /// и дать фейковому времени дойти до конца таймера.
  Future<void> dispose(WidgetTester tester) async {
    await tester.pumpWidget(const SizedBox());
    await tester.pump(const Duration(seconds: 5));
  }

  int selectedTab(WidgetTester tester) =>
      DefaultTabController.of(tester.element(find.byType(TabBar))).index;

  testWidgets('узел Tailscale: Network перед Diagnostics', (tester) async {
    await pump(tester, tag: 'ts', sub: subWith(userServer()));
    final tabs = tester.widget<TabBar>(find.byType(TabBar)).tabs;
    expect(tabs.length, 4);
    expect((tabs[2] as Tab).text, 'Network');
    expect(selectedTab(tester), 0);
  });

  testWidgets('узел не Tailscale: вкладки Network нет', (tester) async {
    await pump(tester, tag: 'v', sub: subWith(userServer()),
        openNetwork: true);
    expect(tester.widget<TabBar>(find.byType(TabBar)).tabs.length, 3);
    expect(find.text('Network'), findsNothing);
    expect(selectedTab(tester), 0);
  });

  testWidgets('из NETWORKS: начальная вкладка Network, Save choice есть',
      (tester) async {
    await pump(tester, tag: 'ts', sub: subWith(userServer()),
        openNetwork: true);
    expect(selectedTab(tester), 2);
    final tab = tester.widget<TailscaleNetworkTab>(
        find.byType(TailscaleNetworkTab));
    expect(tab.onSaveExitNode, isNotNull);
    await dispose(tester);
  });

  testWidgets('узел подписки: Save choice скрыта', (tester) async {
    await pump(tester, tag: 'ts', sub: subWith(subscription()),
        openNetwork: true);
    final tab = tester.widget<TailscaleNetworkTab>(
        find.byType(TailscaleNetworkTab));
    expect(tab.onSaveExitNode, isNull);
    await dispose(tester);
  });

  testWidgets('записи нет: Save choice скрыта', (tester) async {
    await pump(tester, tag: 'ts', sub: SubscriptionController(),
        openNetwork: true);
    final tab = tester.widget<TailscaleNetworkTab>(
        find.byType(TailscaleNetworkTab));
    expect(tab.onSaveExitNode, isNull);
    await dispose(tester);
  });
}
