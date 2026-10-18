// ignore_for_file: depend_on_referenced_packages

import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lxbox/models/tls_policy.dart';
import 'package:lxbox/services/settings_storage.dart';
import 'package:lxbox/widgets/tls_policy_tiles.dart';
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';
import 'package:plugin_platform_interface/plugin_platform_interface.dart';

class _FakePathProvider extends PathProviderPlatform
    with MockPlatformInterfaceMixin {
  final String tempRoot;
  _FakePathProvider(this.tempRoot);
  @override
  Future<String?> getApplicationSupportPath() async => '$tempRoot/support';
  @override
  Future<String?> getApplicationDocumentsPath() async => '$tempRoot/docs';
}

// §664 — у REALITY-узла глобальная фрагментация не наследуется: подпись
// «Default» не должна говорить «On — global».
void main() {
  late Directory tempDir;

  setUp(() async {
    TestWidgetsFlutterBinding.ensureInitialized();
    tempDir = await Directory.systemTemp.createTemp('tls_tiles_reality_');
    await Directory('${tempDir.path}/docs').create();
    await Directory('${tempDir.path}/support').create();
    PathProviderPlatform.instance = _FakePathProvider(tempDir.path);
    SettingsStorage.resetCacheForTesting();
  });

  tearDown(() async {
    try {
      if (tempDir.existsSync()) await tempDir.delete(recursive: true);
    } on FileSystemException {
      // ignore
    }
  });

  String subtitleOf(WidgetTester tester, String key) {
    final tile = tester.widget<ListTile>(find.byKey(ValueKey('tls-$key')));
    return (tile.subtitle! as Text).data!;
  }

  Future<void> pumpTiles(WidgetTester tester, {required bool reality}) async {
    await tester.runAsync(() async {
      await SettingsStorage.setVar('tls_record_fragment', 'true');
      await SettingsStorage.setVar('tls_mixed_case_sni', 'true');
    });
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: TlsPolicyTiles(
          policy: TlsPolicy.none,
          reality: reality,
          onChanged: (_) {},
        ),
      ),
    ));
    // Глобальные vars читаются асинхронно — ждать подписи «On — global»
    // у поля, на которое REALITY не влияет.
    for (var i = 0;
        i < 300 &&
            subtitleOf(tester, 'mixed_case_sni') != 'Default (On — global)';
        i++) {
      await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 10)));
      await tester.pump();
    }
    expect(subtitleOf(tester, 'mixed_case_sni'), 'Default (On — global)');
  }

  testWidgets('REALITY: глобальный record_fragment не показан как On',
      (tester) async {
    await pumpTiles(tester, reality: true);
    expect(subtitleOf(tester, 'record_fragment'),
        'Default (Off — not inherited by REALITY)');
    expect(subtitleOf(tester, 'fragment'),
        'Default (Off — not inherited by REALITY)');

    await tester.tap(find.byKey(const ValueKey('tls-record_fragment')));
    await tester.pumpAndSettle();
    expect(
        find.text(
            'Inherited: Off (REALITY ignores global, folder and subscription levels)'),
        findsOneWidget);
  });

  testWidgets('не REALITY: подпись наследования как раньше', (tester) async {
    await pumpTiles(tester, reality: false);
    expect(subtitleOf(tester, 'record_fragment'), 'Default (On — global)');
    expect(subtitleOf(tester, 'fragment'), 'Default (Off — global)');
  });
}
