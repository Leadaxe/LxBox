// §136 — минимальный синхронный AES-128 для QUIC Initial генератора (i1).
//
// Нужны ровно две операции из RFC 9001:
//   1. encryptBlock — один 16-байтовый ECB-блок (header protection mask).
//   2. AES-128-GCM (encrypt) — шифрование QUIC payload.
//
// Почему свой, а не `package:cryptography`: тот async (Future) и громоздкий для
// побайтовой сборки пакета; QUIC i1 собирается синхронно. Это compact textbook
// AES-128 + GCM, покрыт тестами против известных QUIC-векторов (RFC 9001 A.x).

/// AES-128 (только шифрование блока) + GCM. Ключ — 16 байт.
class AesMin {
  AesMin(List<int> key) {
    assert(key.length == 16, 'AES-128 key must be 16 bytes');
    _expandKey(key);
  }

  static final List<int> _sbox = _buildSbox();
  static final List<int> _rcon = [
    0x01, 0x02, 0x04, 0x08, 0x10, 0x20, 0x40, 0x80, 0x1b, 0x36,
  ];

  // 11 round keys × 16 байт = 176.
  late final List<int> _rk;

  void _expandKey(List<int> key) {
    final rk = List<int>.from(key);
    var rconIdx = 0;
    while (rk.length < 176) {
      final t = rk.sublist(rk.length - 4);
      if (rk.length % 16 == 0) {
        // RotWord + SubWord + Rcon
        final tmp = t[0];
        t[0] = _sbox[t[1]] ^ _rcon[rconIdx++];
        t[1] = _sbox[t[2]];
        t[2] = _sbox[t[3]];
        t[3] = _sbox[tmp];
      }
      for (var i = 0; i < 4; i++) {
        rk.add(rk[rk.length - 16] ^ t[i]);
      }
    }
    _rk = rk;
  }

  static int _xtime(int x) => ((x << 1) ^ ((x >> 7) * 0x1b)) & 0xff;

  /// Шифрует один 16-байтовый блок. Возвращает новый список из 16 байт.
  List<int> encryptBlock(List<int> input) {
    final s = List<int>.from(input.sublist(0, 16));
    _addRoundKey(s, 0);
    for (var round = 1; round < 10; round++) {
      _subBytes(s);
      _shiftRows(s);
      _mixColumns(s);
      _addRoundKey(s, round);
    }
    _subBytes(s);
    _shiftRows(s);
    _addRoundKey(s, 10);
    return s;
  }

  void _addRoundKey(List<int> s, int round) {
    final off = round * 16;
    for (var i = 0; i < 16; i++) {
      s[i] ^= _rk[off + i];
    }
  }

  void _subBytes(List<int> s) {
    for (var i = 0; i < 16; i++) {
      s[i] = _sbox[s[i]];
    }
  }

  void _shiftRows(List<int> s) {
    final t = List<int>.from(s);
    // column-major state; row r shifted left by r.
    s[1] = t[5];
    s[5] = t[9];
    s[9] = t[13];
    s[13] = t[1];
    s[2] = t[10];
    s[6] = t[14];
    s[10] = t[2];
    s[14] = t[6];
    s[3] = t[15];
    s[7] = t[3];
    s[11] = t[7];
    s[15] = t[11];
  }

  void _mixColumns(List<int> s) {
    for (var c = 0; c < 4; c++) {
      final i = c * 4;
      final a0 = s[i], a1 = s[i + 1], a2 = s[i + 2], a3 = s[i + 3];
      s[i] = _xtime(a0) ^ (_xtime(a1) ^ a1) ^ a2 ^ a3;
      s[i + 1] = a0 ^ _xtime(a1) ^ (_xtime(a2) ^ a2) ^ a3;
      s[i + 2] = a0 ^ a1 ^ _xtime(a2) ^ (_xtime(a3) ^ a3);
      s[i + 3] = (_xtime(a0) ^ a0) ^ a1 ^ a2 ^ _xtime(a3);
    }
  }

  // ── GCM ──────────────────────────────────────────────────────────────────

  /// AES-128-GCM encrypt. Возвращает ciphertext||tag (tag = 16 байт).
  /// `iv` = 12 байт (QUIC всегда 96-bit nonce).
  List<int> gcmEncrypt(List<int> iv, List<int> plaintext, List<int> aad) {
    assert(iv.length == 12);
    final h = encryptBlock(List<int>.filled(16, 0));
    // J0 = IV || 0x00000001
    final j0 = <int>[...iv, 0, 0, 0, 1];
    // CTR начинается с J0+1.
    final ct = <int>[];
    var counter = List<int>.from(j0);
    for (var off = 0; off < plaintext.length; off += 16) {
      _incr32(counter);
      final ks = encryptBlock(counter);
      final n = (plaintext.length - off) < 16 ? plaintext.length - off : 16;
      for (var i = 0; i < n; i++) {
        ct.add(plaintext[off + i] ^ ks[i]);
      }
    }
    // GHASH над AAD || CT || len(AAD)||len(CT).
    final tag = _ghashTag(h, aad, ct, j0);
    return [...ct, ...tag];
  }

  void _incr32(List<int> block) {
    for (var i = 15; i >= 12; i--) {
      block[i] = (block[i] + 1) & 0xff;
      if (block[i] != 0) break;
    }
  }

  List<int> _ghashTag(List<int> h, List<int> aad, List<int> ct, List<int> j0) {
    var y = List<int>.filled(16, 0);
    void block(List<int> b) {
      for (var i = 0; i < 16; i++) {
        y[i] ^= b[i];
      }
      y = _gfMul(y, h);
    }

    for (var off = 0; off < aad.length; off += 16) {
      final blk = List<int>.filled(16, 0);
      final n = (aad.length - off) < 16 ? aad.length - off : 16;
      for (var i = 0; i < n; i++) {
        blk[i] = aad[off + i];
      }
      block(blk);
    }
    for (var off = 0; off < ct.length; off += 16) {
      final blk = List<int>.filled(16, 0);
      final n = (ct.length - off) < 16 ? ct.length - off : 16;
      for (var i = 0; i < n; i++) {
        blk[i] = ct[off + i];
      }
      block(blk);
    }
    // lengths in bits, 64-bit big-endian each.
    final lenBlk = List<int>.filled(16, 0);
    _writeU64(lenBlk, 0, aad.length * 8);
    _writeU64(lenBlk, 8, ct.length * 8);
    block(lenBlk);

    final ej0 = encryptBlock(j0);
    final tag = List<int>.filled(16, 0);
    for (var i = 0; i < 16; i++) {
      tag[i] = y[i] ^ ej0[i];
    }
    return tag;
  }

  static void _writeU64(List<int> buf, int off, int value) {
    for (var i = 7; i >= 0; i--) {
      buf[off + i] = value & 0xff;
      value >>= 8;
    }
  }

  /// GF(2^128) multiply (GCM polynomial), big-endian bit order.
  static List<int> _gfMul(List<int> x, List<int> y) {
    final z = List<int>.filled(16, 0);
    final v = List<int>.from(y);
    for (var i = 0; i < 128; i++) {
      final bit = (x[i ~/ 8] >> (7 - (i % 8))) & 1;
      if (bit != 0) {
        for (var j = 0; j < 16; j++) {
          z[j] ^= v[j];
        }
      }
      // v >>= 1, then if LSB was set xor R (0xe1 << 120).
      var lsb = v[15] & 1;
      for (var j = 15; j > 0; j--) {
        v[j] = ((v[j] >> 1) | ((v[j - 1] & 1) << 7)) & 0xff;
      }
      v[0] = v[0] >> 1;
      if (lsb != 0) v[0] ^= 0xe1;
    }
    return z;
  }

  static List<int> _buildSbox() {
    // Стандартный AES S-box, статически.
    const hex =
        '637c777bf26b6fc53001672bfed7ab76ca82c97dfa5947f0add4a2af9ca472c0'
        'b7fd9326363ff7cc34a5e5f171d8311504c723c31896059a071280e2eb27b275'
        '09832c1a1b6e5aa0523bd6b329e32f8453d100ed20fcb15b6acbbe394a4c58cf'
        'd0efaafb434d338545f9027f503c9fa851a3408f929d38f5bcb6da2110fff3d2'
        'cd0c13ec5f974417c4a77e3d645d197360814fdc222a908846eeb814de5e0bdb'
        'e0323a0a4906245cc2d3ac629195e479e7c8376d8dd54ea96c56f4ea657aae08'
        'ba78252e1ca6b4c6e8dd741f4bbd8b8a703eb5664803f60e613557b986c11d9e'
        'e1f8981169d98e949b1e87e9ce5528df8ca1890dbfe6426841992d0fb054bb16';
    final out = <int>[];
    for (var i = 0; i < hex.length; i += 2) {
      out.add(int.parse(hex.substring(i, i + 2), radix: 16));
    }
    return out;
  }
}
