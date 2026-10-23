import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:lxbox/models/dns_ref.dart';
import 'package:lxbox/screens/dns_settings_screen/dns_server_catalog_screen.dart';

/// §680 — страница «Add DNS server»: каталог шаблона, Add / Added,
/// «Add all defaults».
void main() {
  final templateServers = <Map<String, dynamic>>[
    {
      'description': 'Google DNS (direct)',
      'enabled': true,
      'vars': [
        {'name': 'dns_ip', 'type': 'enum', 'default_value': '8.8.8.8'},
      ],
      'server': {'type': 'udp', 'tag': 'google_udp', 'server': '@dns_ip'},
    },
    {
      'description': 'OpenDNS UDP (direct)',
      'enabled': true,
      'server': {
        'type': 'udp',
        'tag': 'opendns_udp',
        'server': '208.67.222.222',
      },
    },
    {
      'description': 'Safe DNS (DoT)',
      'enabled': false,
      'server': {'type': 'tls', 'tag': 'safe_dns_dot', 'server': '9.9.9.9'},
    },
  ];

  Future<List<DnsServerTemplate>> pump(
    WidgetTester tester, {
    Set<String> present = const {'google_udp'},
  }) async {
    final added = <DnsServerTemplate>[];
    await tester.pumpWidget(MaterialApp(
      home: DnsServerCatalogScreen(
        templateServers: templateServers,
        presentTags: present,
        onAdd: added.addAll,
      ),
    ));
    return added;
  }

  Finder rowButton(String tag) => find.descendant(
        of: find.byKey(ValueKey('dns-catalog-$tag')),
        matching: find.byType(TextButton),
      );

  testWidgets('строки каталога: Added у присутствующих, адрес var дефолтом',
      (tester) async {
    await pump(tester);
    expect(find.text('Add DNS server'), findsOneWidget);
    expect(find.text('Custom server'), findsOneWidget);
    expect(find.text('FROM TEMPLATE'), findsOneWidget);
    expect(find.text('google_udp · udp · 8.8.8.8'), findsOneWidget);
    expect(tester.widget<TextButton>(rowButton('google_udp')).onPressed,
        isNull);
    expect(
        find.descendant(
            of: find.byKey(const ValueKey('dns-catalog-google_udp')),
            matching: find.text('Added')),
        findsOneWidget);
    expect(tester.widget<TextButton>(rowButton('opendns_udp')).onPressed,
        isNotNull);
  });

  testWidgets('Add добавляет запись с enabled шаблона, кнопка → Added',
      (tester) async {
    final added = await pump(tester);
    await tester.tap(rowButton('safe_dns_dot'));
    await tester.pump();
    expect(added, [const DnsServerTemplate(enabled: false, tag: 'safe_dns_dot')]);
    expect(tester.widget<TextButton>(rowButton('safe_dns_dot')).onPressed,
        isNull);
    expect(find.text('Added "Safe DNS (DoT)"'), findsOneWidget);
    // Страница остаётся открытой.
    expect(find.text('Add DNS server'), findsOneWidget);
  });

  testWidgets('Add all defaults досевает отсутствующие; повтор — сообщение',
      (tester) async {
    final added = await pump(tester);
    await tester.tap(find.byType(PopupMenuButton<String>));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Add all defaults'));
    await tester.pumpAndSettle();
    expect(added, [
      const DnsServerTemplate(enabled: true, tag: 'opendns_udp'),
      const DnsServerTemplate(enabled: false, tag: 'safe_dns_dot'),
    ]);
    expect(find.text('Added 2 servers'), findsOneWidget);

    await tester.tap(find.byType(PopupMenuButton<String>));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Add all defaults'));
    await tester.pumpAndSettle();
    expect(added.length, 2);
    expect(find.text('All defaults are already in the list'), findsOneWidget);
  });

  testWidgets('Custom server закрывает страницу с результатом custom',
      (tester) async {
    DnsServerCatalogResult? result;
    await tester.pumpWidget(MaterialApp(
      home: Builder(
        builder: (context) => TextButton(
          onPressed: () async {
            result = await Navigator.of(context).push(MaterialPageRoute(
              builder: (_) => DnsServerCatalogScreen(
                templateServers: templateServers,
                presentTags: const {},
                onAdd: (_) {},
              ),
            ));
          },
          child: const Text('open'),
        ),
      ),
    ));
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    final customRow = find.ancestor(
        of: find.text('Custom server'), matching: find.byType(Row));
    await tester.tap(find.descendant(
        of: customRow.first, matching: find.byType(TextButton)));
    await tester.pumpAndSettle();
    expect(result, DnsServerCatalogResult.custom);
  });
}
