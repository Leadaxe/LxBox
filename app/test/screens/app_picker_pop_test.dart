import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lxbox/screens/app_picker_screen.dart';
import 'package:lxbox/services/l10n/l10n.dart';

/// §108 — системный back / predictive-жест в AppPickerScreen обязан
/// возвращать выбор (AppPickerResult) так же, как стрелка в AppBar.
/// Раньше PopScope с пустым handler'ом (canPop=true по умолчанию) попал
/// роут с result=null — caller (`_pickApps` в tun_apps_tab) молча
/// выкидывал селекцию.
void main() {
  const channel = MethodChannel('com.leadaxe.lxbox/methods');

  setUp(() {
    TestWidgetsFlutterBinding.ensureInitialized();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
      if (call.method == 'getInstalledApps') return <dynamic>[];
      return null;
    });
  });

  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null);
  });

  Widget host(void Function(AppPickerResult?) onResult) {
    return MaterialApp(
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      home: Builder(
        builder: (context) => TextButton(
          onPressed: () async {
            final r = await Navigator.push<AppPickerResult>(
              context,
              MaterialPageRoute(
                builder: (_) => const AppPickerScreen(selected: {'com.a'}),
              ),
            );
            onResult(r);
          },
          child: const Text('open'),
        ),
      ),
    );
  }

  testWidgets('системный back возвращает текущий выбор (§108)',
      (tester) async {
    AppPickerResult? result;
    var popped = false;
    await tester.pumpWidget(host((r) {
      result = r;
      popped = true;
    }));
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();

    // Системный back Android доставляет через maybePop.
    final navigator = tester.state<NavigatorState>(find.byType(Navigator));
    unawaited(navigator.maybePop());
    await tester.pumpAndSettle();

    expect(popped, isTrue, reason: 'picker должен попаться');
    expect(result, isNotNull, reason: '§108: back не должен терять выбор');
    expect(result!.packages, ['com.a']);
  });

  testWidgets('стрелка в AppBar возвращает выбор (поведение не изменилось)',
      (tester) async {
    AppPickerResult? result;
    await tester.pumpWidget(host((r) => result = r));
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();

    await tester.tap(find.byIcon(Icons.arrow_back));
    await tester.pumpAndSettle();

    expect(result, isNotNull);
    expect(result!.packages, ['com.a']);
  });
}
