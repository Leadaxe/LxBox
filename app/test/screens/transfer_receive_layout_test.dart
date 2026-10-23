// §622 — экран приёма на TV (фича 031, P8): всё помещается в окно без
// прокрутки, кнопки видны, белое поле QR не уходит под AppBar.

import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lxbox/screens/transfer_receive_screen.dart';
import 'package:lxbox/services/transfer/transfer_receiver.dart';

/// QR версии 7 (45×45) — порядок размера реального кода передачи.
({int side, List<bool> dark}) _fakeQr(String _) =>
    (side: 45, dark: List<bool>.generate(45 * 45, (i) => i.isEven));

Future<void> _pumpWaiting(WidgetTester tester) async {
  await tester.pumpWidget(const MaterialApp(home: TransferReceiveScreen()));
  // Сервер слушает реальный сокет — ждём появления кода, а не время.
  final qr = find.byKey(TransferReceiveScreen.qrKey);
  for (var i = 0; i < 200 && qr.evaluate().isEmpty; i++) {
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 10)),
    );
    await tester.pump();
  }
  await tester.pumpAndSettle(const Duration(milliseconds: 100));
  expect(qr, findsOneWidget);
}

Future<void> _dispose(WidgetTester tester) async {
  await tester.pumpWidget(const SizedBox());
  // Закрытие сервера — реальный I/O.
  await tester.runAsync(
    () => Future<void>.delayed(const Duration(milliseconds: 50)),
  );
  // Таймауты закрытия и окно троттлинга журнала — фейковые таймеры.
  await tester.pump(const Duration(seconds: 3));
}

void main() {
  setUp(() {
    TransferReceiveScreen.addresses = () async => ['192.168.1.20'];
    TransferReceiveScreen.openReceiver = () =>
        TransferReceiver.open(bindAddress: InternetAddress.loopbackIPv4);
    TransferReceiveScreen.encodeQr = _fakeQr;
  });

  tearDown(() {
    TransferReceiveScreen.addresses = localTransferAddresses;
    TransferReceiveScreen.openReceiver = TransferReceiver.open;
  });

  Rect checkFits(WidgetTester tester, Size screen) {
    expect(tester.takeException(), isNull, reason: 'no overflow');
    final window = Offset.zero & screen;
    for (final label in ['Cancel', 'New code']) {
      final button = find.ancestor(
        of: find.text(label),
        matching: find.byWidgetPredicate((w) => w is ButtonStyleButton),
      );
      final r = tester.getRect(button);
      expect(
        window.contains(r.topLeft) &&
            window.contains(r.bottomRight - const Offset(0.01, 0.01)),
        isTrue,
        reason: '$label $r inside $screen',
      );
    }
    final qr = tester.getRect(find.byKey(TransferReceiveScreen.qrKey));
    final appBar = tester.getRect(find.byType(AppBar));
    expect(
      qr.top,
      greaterThanOrEqualTo(appBar.bottom),
      reason: 'QR $qr under AppBar $appBar',
    );
    expect(qr.bottom, lessThanOrEqualTo(screen.height));
    expect(qr.right, lessThanOrEqualTo(screen.width));
    // Прокручиваться может только текст подписей (запас на крайний случай;
    // шрифт тестов шире настоящего): QR и кнопки — никогда.
    for (final f in [
      find.byKey(TransferReceiveScreen.qrKey),
      find.text('Cancel'),
      find.text('New code'),
    ]) {
      expect(
        find.ancestor(of: f, matching: find.byType(Scrollable)),
        findsNothing,
      );
    }
    return qr;
  }

  Future<Rect> run(WidgetTester tester, Size physical) async {
    tester.view.physicalSize = physical;
    tester.view.devicePixelRatio = 2.0;
    addTearDown(tester.view.reset);
    await _pumpWaiting(tester);
    final qr = checkFits(tester, physical / 2.0);
    // Автофокус пульта — на Cancel, и он виден.
    final focused = FocusManager.instance.primaryFocus!.context!;
    expect(
      find
          .ancestor(
            of: find.byElementPredicate((e) => identical(e, focused)),
            matching: find.byType(OutlinedButton),
          )
          .evaluate()
          .isNotEmpty,
      isTrue,
    );
    await _dispose(tester);
    return qr;
  }

  testWidgets('TV 1920x1080 @2.0: landscape window', (tester) async {
    final qr = await run(tester, const Size(1920, 1080));
    // Здесь всё помещалось и раньше — размер QR прежний: 0,75 высоты окна.
    expect(qr.width, closeTo((540 - 56) * 0.75, 0.5));
  });

  testWidgets('TV with portrait lock: narrow column 608x1080 @2.0', (
    tester,
  ) async {
    final qr = await run(tester, const Size(608, 1080));
    expect(qr.width, greaterThan(0));
  });
}
