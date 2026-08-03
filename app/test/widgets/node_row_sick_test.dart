import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lxbox/widgets/node_row.dart';
import 'package:lxbox/widgets/node_view_item.dart';

/// §355 — ⚠-метка корня беды на строке ноды: рисуется только при
/// isSickRoot, тап по ней дёргает onSickTap (открытие sheet — за caller'ом).
void main() {
  NodeViewItem item({required bool isSickRoot}) => NodeViewItem(
        tag: 'RU node',
        active: false,
        highlighted: false,
        delay: -1,
        pingBusy: false,
        tunnelUp: true,
        busy: false,
        urltestNow: null,
        hasDetour: false,
        protocolLabel: 'VLESS',
        isSickRoot: isSickRoot,
      );

  Widget host(NodeViewItem i, {VoidCallback? onSickTap}) => MaterialApp(
        home: Scaffold(
          body: NodeRow(
            item: i,
            onHighlight: () {},
            onActivate: () {},
            onPing: () {},
            onSickTap: onSickTap,
          ),
        ),
      );

  testWidgets('isSickRoot=false — метки нет', (tester) async {
    await tester.pumpWidget(host(item(isSickRoot: false)));
    expect(find.byIcon(Icons.warning_amber_rounded), findsNothing);
  });

  testWidgets('isSickRoot=true — метка есть, тап зовёт onSickTap',
      (tester) async {
    var taps = 0;
    await tester.pumpWidget(
        host(item(isSickRoot: true), onSickTap: () => taps++));
    final icon = find.byIcon(Icons.warning_amber_rounded);
    expect(icon, findsOneWidget);
    await tester.tap(icon);
    expect(taps, 1);
  });
}
