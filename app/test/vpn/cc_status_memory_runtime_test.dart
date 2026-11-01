import 'package:flutter_test/flutter_test.dart';

import 'package:lxbox/vpn/cc_channel.dart';

/// §705 (ядро lx.29, SPEC 148) — `memoryRuntime` в статусе: память
/// Go-рантайма ядра рядом с RSS процесса (`memory`); у старого ядра ключа
/// нет → 0.
void main() {
  test('missing memoryRuntime (old core) is 0', () {
    final s = CcStatus.fromMap({'memory': 1000});
    expect(s.memory, 1000);
    expect(s.memoryRuntime, 0);
  });
}
