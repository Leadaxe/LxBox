import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lxbox/screens/home/home_dialogs.dart';
import 'package:lxbox/services/settings_storage.dart';

/// §528 — issue #126: диалог «Another VPN is active» (§211) показывался и в
/// proxy-режиме, где чужой туннель наш старт не трогает вовсе —
/// `VpnService.prepare()` там не зовётся (§192, гейт по `hasTun`). Два гейта
/// разошлись: prepare смотрел на режим, диалог — нет.
///
/// Здесь фиксируем оба конца: предикат режима и порядок обращений в гейте
/// (в proxy native вообще не опрашивается).
void main() {
  VpnModeConfig cfg(String mode) =>
      const VpnModeConfig.defaults().copyWith(mode: mode);

  group('§528 askBeforeOverridingForeignVpn', () {
    test('proxy (hasTun=false) → не спрашиваем', () {
      expect(askBeforeOverridingForeignVpn(hasTun: cfg('proxy').hasTun), isFalse);
    });

    test('vpn / vpn_proxy (hasTun=true) → спрашиваем как раньше', () {
      expect(askBeforeOverridingForeignVpn(hasTun: cfg('vpn').hasTun), isTrue);
      expect(askBeforeOverridingForeignVpn(hasTun: cfg('vpn_proxy').hasTun), isTrue);
    });
  });

  group('§528 confirmForeignVpnOverride', () {
    /// Прогон гейта на пустом экране: `context` нужен только для диалога,
    /// который здесь подменён, поэтому реального `showDialog` не случается.
    Future<
        ({bool allowed, int foreignChecks, int dialogs})> run(
      WidgetTester tester, {
      required String mode,
      required bool foreignActive,
      bool? dialogAnswer,
    }) async {
      var foreignChecks = 0;
      var dialogs = 0;
      late bool allowed;

      await tester.pumpWidget(MaterialApp(
        home: Builder(builder: (ctx) {
          return TextButton(
            onPressed: () async {
              allowed = await confirmForeignVpnOverride(
                context: ctx,
                loadVpnMode: () async => cfg(mode),
                isForeignVpnActive: () async {
                  foreignChecks++;
                  return foreignActive;
                },
                showDialogFn: (_) async {
                  dialogs++;
                  return dialogAnswer;
                },
              );
            },
            child: const Text('start'),
          );
        }),
      ));
      await tester.tap(find.text('start'));
      await tester.pumpAndSettle();
      return (allowed: allowed, foreignChecks: foreignChecks, dialogs: dialogs);
    }

    testWidgets('ГЛАВНЫЙ кейс: proxy + активен чужой VPN → ни опроса, ни диалога',
        (tester) async {
      final r = await run(tester, mode: 'proxy', foreignActive: true);
      expect(r.allowed, isTrue, reason: 'старт не должен блокироваться');
      expect(r.foreignChecks, 0, reason: 'native в proxy не опрашиваем вовсе');
      expect(r.dialogs, 0);
    });

    testWidgets('vpn + активен чужой VPN → диалог; Switch пускает старт',
        (tester) async {
      final r = await run(
        tester,
        mode: 'vpn',
        foreignActive: true,
        dialogAnswer: true,
      );
      expect(r.foreignChecks, 1);
      expect(r.dialogs, 1);
      expect(r.allowed, isTrue);
    });

    testWidgets('vpn + активен чужой VPN → Cancel отменяет старт',
        (tester) async {
      final r = await run(
        tester,
        mode: 'vpn',
        foreignActive: true,
        dialogAnswer: false,
      );
      expect(r.dialogs, 1);
      expect(r.allowed, isFalse);
    });

    testWidgets('vpn_proxy + активен чужой VPN → диалог (TUN есть)',
        (tester) async {
      final r = await run(
        tester,
        mode: 'vpn_proxy',
        foreignActive: true,
        dialogAnswer: true,
      );
      expect(r.foreignChecks, 1);
      expect(r.dialogs, 1);
      expect(r.allowed, isTrue);
    });

    testWidgets('vpn + чужого VPN нет → опрос был, диалога нет', (tester) async {
      final r = await run(tester, mode: 'vpn', foreignActive: false);
      expect(r.foreignChecks, 1);
      expect(r.dialogs, 0);
      expect(r.allowed, isTrue);
    });
  });
}
