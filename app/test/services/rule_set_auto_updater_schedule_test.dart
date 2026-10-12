// ignore_for_file: depend_on_referenced_packages

import 'package:fake_async/fake_async.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lxbox/services/rule_set_auto_updater.dart';

/// 004-ROUTING · P10 — расписание автообновления наборов: проход
/// планируется через 30 с после старта приложения или подъёма туннеля и
/// только на переднем плане; уход в фон отменяет запланированное.
/// Сам проход (`_run`) здесь не запускается — время не доматывается до
/// срабатывания таймера, сеть и диск не трогаются.
void main() {
  Duration? onlyTimer(FakeAsync async) {
    final timers = async.pendingTimers.toList();
    if (timers.isEmpty) return null;
    expect(timers, hasLength(1), reason: 'одна запланированная попытка');
    return timers.single.duration;
  }

  test('старт приложения → одна попытка через 30 с', () {
    fakeAsync((async) {
      final u = RuleSetAutoUpdater()..start();
      expect(onlyTimer(async), RuleSetAutoUpdater.appStartDelay);
      expect(RuleSetAutoUpdater.appStartDelay, const Duration(seconds: 30));
      u.dispose();
    });
  });

  test('подъём туннеля → одна попытка через 30 с', () {
    fakeAsync((async) {
      final u = RuleSetAutoUpdater()..onVpnConnected();
      expect(onlyTimer(async), RuleSetAutoUpdater.postVpnConnectedDelay);
      expect(RuleSetAutoUpdater.postVpnConnectedDelay,
          const Duration(seconds: 30));
      u.dispose();
    });
  });

  test('повторный триггер не плодит таймеры, а перепланирует', () {
    fakeAsync((async) {
      final u = RuleSetAutoUpdater()
        ..start()
        ..onVpnConnected();
      expect(onlyTimer(async), RuleSetAutoUpdater.postVpnConnectedDelay);
      u.dispose();
    });
  });

  test('уход в фон отменяет запланированную попытку', () {
    fakeAsync((async) {
      final u = RuleSetAutoUpdater()..start();
      u.onAppPaused();
      expect(onlyTimer(async), isNull);
      u.dispose();
    });
  });

  test('в фоне триггеры ничего не планируют; после возврата — планируют', () {
    fakeAsync((async) {
      final u = RuleSetAutoUpdater()..onAppPaused();
      u.start();
      u.onVpnConnected();
      expect(onlyTimer(async), isNull);

      u.onAppResumed();
      u.onVpnConnected();
      expect(onlyTimer(async), RuleSetAutoUpdater.postVpnConnectedDelay);
      u.dispose();
    });
  });

  test('dispose снимает таймер', () {
    fakeAsync((async) {
      final u = RuleSetAutoUpdater()..start();
      u.dispose();
      expect(onlyTimer(async), isNull);
    });
  });
}
