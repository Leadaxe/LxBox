import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lxbox/models/direction.dart';
import 'package:lxbox/models/parser_config.dart';
import 'package:lxbox/models/server_list.dart';
import 'package:lxbox/screens/direction_edit_screen.dart';
import 'package:lxbox/services/builder/build_config.dart';
import 'package:lxbox/services/parser/uri_parsers.dart';

import '../parser/engine_test_setup.dart';

// §674 — превью фильтра в редакторе Направления строится от пула сборщика,
// туннель не нужен: снимка ядра в тесте нет вовсе, а превью показывает узлы.

Finder _nodeFilterField() =>
    find.widgetWithText(TextField, 'e.g. 🇩🇪|🇳🇱 — empty = all nodes');

Future<void> _pump(WidgetTester tester, Future<List<String>> pool) async {
  tester.view.physicalSize = const Size(900, 3000);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(MaterialApp(
    home: DirectionEditScreen(
      initial: const Direction(tag: 'vpn-2', label: 'X'),
      canDelete: true,
      nodePool: pool,
    ),
  ));
}

void main() {
  setUpAll(loadEngineSections);

  /// Пул так, как его посчитает приложение: тот же сборщик, без ядра.
  Future<List<String>> builderPool() => buildDirectionPool(
        lists: [
          UserServer(
            id: 'u',
            name: 'N',
            enabled: true,
            tagPrefix: '',
            detourPolicy: DetourPolicy.defaults,
            origin: UserSource.paste,
            nodes: [
              parseUri('vless://u1@h1.com:443?type=ws&security=tls#🇩🇪 Berlin')!,
              parseUri('vless://u2@h2.com:443?type=ws&security=tls#🇳🇱 Amsterdam')!,
              parseUri('vless://u3@h3.com:443?type=ws&security=tls#🇺🇸 NYC')!,
            ],
          ),
        ],
        template: WizardTemplate(
          groupTemplates: GroupTemplates(),
          vars: const [],
          varSections: const [],
          config: {
            'outbounds': [
              {'tag': 'direct-out', 'type': 'direct'},
            ],
            'route': {'rules': []},
          },
          selectableRules: const [],
          dnsOptions: const {},
          pingOptions: const {},
          speedTestOptions: const {},
        ),
        settings: const BuildSettings(
          directions: [Direction(tag: 'vpn-1', label: 'Main')],
        ),
      );

  testWidgets('без туннеля превью показывает узлы пула, не заглушку',
      (tester) async {
    final pool = (await tester.runAsync(builderPool))!;
    expect(pool, hasLength(3));
    await _pump(tester, Future.value(pool));
    await tester.pumpAndSettle();
    expect(find.text('matched: 3 / 3 nodes'), findsOneWidget);
    expect(find.textContaining('connect to preview'), findsNothing);

    await tester.enterText(_nodeFilterField(), '🇩🇪|🇳🇱');
    await tester.pump();
    expect(find.text('matched: 2 / 3 nodes'), findsOneWidget);

    await tester.enterText(_nodeFilterField(), 'Tokyo');
    await tester.pump();
    expect(find.text('No nodes match'), findsOneWidget);
  });

  testWidgets('пока пул считается — спиннер, затем счёт', (tester) async {
    final pending = Completer<List<String>>();
    await _pump(tester, pending.future);
    await tester.pump();
    expect(find.byType(CircularProgressIndicator), findsOneWidget);
    expect(find.textContaining('matched:'), findsNothing);
    expect(find.text('No nodes match'), findsNothing);

    pending.complete(const ['a', 'b']);
    await tester.pump();
    expect(find.byType(CircularProgressIndicator), findsNothing);
    expect(find.text('matched: 2 / 2 nodes'), findsOneWidget);
  });
}
