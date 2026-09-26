import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lxbox/models/config_node.dart';
import 'package:lxbox/widgets/node_row.dart';
import 'package:lxbox/widgets/node_view_item.dart';

import '../contract_paths.dart';

/// §556 (§56/§60, контракт 1.1.60) — подпись уровня протокола в строке узла
/// берётся из реестра (`levels`/`level`/`level_mark`/`range_form.level`) и
/// стоит рядом с именем протокола; у схем без `levels` её нет.
void main() {
  setUpAll(loadTestRegistry);

  ParsedConfig parse() => ParsedConfig.parse(jsonEncode({
        'outbounds': [
          {'tag': 'plain-vless', 'type': 'vless'},
        ],
        'endpoints': [
          {'tag': 'awg-range', 'type': 'wireguard', 'jc': 4, 'h1': '10-20'},
          {'tag': 'awg-mask', 'type': 'wireguard', 'jc': 4, 'ip': 'quic'},
          {'tag': 'wg', 'type': 'wireguard'},
        ],
      }));

  // Та же сборка подписи, что у списка узлов на главной: протокол ·
  // транспорт · security-слот.
  Widget host(ConfigNode n, String proto) => MaterialApp(
        home: Scaffold(
          body: NodeRow(
            item: NodeViewItem(
              tag: n.tag,
              active: false,
              highlighted: false,
              delay: -1,
              pingBusy: false,
              tunnelUp: false,
              busy: false,
              urltestNow: null,
              hasDetour: false,
              protocolLabel:
                  [proto, ?n.transportLabel, ?n.securityLabel].join('·'),
            ),
            onHighlight: () {},
            onActivate: () {},
            onPing: () {},
          ),
        ),
      );

  testWidgets('AWG с диапазоном заголовка — awg2 рядом с протоколом',
      (tester) async {
    await tester.pumpWidget(host(parse()['awg-range']!, 'WireGuard'));
    expect(find.textContaining('WireGuard·awg2'), findsOneWidget);
  });

  testWidgets('маскировка даёт суффикс level_mark', (tester) async {
    await tester.pumpWidget(host(parse()['awg-mask']!, 'WireGuard'));
    expect(find.textContaining('WireGuard·awg1.5+'), findsOneWidget);
  });

  testWidgets('без полей уровня и у схем без levels подписи нет',
      (tester) async {
    final pc = parse();
    expect(pc['wg']!.securityLabel, isNull);
    expect(pc['plain-vless']!.securityLabel, isNull);
    await tester.pumpWidget(host(pc['wg']!, 'WireGuard'));
    expect(find.textContaining('awg'), findsNothing);
  });
}
