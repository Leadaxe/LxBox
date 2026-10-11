// §834 — golden-вектор Dart-порта WG handshake-initiation. Эталон сгенерирован
// независимо (Python + cryptography) и сверяется байт-в-байт: если X25519 /
// ChaCha20-Poly1305 / BLAKE2s / KDF разойдутся с WG-спецификацией, тест упадёт.

import 'package:flutter_test/flutter_test.dart';
import 'package:lxbox/services/warp/scan/scan_wire.dart';

List<int> _hex(String s) {
  final out = <int>[];
  for (var i = 0; i < s.length; i += 2) {
    out.add(int.parse(s.substring(i, i + 2), radix: 16));
  }
  return out;
}

String _toHex(List<int> b) =>
    b.map((x) => x.toRadixString(16).padLeft(2, '0')).join();

void main() {
  test(
    'buildWgInitiation matches the reference vector byte-for-byte',
    () async {
      final pkt = await buildWgInitiation(
        serverPubRaw: _hex(
          '8f40c5adb68f25624ae5b214ea767a6ec94d829d3d7b5e1ad1ba6f3e2138285f',
        ),
        staticPrivRaw: _hex(
          '202122232425262728292a2b2c2d2e2f303132333435363738393a3b3c3d3e3f',
        ),
        ephPrivRaw: _hex(
          '404142434445464748494a4b4c4d4e4f505152535455565758595a5b5c5d5e5f',
        ),
        tai64nBytes: _hex('400000006553f100075bcd15'),
        senderIndex: 0x0A0B0C0D,
      );

      expect(pkt.length, 148);
      expect(
        _toHex(pkt),
        '010000000d0c0b0a'
        '79a631eede1bf9c98f12032cdeadd0e7a079398fc786b88cc846ec89af85a51a'
        '7ddcb8b744a022c9c8782384accd9e666f2102ba530a639e23b548c75c041cd0'
        '54cdd371b0e363181bc1652b98c9625a'
        'b47e11a887604bab0b37f27c154a71076e1116565bfdb55117a84329'
        'ec89f09d6ef294be4d01df9fae7c6d97'
        '00000000000000000000000000000000',
      );
    },
  );

  test('classifyWgResponse maps wire responses correctly', () {
    expect(classifyWgResponse(null).kind, WgProbeKind.timeout);
    expect(classifyWgResponse(<int>[]).kind, WgProbeKind.timeout);
    expect(
      classifyWgResponse([2, ...List.filled(91, 0)]).kind,
      WgProbeKind.response,
    );
    expect(classifyWgResponse([2, ...List.filled(91, 0)]).alive, isTrue);
    expect(
      classifyWgResponse([3, ...List.filled(63, 0)]).kind,
      WgProbeKind.cookie,
    );
    expect(classifyWgResponse([1, 2, 3]).kind, WgProbeKind.junk);
    // 92 байта, но не type-2 — не принимаем за response.
    expect(
      classifyWgResponse([9, ...List.filled(91, 0)]).kind,
      WgProbeKind.junk,
    );
  });

  // §837 — РЕГРЕССИЯ на реальную причину «сканер не находит рабочие»:
  // живой сервер отвечает на handshake initiation типом 2 (Handshake Response,
  // 92 Б), а НЕ типом 4 (Transport Data). Старый код требовал type == 4,
  // поэтому все живые ответы уходили в junk и валидных было ноль.
  group('§837 типы сообщений WireGuard (спецификация)', () {
    test('type 2 (Handshake Response, 92 Б) — эндпоинт ЖИВОЙ', () {
      final r = classifyWgResponse([2, ...List.filled(91, 0)], rttMs: 42);
      expect(r.kind, WgProbeKind.response);
      expect(r.alive, isTrue);
      expect(r.strict, isTrue, reason: 'это полноценный handshake response');
      expect(r.rttMs, 42);
      expect(r.detail, contains('type2'));
      expect(r.detail, contains('92B'));
    });

    test('type 4 (Transport Data, 92 Б) — НЕ ответ на handshake → junk', () {
      final r = classifyWgResponse([4, ...List.filled(91, 0)]);
      expect(r.kind, WgProbeKind.junk);
      expect(r.alive, isFalse,
          reason: 'сервер не может слать transport data до handshake');
      expect(r.detail, contains('type=4'));
      expect(r.detail, contains('ждали type=2'),
          reason: 'журнал должен объяснять, чего не хватило');
    });

    test('type 1 (наше же эхо, 148 Б) — junk с подсказкой про эхо', () {
      final r = classifyWgResponse([1, ...List.filled(147, 0)]);
      expect(r.kind, WgProbeKind.junk);
      expect(r.detail, contains('echo'));
    });

    test('type 3 (Cookie Reply, 64 Б) — сервер под нагрузкой, но ЖИВОЙ', () {
      final r = classifyWgResponse([3, ...List.filled(63, 0)]);
      expect(r.kind, WgProbeKind.cookie);
      expect(r.alive, isTrue);
      expect(r.strict, isFalse);
    });

    test('правильный тип, но неверная длина — junk', () {
      expect(classifyWgResponse([2, ...List.filled(50, 0)]).kind,
          WgProbeKind.junk);
      expect(classifyWgResponse([3, ...List.filled(91, 0)]).kind,
          WgProbeKind.junk);
    });
  });
}
