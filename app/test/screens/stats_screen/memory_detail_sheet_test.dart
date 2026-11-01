import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lxbox/models/memory_limit_setting.dart';
import 'package:lxbox/screens/stats_screen/memory_detail_sheet.dart';
import 'package:lxbox/services/settings_storage.dart';
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';
import 'package:plugin_platform_interface/plugin_platform_interface.dart';

/// §705 (ядро lx.29, SPEC 148) — строка Core memory в шторке Memory:
/// дробь `/ N MB` при пресетном лимите, без дроби при Auto, скрыта при 0
/// (старое ядро без `memoryRuntime`).
class _FakePathProvider extends PathProviderPlatform
    with MockPlatformInterfaceMixin {
  final String tempRoot;
  _FakePathProvider(this.tempRoot);
  @override
  Future<String?> getApplicationSupportPath() async => '$tempRoot/support';
  @override
  Future<String?> getApplicationDocumentsPath() async => '$tempRoot/docs';
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const methods = MethodChannel('com.leadaxe.lxbox/methods');
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  late Directory tempDir;

  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp('memory_sheet_');
    await Directory('${tempDir.path}/docs').create();
    await Directory('${tempDir.path}/support').create();
    PathProviderPlatform.instance = _FakePathProvider(tempDir.path);
    SettingsStorage.resetCacheForTesting();
    messenger.setMockMethodCallHandler(methods, (call) async => null);
  });

  tearDown(() async {
    messenger.setMockMethodCallHandler(methods, null);
    if (await tempDir.exists()) await tempDir.delete(recursive: true);
  });

  // Запись прогревает кэш SettingsStorage — шторка читает лимит без диска.
  Future<void> setLimit(WidgetTester tester, String limit) async {
    await tester.runAsync(() => SettingsStorage.setNativeMemoryLimit(limit));
  }

  Future<void> openSheet(WidgetTester tester, {required int coreRuntime}) async {
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: Builder(
          builder: (context) => TextButton(
            onPressed: () => showMemoryDetailSheet(
              context,
              rss: 461 * 1024 * 1024,
              coreRuntime: coreRuntime,
              goroutines: 10,
              connectionsIn: 1,
              connectionsOut: 1,
            ),
            child: const Text('open'),
          ),
        ),
      ),
    ));
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
  }

  testWidgets('preset limit: Core memory shows used / limit', (tester) async {
    await setLimit(tester, '200');
    await openSheet(tester, coreRuntime: 42 * 1024 * 1024);
    expect(find.text('Core memory'), findsOneWidget);
    expect(find.text('42.0 MB / 200 MB'), findsOneWidget);
  });

  testWidgets('auto: Core memory without a fraction', (tester) async {
    await setLimit(tester, MemoryLimitSetting.auto);
    await openSheet(tester, coreRuntime: 42 * 1024 * 1024);
    expect(find.text('Core memory'), findsOneWidget);
    expect(find.text('42.0 MB'), findsOneWidget);
    expect(find.textContaining(' / '), findsNothing);
  });

  testWidgets('zero (old core): Core memory row hidden', (tester) async {
    await setLimit(tester, '200');
    await openSheet(tester, coreRuntime: 0);
    // Заголовок группы — «CORE RUNTIME» в верхнем регистре, строки нет.
    expect(find.text('Core memory'), findsNothing);
    expect(find.textContaining(' / 200 MB'), findsNothing);
  });
}
