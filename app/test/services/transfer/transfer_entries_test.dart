// §622 — где показываются пункты передачи (фича 031, P10).

import 'package:flutter_test/flutter_test.dart';
import 'package:lxbox/services/transfer/transfer_entries.dart';

void main() {
  test('TV: receive only, even with a camera', () {
    final e = transferEntriesFor(isTelevision: true, hasCamera: true);
    expect(e.receive, isTrue);
    expect(e.send, isFalse);
    final noCam = transferEntriesFor(isTelevision: true, hasCamera: false);
    expect(noCam.receive, isTrue);
    expect(noCam.send, isFalse);
  });

  test('not a TV → no receive item; send only with a camera', () {
    final phone = transferEntriesFor(isTelevision: false, hasCamera: true);
    expect(phone.receive, isFalse);
    expect(phone.send, isTrue);
    final noCam = transferEntriesFor(isTelevision: false, hasCamera: false);
    expect(noCam.receive, isFalse);
    expect(noCam.send, isFalse);
  });
}
