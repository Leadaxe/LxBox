import 'dart:math';
import 'dart:typed_data';

import 'package:crypto/crypto.dart' as crypto;

import 'aes_min.dart';

/// §136 — генератор `i1` как **настоящий QUIC Initial** (порт `quic.js` из
/// `warp-generator.github.io`). Заменяет слабый WG-traffic decoy (§126).
///
/// Идея (реверс 2026-06-16): junk-`i1` = валидный QUIC Initial-пакет с голым
/// SNI-ClientHello. DPI читает заголовок `QUIC к SNI` и пропускает (под
/// google/госуслуги/etc QUIC-трафик не режут). Изменчивые поля (TLS random,
/// хвост шифротекста) вырезаются в **CPS-тег `<r N>`** → ядро AmneziaWG рандомит
/// их НА КАЖДЫЙ пакет → нет общей сигнатуры/beacon между юзерами.
///
/// Крипта — RFC 9001 (Initial secrets): `INITIAL_SALT → HMAC(dcid) →
/// client_in → quic key/iv/hp`, AES-128-GCM + header protection. Та же, что
/// в `quic.js`; теги `<b>`/`<r>` подтверждены в нашем ядре (lx.10
/// `obfBuilders["r"]`, `lx-test/config/awg2_basic.json i2:"<c><t><r 10>"`).
class QuicI1 {
  QuicI1._();

  static final Random _rng = Random.secure();

  /// RFC 9001 §5.2 initial salt (QUIC v1).
  static final List<int> _initialSalt = [
    0x38, 0x76, 0x2c, 0xf7, 0xf5, 0x59, 0x34, 0xb3, 0x4d, 0x17,
    0x9a, 0xe6, 0xa4, 0xc8, 0x0c, 0xad, 0xcc, 0xbb, 0x7f, 0x0a,
  ];

  /// Минимальная длина QUIC payload (CRYPTO+PADDING), чтобы итоговый пакет был
  /// ~1232+ байт = настоящий QUIC Initial. RFC 9000 требует ≥1200; рабочий i1
  /// у юзера = 1250б (length-поле 1232). Короткий «Initial» (~92б, как у
  /// quic.js padto=0) — аномалия, DPI его НЕ примет за настоящий QUIC.
  static const int _minPayloadLen = 1200;

  /// Генерирует `i1` CPS-строку для заданного [sni] и [level] нарезки (0–4).
  /// Каждый вызов уникален ([Random.secure]). Возвращает `<b 0x…><r N>…`.
  static String generate(String sni, {int level = 0}) {
    final ch = _clientHelloSniOnly(sni);
    final dcid = _randomBytes(8); // 8 байт (как в рабочем i1; quic.js брал 1)
    final pkn = [0]; // packet number = 0
    final framed = _clientHelloToFrames(ch, level);
    // §136fix — паддим payload QUIC PADDING-фреймами (нули) до _minPayloadLen,
    // чтобы пакет был полноразмерным Initial (~1232+). Нули = валидный PADDING,
    // нарезка покрывает их в последнем <b>-сегменте (см. _padCut).
    final basePayload = framed.payload;
    final padLen = basePayload.length < _minPayloadLen
        ? _minPayloadLen - basePayload.length
        : 0;
    final payload = <int>[...basePayload, ...List<int>.filled(padLen, 0)];
    final packet = _quicInitial(dcid, const [], const [], pkn, payload);
    final cut = _fixCutSettings(
        _padCut(framed.cut, padLen), packet.length, pkn.length, payload.length);
    return _toAwg(packet, cut);
  }

  /// §136fix — расширяет последний `<b>`-сегмент cut на [padLen] байт padding,
  /// чтобы PADDING-нули попали в вывод (иначе выпали бы из AWG).
  static List<int> _padCut(List<int> cut, int padLen) {
    if (padLen == 0) return cut;
    final c = List<int>.from(cut);
    // cut = [b, r, b, r] (level 0) или [b, r] (1-4). Последний — <r>-хвост;
    // padding кладём ПЕРЕД ним, расширяя предпоследний <b> (чётный индекс).
    // Для [b,r,b,r] — индекс 2; для [b,r] — индекс 0.
    final bIdx = c.length >= 4 ? 2 : 0;
    c[bIdx] += padLen;
    return c;
  }

  // ── ClientHello (голый, только SNI) ───────────────────────────────────────

  /// TLS 1.3 ClientHello, только SNI-расширение, как `quicTlsClientHelloSniOnly`.
  /// `01 | len24 | 0303 | random[32] | sid=0 | cipher=[] | comp=0 | ext{SNI}`.
  static List<int> _clientHelloSniOnly(String sni) {
    final random = _randomBytes(32);
    final sniExt = _tlsExtSni(sni);
    // тело ClientHello (без 4-байтового handshake-заголовка)
    final body = <int>[
      0x03, 0x03, // legacy_version
      ...random,
      0x00, // session_id length = 0
      0x00, 0x00, // cipher_suites length = 0 (как в quic.js)
      // (нет вектора компрессии в quic.js — он опускает; держим 1:1)
      ..._u16(sniExt.length), // extensions length
      ...sniExt,
    ];
    return <int>[
      0x01, // handshake type = ClientHello
      ..._u24(body.length),
      ...body,
    ];
  }

  /// SNI extension (type 0x0000): ext{ server_name_list{ host_name } }.
  static List<int> _tlsExtSni(String sni) {
    final host = _ascii(sni);
    final serverName = <int>[
      0x00, // name_type = host_name
      ..._u16(host.length),
      ...host,
    ];
    final list = <int>[
      ..._u16(serverName.length),
      ...serverName,
    ];
    return <int>[
      0x00, 0x00, // extension_type = server_name
      ..._u16(list.length),
      ...list,
    ];
  }

  // ── CRYPTO frame(s) + нарезка по уровню ───────────────────────────────────

  static _Framed _clientHelloToFrames(List<int> ch, int level) {
    if (level == 0) {
      // legacy cut (quic.js level 0): один CRYPTO frame, дыры в середине.
      final payload = _cryptoFrame(ch, 0);
      final dataOffset = payload.length - ch.length;
      // [b до random][r 32 = TLS random][b середина][r 16 = хвост]
      final cut = <int>[dataOffset + 6, 32, ch.length - 38, 16];
      return _Framed(payload, cut);
    }
    // level 1..4 — два CRYPTO frame с разными пресетами разреза (как quic.js).
    final presets = <int, List<int>>{
      1: [38, ch.length, 0, 38, 32],
      2: [38, ch.length, 0, 38, 37],
      3: [0, 1, 38, ch.length, 0],
      4: [0, 1, 38, ch.length, 0],
    };
    final p = presets[level] ?? presets[1]!;
    var p2s = p[2];
    if (level == 4) {
      while (p2s < ch.length && ch[p2s] == 0) {
        p2s++;
      }
    }
    final payload = <int>[
      ..._cryptoFrame(ch.sublist(p[0], p[1].clamp(0, ch.length)), p[0]),
      ..._cryptoFrame(ch.sublist(p2s, p[3].clamp(0, ch.length)), p2s),
    ];
    final dropTail = p[4];
    final cut = <int>[payload.length - dropTail, 16 + dropTail];
    return _Framed(payload, cut);
  }

  /// CRYPTO frame: `06 | varint(offset) | varint(len) | data`.
  static List<int> _cryptoFrame(List<int> data, int offset) => <int>[
        0x06,
        ..._varint(offset),
        ..._varint(data.length),
        ...data,
      ];

  // ── QUIC Initial пакет (RFC 9001) ─────────────────────────────────────────

  static List<int> _quicInitial(List<int> dcid, List<int> scid,
      List<int> token, List<int> pkn, List<int> payload) {
    final lengths =
        _measure(dcid.length, scid.length, token.length, pkn.length,
            payload.length);
    final padding = lengths.padding;

    // header: flags | version | dcid(len8) | scid(len8) | token(len8) | length | pkn
    final header = <int>[
      0xc0 | (pkn.length - 1), // long header, Initial, pn_len
      0x00, 0x00, 0x00, 0x01, // version = 1
      ..._str8(dcid),
      ..._str8(scid),
      ..._str8(token),
      ..._varint(pkn.length + payload.length + padding + 16),
      ...pkn,
    ];

    // derive keys
    final initSecret = _hmac(_initialSalt, dcid);
    final clientSecret = _deriveSecret(initSecret, 32, 'client in');
    final key = _deriveSecret(clientSecret, 16, 'quic key');
    final iv = _deriveSecret(clientSecret, 12, 'quic iv');
    final hp = _deriveSecret(clientSecret, 16, 'quic hp');

    // nonce = iv xor pkn (right-aligned)
    final nonce = List<int>.from(iv);
    for (var i = 0; i < pkn.length; i++) {
      nonce[12 - pkn.length + i] ^= pkn[i];
    }

    final paddedPayload = <int>[...payload, ...List<int>.filled(padding, 0)];
    final aes = AesMin(key);
    final encrypted = aes.gcmEncrypt(nonce, paddedPayload, header);

    // header protection
    final sampleOffset = 4 - pkn.length;
    final sample = encrypted.sublist(sampleOffset, sampleOffset + 16);
    final mask = AesMin(hp).encryptBlock(sample);
    final out = <int>[...header, ...encrypted];
    out[0] ^= (mask[0] & 0x0f);
    final pknOffset = header.length - pkn.length;
    for (var i = 0; i < pkn.length; i++) {
      out[pknOffset + i] ^= mask[1 + i];
    }
    return out;
  }

  static _Lengths _measure(int dcidLen, int scidLen, int tokenLen, int pknLen,
      int payloadLen) {
    final baseHeader = 8 + dcidLen + scidLen + tokenLen + pknLen;
    const tag = 16;
    var padding = 0;
    int lenByteSize() => _varintLen(pknLen + payloadLen + padding + tag);
    int overall() => baseHeader + lenByteSize() + payloadLen + padding + tag;
    // safety: tail (pkn..tag) ≥ 20 байт для HP-sample.
    if (pknLen + payloadLen + padding + tag < 20) {
      padding = 20 - pknLen - payloadLen - tag;
    }
    return _Lengths(overall(), padding);
  }

  // ── HKDF-like (quic.js quicDeriveSecret: HMAC, no full HKDF) ───────────────

  /// `quicDeriveSecret`: HMAC(key, [u16(len) | str8('tls13 '+label) | str8('') |
  /// 0x01]).slice(0,len). 1:1 c quic.js.
  static List<int> _deriveSecret(List<int> key, int length, String label) {
    final data = <int>[
      ..._u16(length),
      ..._str8(_ascii('tls13 $label')),
      ..._str8(const []),
      0x01,
    ];
    final mac = _hmac(key, data);
    return mac.sublist(0, length);
  }

  static List<int> _hmac(List<int> key, List<int> data) =>
      crypto.Hmac(crypto.sha256, key).convert(data).bytes;

  // ── CPS-сериализация (quicToAWG) ──────────────────────────────────────────

  /// Чинит cutSettings под header protection и абсолютный offset (quic.js
  /// `quicFixCutSettings`, padto=0).
  static List<int> _fixCutSettings(
      List<int> cut, int packetLen, int pknLen, int payloadLen) {
    final c = List<int>.from(cut);
    if (c[0] < 20 - pknLen) {
      final toAdd = 20 - pknLen - c[0];
      c[0] += toAdd;
      c[1] -= toAdd;
    }
    // включаем заголовок в первый <b>-кусок.
    c[0] += packetLen - payloadLen - 16;
    return c;
  }

  /// Режет пакет на `<b 0x…>` (статика) / `<r N>` (ядро рандомит) по [parts].
  /// Нечётные сегменты (index 1,3,…) → `<r N>`. quic.js `quicToAWG`.
  static String _toAwg(List<int> packet, List<int>? parts) {
    if (parts == null) return '<b 0x${_hex(packet)}>';
    final sb = StringBuffer();
    var include = true;
    var offset = 0;
    for (final part in parts) {
      if (part > 0) {
        if (include) {
          final end = (offset + part).clamp(0, packet.length);
          sb.write('<b 0x${_hex(packet.sublist(offset.clamp(0, packet.length), end))}>');
        } else {
          sb.write('<r $part>');
        }
        offset += part;
      }
      include = !include;
    }
    return sb.toString();
  }

  // ── helpers ───────────────────────────────────────────────────────────────

  static List<int> _str8(List<int> data) => <int>[data.length, ...data];

  static List<int> _u16(int x) => <int>[(x >> 8) & 0xff, x & 0xff];

  static List<int> _u24(int x) =>
      <int>[(x >> 16) & 0xff, (x >> 8) & 0xff, x & 0xff];

  /// QUIC variable-length integer.
  static List<int> _varint(int x) {
    if (x < 0x40) return <int>[x];
    if (x < 0x4000) return <int>[((x >> 8) & 0xff) | 0x40, x & 0xff];
    if (x < 0x40000000) {
      return <int>[
        ((x >> 24) & 0xff) | 0x80,
        (x >> 16) & 0xff,
        (x >> 8) & 0xff,
        x & 0xff,
      ];
    }
    final b = ByteData(8)..setUint64(0, x);
    final out = b.buffer.asUint8List().toList();
    out[0] |= 0xc0;
    return out;
  }

  static int _varintLen(int x) {
    if (x < 0x40) return 1;
    if (x < 0x4000) return 2;
    if (x < 0x40000000) return 4;
    return 8;
  }

  static List<int> _randomBytes(int n) =>
      List<int>.generate(n, (_) => _rng.nextInt(256));

  static List<int> _ascii(String s) => s.codeUnits;

  static String _hex(List<int> bytes) {
    final sb = StringBuffer();
    for (final b in bytes) {
      sb.write((b & 0xff).toRadixString(16).padLeft(2, '0'));
    }
    return sb.toString();
  }
}

class _Framed {
  _Framed(this.payload, this.cut);
  final List<int> payload;
  final List<int> cut;
}

class _Lengths {
  _Lengths(this.total, this.padding);
  final int total;
  final int padding;
}
