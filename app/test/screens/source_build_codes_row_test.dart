import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lxbox/controllers/subscription_controller.dart';
import 'package:lxbox/models/node_spec.dart';
import 'package:lxbox/models/node_warning.dart';
import 'package:lxbox/screens/subscription_detail_screen/node_inspect_screen.dart';
import 'package:lxbox/screens/subscription_detail_screen/widgets/node_warnings_sheet.dart';
import 'package:lxbox/screens/subscription_detail_screen/widgets/source_build_codes_row.dart';
import 'package:lxbox/services/contract/registry.dart';
import 'package:lxbox/services/parser/body_decoder.dart';
import 'package:lxbox/services/parser/parse_all.dart';
import 'package:lxbox/widgets/node_diagnostics_tab.dart';

import '../parser/engine_test_setup.dart';

/// §739 итер. 2 — коды сборки источника строкой на странице подписки/папки
/// (как «N entries dropped»: тап — шторка) и на карточке узла подписки.
void main() {
  setUpAll(loadEngineSections);
  tearDownAll(unloadEngineSections);

  const unavailable = RegistryWarning(
    code: 'detour_unavailable',
    params: {'target': '⚡ J730', 'count': '1', 'tags': 'S730-A'},
    ownerTag: 'Sub730',
  );
  const throughGroup = RegistryWarning(
    code: 'node_detour_through_group',
    params: {'group': 'vpn-2', 'count': '1', 'tags': 'S730-A'},
    ownerTag: 'Sub730',
  );

  Future<SubscriptionController> pumpRow(
    WidgetTester tester,
    Map<String, List<RegistryWarning>> codes,
  ) async {
    final c = SubscriptionController()..debugSetLastSourceBuildCodes(codes);
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: SourceBuildCodesRow(controller: c, sourceId: 's1'),
      ),
    ));
    return c;
  }

  testWidgets('нет кодов у источника — строки нет', (tester) async {
    await pumpRow(tester, {
      'other': [unavailable],
    });
    expect(find.byIcon(Icons.chevron_right), findsNothing);
  });

  testWidgets('один код: заголовок, тап открывает шторку', (tester) async {
    await pumpRow(tester, {
      's1': [unavailable],
    });
    expect(find.textContaining('⚡ J730'), findsOneWidget);
    expect(find.textContaining('more'), findsNothing);

    await tester.tap(find.byIcon(Icons.chevron_right));
    await tester.pumpAndSettle();
    final sheet =
        tester.widget<NodeWarningsSheet>(find.byType(NodeWarningsSheet));
    expect(sheet.warnings, [unavailable]);
  });

  testWidgets('два кода — счётчик «+1 more», в шторке оба', (tester) async {
    await pumpRow(tester, {
      's1': [unavailable, throughGroup],
    });
    expect(find.textContaining('(+1 more)'), findsOneWidget);
    await tester.tap(find.byIcon(Icons.chevron_right));
    await tester.pumpAndSettle();
    final sheet =
        tester.widget<NodeWarningsSheet>(find.byType(NodeWarningsSheet));
    expect(sheet.warnings, hasLength(2));
  });

  testWidgets('строка обновляется после пересборки без перезахода',
      (tester) async {
    final c = await pumpRow(tester, const {});
    expect(find.byIcon(Icons.chevron_right), findsNothing);

    c.debugSetLastSourceBuildCodes({
      's1': [unavailable],
    });
    c.notifyListeners();
    await tester.pump();
    expect(find.byIcon(Icons.chevron_right), findsOneWidget);

    c.debugSetLastSourceBuildCodes(const {});
    c.notifyListeners();
    await tester.pump();
    expect(find.byIcon(Icons.chevron_right), findsNothing);
  });

  testWidgets('карточка узла подписки: код сборки на вкладке Diagnostics',
      (tester) async {
    expect(ContractRegistry.I.isLoaded, isTrue);
    final NodeSpec node = parseAll(decode(
      'socks5://10.0.2.2:18092#S730-A',
    )).single;
    await tester.pumpWidget(MaterialApp(
      home: NodeInspectScreen(
        node: node,
        initialTab: NodeInspectTab.diagnostics,
        buildWarnings: const [unavailable],
      ),
    ));
    await tester.pumpAndSettle();
    final label = tester.widget<NodeDiagnosticsTabLabel>(
        find.byType(NodeDiagnosticsTabLabel));
    expect(label.warnings, contains(unavailable));
    expect(find.textContaining('⚡ J730'), findsWidgets);
  });
}
