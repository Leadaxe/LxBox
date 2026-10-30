import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:lxbox/screens/dns_settings_screen/resolved_server.dart';
import 'package:lxbox/screens/dns_settings_screen/widgets/merged_server_tile.dart';

/// §680 — залоченный включённый сервер: свитч рисуется ON и активным,
/// тап показывает SnackBar «Locked: used by …» вместо переключения.
void main() {
  Future<List<bool>> pump(WidgetTester tester, ResolvedServer entry) async {
    final toggles = <bool>[];
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: MergedServerTile(
            entry: entry,
            onToggleEnabled: (_, v) => toggles.add(v),
            onTap: (_) {},
          ),
        ),
      ),
    );
    return toggles;
  }

  ResolvedServer server({
    required bool enabled,
    List<String> usedBy = const [],
  }) => ResolvedServer(
    kind: ServerKind.template,
    tag: 'google_doh',
    description: 'Google DoH',
    enabled: enabled,
    body: const {'type': 'https', 'tag': 'google_doh', 'server': '8.8.8.8'},
    usedByList: usedBy,
  );

  testWidgets('locked + enabled: switch ON and active, tap shows SnackBar', (
    tester,
  ) async {
    final toggles = await pump(
      tester,
      server(enabled: true, usedBy: ['dns_shield']),
    );
    final sw = tester.widget<Switch>(find.byType(Switch));
    expect(sw.value, isTrue);
    expect(sw.onChanged, isNotNull);

    await tester.tap(find.byType(Switch));
    await tester.pump();
    expect(toggles, isEmpty);
    expect(find.textContaining('Locked: used by dns_shield'), findsOneWidget);

    // Повторный тап не копит очередь — на экране по-прежнему один SnackBar.
    await tester.tap(find.byType(Switch));
    await tester.pump();
    expect(toggles, isEmpty);
    expect(find.byType(SnackBar), findsOneWidget);
  });

  testWidgets('locked + disabled: switch toggles as before', (tester) async {
    final toggles = await pump(
      tester,
      server(enabled: false, usedBy: ['dns_shield']),
    );
    await tester.tap(find.byType(Switch));
    await tester.pump();
    expect(toggles, [true]);
    expect(find.byType(SnackBar), findsNothing);
  });

  testWidgets('not locked: switch toggles as before', (tester) async {
    final toggles = await pump(tester, server(enabled: true));
    await tester.tap(find.byType(Switch));
    await tester.pump();
    expect(toggles, [false]);
  });

  // §695 — выключенная группа без живых членов: тап объясняет, не включает.
  ResolvedServer group({
    required bool enabled,
    int inList = 0,
    int live = 0,
  }) => ResolvedServer(
    kind: ServerKind.template,
    tag: 'dns_shield',
    description: 'Shield DNS',
    enabled: enabled,
    body: const {
      'type': 'group',
      'tag': 'dns_shield',
      'mode': 'fastest',
      'servers': ['a', 'b', 'c', 'd', 'e', 'f'],
    },
    groupMembersInList: inList,
    groupLiveMembers: live,
  );

  testWidgets('empty disabled group: tap shows SnackBar, no toggle', (
    tester,
  ) async {
    final toggles = await pump(tester, group(enabled: false, inList: 2));
    await tester.tap(find.byType(Switch));
    await tester.pump();
    expect(toggles, isEmpty);
    expect(find.byType(SnackBar), findsOneWidget);
  });

  testWidgets('disabled group with a live member toggles', (tester) async {
    final toggles = await pump(
      tester,
      group(enabled: false, inList: 2, live: 1),
    );
    await tester.tap(find.byType(Switch));
    await tester.pump();
    expect(toggles, [true]);
    expect(find.byType(SnackBar), findsNothing);
  });

  testWidgets('group subtitle counts members present in the list', (
    tester,
  ) async {
    await pump(tester, group(enabled: true, inList: 5, live: 5));
    expect(find.textContaining('dns_shield · group · fastest · 5'),
        findsOneWidget);
  });
}
