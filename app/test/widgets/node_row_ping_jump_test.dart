import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lxbox/widgets/node_row.dart';
import 'package:lxbox/widgets/node_view_item.dart';

/// Строка direct без бейджей: появление «PING…» и замера не сдвигает
/// заголовок (раньше подзаголовок схлопывался в 0 и заголовок прыгал).
void main() {
  NodeViewItem item({int? delay, bool pingBusy = false}) => NodeViewItem(
    tag: 'direct-out',
    active: false,
    highlighted: false,
    delay: delay,
    pingBusy: pingBusy,
    tunnelUp: true,
    busy: false,
    urltestNow: null,
    hasDetour: false,
    protocolLabel: null,
    outboundType: 'direct',
  );

  Widget host(NodeViewItem i) => MaterialApp(
    home: Scaffold(
      body: NodeRow(
        item: i,
        onHighlight: () {},
        onActivate: () {},
        onPing: () {},
      ),
    ),
  );

  Future<double> titleTop(WidgetTester tester, NodeViewItem i) async {
    await tester.pumpWidget(host(i));
    return tester.getTopLeft(find.byType(Text).first).dy;
  }

  testWidgets('заголовок direct стоит на месте при пинге', (tester) async {
    final idle = await titleTop(tester, item());
    final busy = await titleTop(tester, item(pingBusy: true));
    final done = await titleTop(tester, item(delay: 199));
    expect(busy, idle);
    expect(done, idle);
  });
}
