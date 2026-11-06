// §622 — запись в журнал из dispose() (экран приёма закрывает сессию и
// пишет «session closed») не дёргает слушателей при запертом дереве.

// ignore_for_file: depend_on_referenced_packages

import 'package:fake_async/fake_async.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lxbox/services/app_log.dart';

class _LogsOnDispose extends StatefulWidget {
  const _LogsOnDispose();

  @override
  State<_LogsOnDispose> createState() => _LogsOnDisposeState();
}

class _LogsOnDisposeState extends State<_LogsOnDispose> {
  @override
  void dispose() {
    AppLog.I.info('[test] closed in dispose');
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => const SizedBox();
}

void main() {
  setUp(AppLog.I.resetForTesting);

  testWidgets('log written in dispose reaches listeners after the frame', (
    tester,
  ) async {
    var builds = 0;
    Widget app({required bool child}) => MaterialApp(
      home: Column(
        children: [
          // Слушатель журнала, как экран лога и счётчик ошибок на главном.
          ListenableBuilder(
            listenable: AppLog.I,
            builder: (_, _) {
              builds++;
              return Text('${AppLog.I.entries.length}');
            },
          ),
          if (child) const _LogsOnDispose(),
        ],
      ),
    );

    await tester.pumpWidget(app(child: true));
    // Окно троттлинга от прошлых записей закрыто: уведомление — первое.
    await tester.pump(const Duration(milliseconds: 20));
    final before = builds;

    await tester.pumpWidget(app(child: false));
    expect(tester.takeException(), isNull);
    await tester.pump();
    expect(tester.takeException(), isNull);
    expect(AppLog.I.entries.first.message, '[test] closed in dispose');
    expect(builds, greaterThan(before), reason: 'listener still notified');

    await tester.pump(const Duration(milliseconds: 20));
  });

  // Fake time: на реальных таймерах окно (16 мс) и сон теста при опоздании
  // изолята срабатывали одной пачкой, и микрозадача с уведомлением шла уже
  // после проверки (§708).
  test('notification is not synchronous with the write', () {
    fakeAsync((async) {
      var notified = 0;
      void listener() => notified++;
      AppLog.I.addListener(listener);
      addTearDown(() => AppLog.I.removeListener(listener));

      AppLog.I.info('a');
      expect(notified, 0);
      async.flushMicrotasks();
      expect(notified, 1);
      // Записи в окне сливаются в одно уведомление в его конце.
      AppLog.I.info('b');
      AppLog.I.info('c');
      async.elapse(const Duration(milliseconds: 15));
      expect(notified, 1);
      async.elapse(const Duration(milliseconds: 1));
      expect(notified, 2);
      // Окно, открытое этим уведомлением, без новых записей гаснет молча.
      async.elapse(const Duration(milliseconds: 40));
      expect(notified, 2);
      expect(async.pendingTimers, isEmpty);
    });
  });
}
