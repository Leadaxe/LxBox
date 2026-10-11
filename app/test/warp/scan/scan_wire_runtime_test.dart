// §834 — диагностика рантайм-ветки генерации WG-handshake: БЕЗ инъекции ключей
// (как в реальном скане). Если тут исключение — пакет не уходит в сокет вовсе,
// и скан даёт «нет трафика» на любом устройстве.

import 'package:flutter_test/flutter_test.dart';
import 'package:lxbox/services/warp/scan/scan_wire.dart';

void main() {
  test('buildWgInitiation с реальной генерацией ключей (рантайм-ветка)', () async {
    final pkt = await buildWgInitiation();
    expect(pkt.length, 148);
    expect(pkt[0], 1); // msg type 1 = initiation
  });

  test('два вызова дают разные пакеты (эфемерный ключ случаен)', () async {
    final a = await buildWgInitiation();
    final b = await buildWgInitiation();
    expect(a, isNot(equals(b)));
  });
}
