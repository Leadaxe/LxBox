// ignore_for_file: depend_on_referenced_packages

import 'package:flutter_test/flutter_test.dart';
import 'package:lxbox/services/probe/probe_lifecycle.dart';

/// §286 — реестр отмены пробирования: register/deregister/haltAll.
void main() {
  tearDown(() {
    // Singleton — чистим между тестами, чтобы состояние не протекало.
    ProbeLifecycle.I.haltAll();
  });

  test('register → isProbing; haltAll дёргает cancel и очищает', () {
    var cancelled = 0;
    ProbeLifecycle.I.register(() => cancelled++);
    expect(ProbeLifecycle.I.isProbing, isTrue);

    ProbeLifecycle.I.haltAll();

    expect(cancelled, 1);
    expect(ProbeLifecycle.I.isProbing, isFalse);
  });

  test('haltAll дёргает ВСЕ зарегистрированные отменители', () {
    var a = 0, b = 0;
    ProbeLifecycle.I.register(() => a++);
    ProbeLifecycle.I.register(() => b++);

    ProbeLifecycle.I.haltAll();

    expect(a, 1);
    expect(b, 1);
    expect(ProbeLifecycle.I.isProbing, isFalse);
  });

  test('deregister снимает отменитель — haltAll его не трогает', () {
    var cancelled = 0;
    final canceller = ProbeLifecycle.I.register(() => cancelled++);
    ProbeLifecycle.I.deregister(canceller);
    expect(ProbeLifecycle.I.isProbing, isFalse);

    ProbeLifecycle.I.haltAll();

    expect(cancelled, 0);
  });

  test('haltAll на пустом реестре — no-op (идемпотентно)', () {
    expect(ProbeLifecycle.I.isProbing, isFalse);
    ProbeLifecycle.I.haltAll(); // не бросает
    expect(ProbeLifecycle.I.isProbing, isFalse);
  });

  test('cancel, синхронно снимающий себя через deregister, не ломает обход', () {
    // Реальный сценарий: FolderProbeRunner.run() finally зовёт deregister из
    // того же тика, что haltAll → мутация набора при обходе. haltAll берёт
    // снимок, поэтому это безопасно.
    var cancelled = 0;
    late final void Function() self;
    self = () {
      cancelled++;
      ProbeLifecycle.I.deregister(self);
    };
    ProbeLifecycle.I.register(self);

    ProbeLifecycle.I.haltAll();

    expect(cancelled, 1);
    expect(ProbeLifecycle.I.isProbing, isFalse);
  });
}
