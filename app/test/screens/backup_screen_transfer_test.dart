// §622 — пункты передачи на экране Backup (фича 031, P5, P10).

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lxbox/screens/backup_screen.dart';
import 'package:lxbox/services/url_launcher.dart';

void main() {
  const utils = MethodChannel('com.leadaxe.lxbox/utils');

  void device({required bool tv, required bool camera}) {
    UrlLauncher.resetTelevisionCacheForTesting();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(utils, (call) async {
      return switch (call.method) {
        'isTelevision' => tv,
        'hasCamera' => camera,
        _ => null,
      };
    });
  }

  tearDown(() {
    UrlLauncher.resetTelevisionCacheForTesting();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(utils, null);
  });

  Future<void> pump(WidgetTester tester) async {
    await tester.pumpWidget(const MaterialApp(home: BackupScreen()));
    await tester.pumpAndSettle();
  }

  testWidgets('categories sent default to everything except Debug API (P5)',
      (tester) async {
    device(tv: false, camera: true);
    await pump(tester);
    final debugTile = tester.widget<CheckboxListTile>(find.ancestor(
      of: find.text('Debug API config'),
      matching: find.byType(CheckboxListTile),
    ));
    expect(debugTile.value, isFalse);
    final serverTile = tester.widget<CheckboxListTile>(find.ancestor(
      of: find.text('Server lists'),
      matching: find.byType(CheckboxListTile),
    ));
    expect(serverTile.value, isTrue);
  });
}
