import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lxbox/screens/stats_screen/memory_detail_sheet.dart';
import 'package:lxbox/services/settings_storage.dart';

/// §705 (ядро lx.29, SPEC 148) — строка Core memory в шторке Memory:
/// дробь `/ N MB` при пресетном лимите, без дроби при Auto, скрыта при 0
/// (старое ядро без `memoryRuntime`).
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  // path_provider мокается каналом, как в native_prefs_memory_limit_test —
  // platform-interface пакетов нет в pubspec, analyze их не пропускает.
  const pathChannel = MethodChannel('plugins.flutter.io/path_provider');
  const methods = MethodChannel('com.leadaxe.lxbox/methods');
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  late Directory tempDir;

  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp('memory_sheet_');
    await Directory('${tempDir.path}/docs').create();
    await Directory('${tempDir.path}/support').create();
    messenger.setMockMethodCallHandler(pathChannel, (call) async {
      switch (call.method) {
        case 'getApplicationDocumentsDirectory':
        case 'getApplicationDocumentsPath':
          return '${tempDir.path}/docs';
        case 'getApplicationSupportDirectory':
        case 'getApplicationSupportPath':
          return '${tempDir.path}/support';
      }
      return null;
    });
    SettingsStorage.resetCacheForTesting();
    messenger.setMockMethodCallHandler(methods, (call) async => null);
  });

  tearDown(() async {
    messenger.setMockMethodCallHandler(pathChannel, null);
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

  testWidgets('zero (old core): Core memory row hidden', (tester) async {
    await setLimit(tester, '200');
    await openSheet(tester, coreRuntime: 0);
    // Заголовок группы — «CORE RUNTIME» в верхнем регистре, строки нет.
    expect(find.text('Core memory'), findsNothing);
    expect(find.textContaining(' / 200 MB'), findsNothing);
  });
}
