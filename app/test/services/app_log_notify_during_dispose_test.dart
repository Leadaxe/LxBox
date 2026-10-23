// §622 — запись в журнал из dispose() (экран приёма закрывает сессию и
// пишет «session closed») не дёргает слушателей при запертом дереве.

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

  test('notification is not synchronous with the write', () async {
    var notified = 0;
    void listener() => notified++;
    AppLog.I.addListener(listener);
    addTearDown(() => AppLog.I.removeListener(listener));
    await Future<void>.delayed(const Duration(milliseconds: 20));

    AppLog.I.info('a');
    expect(notified, 0);
    await Future<void>.delayed(Duration.zero);
    expect(notified, 1);
    // Записи в окне сливаются в одно уведомление в его конце.
    AppLog.I.info('b');
    AppLog.I.info('c');
    await Future<void>.delayed(const Duration(milliseconds: 40));
    expect(notified, 2);
  });
}
