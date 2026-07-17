import 'dart:convert';
import 'dart:typed_data';

// §279 — SHA-256 (FIPS 180-4) на чистом Dart. Намеренно без package:crypto:
// tool/ не должен тянуть транзитивные зависимости (depend_on_referenced_packages).
// Корректность страхуется sha256SelfTest() при старте каждого checker'а.

const List<int> _k = [
  0x428a2f98, 0x71374491, 0xb5c0fbcf, 0xe9b5dba5, //
  0x3956c25b, 0x59f111f1, 0x923f82a4, 0xab1c5ed5,
  0xd807aa98, 0x12835b01, 0x243185be, 0x550c7dc3,
  0x72be5d74, 0x80deb1fe, 0x9bdc06a7, 0xc19bf174,
  0xe49b69c1, 0xefbe4786, 0x0fc19dc6, 0x240ca1cc,
  0x2de92c6f, 0x4a7484aa, 0x5cb0a9dc, 0x76f988da,
  0x983e5152, 0xa831c66d, 0xb00327c8, 0xbf597fc7,
  0xc6e00bf3, 0xd5a79147, 0x06ca6351, 0x14292967,
  0x27b70a85, 0x2e1b2138, 0x4d2c6dfc, 0x53380d13,
  0x650a7354, 0x766a0abb, 0x81c2c92e, 0x92722c85,
  0xa2bfe8a1, 0xa81a664b, 0xc24b8b70, 0xc76c51a3,
  0xd192e819, 0xd6990624, 0xf40e3585, 0x106aa070,
  0x19a4c116, 0x1e376c08, 0x2748774c, 0x34b0bcb5,
  0x391c0cb3, 0x4ed8aa4a, 0x5b9cca4f, 0x682e6ff3,
  0x748f82ee, 0x78a5636f, 0x84c87814, 0x8cc70208,
  0x90befffa, 0xa4506ceb, 0xbef9a3f7, 0xc67178f2,
];

const int _mask32 = 0xffffffff;

int _rotr(int x, int n) => ((x >> n) | (x << (32 - n))) & _mask32;

/// Hex-дайджест SHA-256 от UTF-8 представления [input].
String sha256Hex(String input) => sha256HexOfBytes(utf8.encode(input));

String sha256HexOfBytes(List<int> data) {
  final builder = BytesBuilder(copy: true)
    ..add(data)
    ..addByte(0x80);
  while (builder.length % 64 != 56) {
    builder.addByte(0);
  }
  final lenBytes = ByteData(8)..setUint64(0, data.length * 8, Endian.big);
  builder.add(lenBytes.buffer.asUint8List());
  final msg = builder.toBytes();

  final h = <int>[
    0x6a09e667, 0xbb67ae85, 0x3c6ef372, 0xa54ff53a, //
    0x510e527f, 0x9b05688c, 0x1f83d9ab, 0x5be0cd19,
  ];
  final w = List<int>.filled(64, 0);

  for (var i = 0; i < msg.length; i += 64) {
    for (var t = 0; t < 16; t++) {
      final o = i + 4 * t;
      w[t] = (msg[o] << 24) | (msg[o + 1] << 16) | (msg[o + 2] << 8) | msg[o + 3];
    }
    for (var t = 16; t < 64; t++) {
      final s0 = _rotr(w[t - 15], 7) ^ _rotr(w[t - 15], 18) ^ (w[t - 15] >> 3);
      final s1 = _rotr(w[t - 2], 17) ^ _rotr(w[t - 2], 19) ^ (w[t - 2] >> 10);
      w[t] = (w[t - 16] + s0 + w[t - 7] + s1) & _mask32;
    }
    var a = h[0], b = h[1], c = h[2], d = h[3];
    var e = h[4], f = h[5], g = h[6], hh = h[7];
    for (var t = 0; t < 64; t++) {
      final s1 = _rotr(e, 6) ^ _rotr(e, 11) ^ _rotr(e, 25);
      final ch = (e & f) ^ ((~e & _mask32) & g);
      final t1 = (hh + s1 + ch + _k[t] + w[t]) & _mask32;
      final s0 = _rotr(a, 2) ^ _rotr(a, 13) ^ _rotr(a, 22);
      final maj = (a & b) ^ (a & c) ^ (b & c);
      final t2 = (s0 + maj) & _mask32;
      hh = g;
      g = f;
      f = e;
      e = (d + t1) & _mask32;
      d = c;
      c = b;
      b = a;
      a = (t1 + t2) & _mask32;
    }
    h[0] = (h[0] + a) & _mask32;
    h[1] = (h[1] + b) & _mask32;
    h[2] = (h[2] + c) & _mask32;
    h[3] = (h[3] + d) & _mask32;
    h[4] = (h[4] + e) & _mask32;
    h[5] = (h[5] + f) & _mask32;
    h[6] = (h[6] + g) & _mask32;
    h[7] = (h[7] + hh) & _mask32;
  }
  return h.map((x) => x.toRadixString(16).padLeft(8, '0')).join();
}

/// Известный тест-вектор из FIPS 180-4; зовётся при старте каждого checker'а —
/// цена микросекунды, зато hash-контракт (src-hash, baseline) не может тихо
/// разъехаться из-за опечатки в константах.
void sha256SelfTest() {
  const expected =
      'ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad';
  if (sha256Hex('abc') != expected) {
    throw StateError('sha256 self-test failed');
  }
}
