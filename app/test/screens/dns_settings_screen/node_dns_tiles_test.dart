import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lxbox/models/dns_ref.dart';
import 'package:lxbox/screens/dns_settings_screen/widgets/node_dns_tiles.dart';
import 'package:lxbox/services/dns/node_dns_records.dart';

/// §435 — read-only строки DNS-записей узлов на экране DNS Settings (спека
/// §9.2): подпись после подстановки, пометка «from node <тег>», без свитча;
/// выключенный узел — подсказка «node is disabled». Без словаря
/// `getLocalText.s` отдаёт английский ключ — сверяемся с ним.
void main() {
  const server = DnsServerInline(
    enabled: true,
    tag: 'home-ts-dns',
    body: {'type': 'tailscale', 'endpoint': 'home-ts'},
  );
  const rule = DnsRuleInline(
    name: '',
    rule: {
      'domain_suffix': ['.ts.net'],
      'server': 'home-ts-dns',
    },
  );

  Future<void> pump(WidgetTester t, List<Widget> children) => t.pumpWidget(
        MaterialApp(home: Scaffold(body: ListView(children: children))),
      );

  testWidgets('тайл сервера: подпись после подстановки, без свитча',
      (t) async {
    await pump(t, const [
      NodeDnsServerTile(
        record: NodeDnsServerRecord(
          nodeTag: 'home-ts',
          server: server,
          nodeEnabled: true,
        ),
      ),
    ]);
    expect(find.text('home-ts-dns'), findsOneWidget);
    expect(find.text('home-ts-dns · tailscale · home-ts'), findsOneWidget);
    expect(find.text('from node home-ts'), findsOneWidget);
    expect(find.byType(Switch), findsNothing);
    expect(find.text('Node'), findsOneWidget);
    expect(find.textContaining('node is disabled'), findsNothing);
  });

  testWidgets('выключенный узел: подсказка «node is disabled»', (t) async {
    await pump(t, const [
      NodeDnsServerTile(
        record: NodeDnsServerRecord(
          nodeTag: 'P off-ts',
          server: server,
          nodeEnabled: false,
        ),
      ),
    ]);
    expect(find.text('from node P off-ts · node is disabled'), findsOneWidget);
  });

  testWidgets('карточка правил: заголовок, превью, бейдж node, диалог по тапу',
      (t) async {
    await pump(t, const [
      NodeDnsRulesCard(
        records: [
          NodeDnsRuleRecord(nodeTag: 'home-ts', rule: rule, nodeEnabled: true),
          NodeDnsRuleRecord(
            nodeTag: 'off-ts',
            rule: DnsRuleInline(
              name: 'lan',
              rule: {'domain_suffix': ['.lan'], 'server': 'off-ts-dns'},
              enabled: false,
            ),
            nodeEnabled: false,
          ),
        ],
      ),
    ]);
    expect(find.text('From nodes · read-only, edited in the node'),
        findsOneWidget);
    // Безымянное правило — заголовок = тег узла.
    expect(find.text('home-ts'), findsOneWidget);
    expect(find.text('lan'), findsOneWidget);
    expect(find.byType(Switch), findsNothing);
    expect(find.text('node'), findsNWidgets(2));
    // Подзаголовок: превью тела после подстановки + подпись-источник.
    expect(
      find.text('domain_suffix: .ts.net · server: home-ts-dns · from node home-ts'),
      findsOneWidget,
    );
    expect(
      find.text(
          'domain_suffix: .lan · server: off-ts-dns · from node off-ts · node is disabled · disabled'),
      findsOneWidget,
    );
    // Тап → read-only диалог с телом и label источника «node».
    await t.tap(find.text('lan'));
    await t.pumpAndSettle();
    expect(find.byType(AlertDialog), findsOneWidget);
    expect(find.textContaining('"server": "off-ts-dns"'), findsOneWidget);
  });
}
