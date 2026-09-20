import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lxbox/models/node_warning.dart';
import 'package:lxbox/screens/subscription_detail_screen/widgets/node_warning_row.dart';
import 'package:lxbox/screens/subscription_detail_screen/widgets/node_warnings_sheet.dart';
import 'package:lxbox/services/contract/registry.dart';
import 'package:lxbox/widgets/node_row.dart';
import 'package:lxbox/widgets/node_view_item.dart';

/// §502 — значок уведомлений в строке протокола на главном экране.
void main() {
  setUpAll(() async {
    await ContractRegistry.I.loadFromDirectory('assets/contract');
  });

  tearDownAll(ContractRegistry.I.resetForTesting);
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
  const err = RegistryWarning(
    code: 'field_missing',
    path: 'sni',
    params: {'field': 'sni'},
  );

  NodeViewItem item({
    List<NodeWarning>? notificationWarnings,
    String protocolLabel = 'VLESS·tcp·TLS',
  }) =>
      NodeViewItem(
        tag: 'DE node',
        active: false,
        highlighted: false,
        delay: 126,
        pingBusy: false,
        tunnelUp: true,
        busy: false,
        urltestNow: null,
        hasDetour: false,
        protocolLabel: protocolLabel,
        notificationWarnings: notificationWarnings,
      );

  Widget host(NodeViewItem rowItem) => MaterialApp(
        home: Scaffold(
          body: NodeRow(
            item: rowItem,
            onHighlight: () {},
            onActivate: () {},
            onPing: () {},
          ),
        ),
      );

  Icon badgeWidget(WidgetTester tester) {
    final icons = tester.widgetList<Icon>(find.descendant(
      of: find.byType(NodeInfoBadge),
      matching: find.byType(Icon),
    ));
    expect(icons.length, 1);
    return icons.first;
  }

  testWidgets('без уведомлений — значка нет', (tester) async {
    await tester.pumpWidget(host(item(notificationWarnings: const [])));
    expect(find.byType(NodeInfoBadge), findsNothing);
  });

  testWidgets('info — приглушённый (i) перед протоколом', (tester) async {
    await tester.pumpWidget(host(item(notificationWarnings: const [infoOnly])));
    expect(find.byType(NodeInfoBadge), findsOneWidget);
    final ico = badgeWidget(tester);
    expect(ico.icon, Icons.info_outline);
    final ctx = tester.element(find.byType(NodeInfoBadge));
    expect(ico.color, Theme.of(ctx).colorScheme.onSurfaceVariant);
    expect(find.text('VLESS·tcp·TLS'), findsOneWidget);
  });

  testWidgets('warning — треугольник перед протоколом', (tester) async {
    await tester.pumpWidget(host(item(notificationWarnings: const [warn])));
    expect(badgeWidget(tester).icon, Icons.warning_amber);
  });

  testWidgets('error — круг с × перед протоколом', (tester) async {
    await tester.pumpWidget(host(item(notificationWarnings: const [err])));
    expect(badgeWidget(tester).icon, Icons.error_outline);
  });

  testWidgets('тап по значку открывает шторку уведомлений', (tester) async {
    await tester.pumpWidget(host(item(notificationWarnings: const [warn])));

    await tester.tap(find.byType(NodeInfoBadge));
    await tester.pumpAndSettle();

    expect(find.byType(NodeWarningsSheet), findsOneWidget);
  });

  testWidgets('null notificationWarnings — значка нет (служебная строка)',
      (tester) async {
    await tester.pumpWidget(host(item(notificationWarnings: null)));
    expect(find.byType(NodeInfoBadge), findsNothing);
  });
}
