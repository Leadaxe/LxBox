// §622 — предпросмотр восстановления с пульта (фича 031, P8): фокус в
// диалоге, стрелки двигают фокус, а не выбор Merge/Replace.

import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lxbox/screens/backup_screen.dart';
import 'package:lxbox/screens/backup_screen/import_preview_dialog.dart';
import 'package:lxbox/screens/transfer_receive_screen.dart';
import 'package:lxbox/services/backup_service.dart';
import 'package:lxbox/services/settings_storage.dart';
import 'package:lxbox/services/url_launcher.dart';

const _backup =
    '{"app":"lxbox","kind":"backup",'
    '"storage":{"storage_version":1,"vars":{"log_level":"info"}}}';

bool _focusInside(Finder f) {
  final ctx = FocusManager.instance.primaryFocus?.context;
  if (ctx == null) return false;
  final target = f.evaluate().single;
  var inside = identical(ctx, target);
  ctx.visitAncestorElements((e) {
    if (identical(e, target)) inside = true;
    return !inside;
  });
  return inside;
}

/// Предпросмотр сначала считает Merge по хранилищу (реальный I/O) — ждём
/// появления диалога, а не фиксированное время.
Future<void> _waitForDialog(WidgetTester tester) async {
  final dialog = find.byType(AlertDialog);
  for (var i = 0; i < 200 && dialog.evaluate().isEmpty; i++) {
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 10)),
    );
    await tester.pump();
  }
  await tester.pumpAndSettle();
  expect(dialog, findsOneWidget);
}

void main() {
  const utils = MethodChannel('com.leadaxe.lxbox/utils');
  const paths = MethodChannel('plugins.flutter.io/path_provider');
  late BackupContents contents;
  late Directory tmp;

  setUpAll(() async {
    contents = await const BackupService().parseImport(_backup);
  });

  setUp(() async {
    tmp = await Directory.systemTemp.createTemp('lxbox_dpad_focus_');
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(paths, (call) async => tmp.path);
    SettingsStorage.resetCacheForTesting();
    UrlLauncher.resetTelevisionCacheForTesting();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(utils, (call) async {
          return switch (call.method) {
            'isTelevision' => true,
            'hasCamera' => false,
            _ => null,
          };
        });
  });

  tearDown(() async {
    BackupScreen.openReceive = openTransferReceiveScreen;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(paths, null);
    SettingsStorage.resetCacheForTesting();
    if (tmp.existsSync()) await tmp.delete(recursive: true);
    UrlLauncher.resetTelevisionCacheForTesting();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(utils, null);
  });

  testWidgets('arrow down from Merge/Replace moves focus on to Import', (
    tester,
  ) async {
    expect(contents.availableCategories(), isNotEmpty);
    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (ctx) => Scaffold(
            body: TextButton(
              onPressed: () => showImportPreview(ctx, contents),
              child: const Text('open'),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('open'));
    await _waitForDialog(tester);

    final merge = find.ancestor(
      of: find.text('Merge with existing (recommended)'),
      matching: find.byType(RadioListTile<bool>),
    );
    final replace = find.ancestor(
      of: find.text('Replace all (destructive)'),
      matching: find.byType(RadioListTile<bool>),
    );
    final import = find.widgetWithText(FilledButton, 'Import');

    Focus.of(
      tester.element(find.text('Merge with existing (recommended)')),
    ).requestFocus();
    await tester.pump();
    expect(_focusInside(merge), isTrue);

    await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
    await tester.pumpAndSettle();
    expect(_focusInside(replace), isTrue, reason: 'down goes to Replace');
    expect(tester.widget<RadioListTile<bool>>(merge).value, isTrue);
    // Выбор не сменился: стрелка двигает фокус, а не радио.
    expect(
      tester.widget<RadioGroup<bool>>(find.byType(RadioGroup<bool>)).groupValue,
      isTrue,
    );

    var reached = false;
    for (var i = 0; i < 3 && !reached; i++) {
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
      await tester.pumpAndSettle();
      if (!_focusInside(import)) {
        await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
        await tester.pumpAndSettle();
      }
      reached = _focusInside(import);
    }
    expect(reached, isTrue, reason: 'Import reachable with arrows');
    expect(
      tester.widget<RadioGroup<bool>>(find.byType(RadioGroup<bool>)).groupValue,
      isTrue,
    );

    // Выбор — OK/Enter на радио.
    Focus.of(
      tester.element(find.text('Replace all (destructive)')),
    ).requestFocus();
    await tester.pump();
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pumpAndSettle();
    expect(
      tester.widget<RadioGroup<bool>>(find.byType(RadioGroup<bool>)).groupValue,
      isFalse,
    );
  });

  testWidgets(
    'receive from Backup: focus inside the preview, back on the card',
    (tester) async {
      BackupScreen.openReceive = (ctx) =>
          Navigator.of(ctx).push<BackupContents>(
            MaterialPageRoute(
              builder: (rctx) => Scaffold(
                body: OutlinedButton(
                  autofocus: true,
                  onPressed: () => Navigator.of(rctx).pop(contents),
                  child: const Text('received'),
                ),
              ),
            ),
          );
      // Хранилище уже в памяти, как на работающем TV: подсчёт Merge идёт без
      // I/O, диалог встаёт в том же кадре, что и перестройка экрана с busy.
      await tester.runAsync(SettingsStorage.getServerLists);
      // Backup открыт поверх главного, как в приложении: в тулбаре «Back».
      await tester.pumpWidget(
        MaterialApp(
          home: Builder(
            builder: (ctx) => Scaffold(
              body: TextButton(
                onPressed: () => Navigator.of(ctx).push(
                  MaterialPageRoute<void>(builder: (_) => const BackupScreen()),
                ),
                child: const Text('open backup'),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.text('open backup'));
      await tester.pumpAndSettle();

      final showCode = find.ancestor(
        of: find.text('Show code'),
        matching: find.byWidgetPredicate((w) => w is FilledButton),
      );
      // Пульт пришёл на карточку с «Back» тулбара: «Back» — в истории фокуса
      // экрана, и погашенная кнопка отдаёт фокус именно ему.
      Focus.of(tester.element(find.byType(BackButtonIcon))).requestFocus();
      await tester.pump();
      expect(_focusInside(find.byType(BackButton)), isTrue);
      Focus.of(tester.element(find.text('Show code'))).requestFocus();
      await tester.pump();
      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await tester.pumpAndSettle();
      expect(find.text('received'), findsOneWidget);

      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await _waitForDialog(tester);
      // Фокус у маршрута диалога (его scope), а не у экрана под ним; первая
      // стрелка уводит его на элемент диалога.
      final focused = FocusManager.instance.primaryFocus!.context!;
      expect(
        ModalRoute.of(focused),
        isA<DialogRoute<ImportDialogResult>>(),
        reason: 'preview dialog holds the focus',
      );
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
      await tester.pumpAndSettle();
      expect(
        _focusInside(find.byType(AlertDialog)),
        isTrue,
        reason: 'arrows move inside the dialog',
      );

      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pumpAndSettle();
      expect(find.byType(AlertDialog), findsNothing);
      expect(
        _focusInside(showCode),
        isTrue,
        reason: 'focus returns to the card after the dialog',
      );
    },
  );
}
