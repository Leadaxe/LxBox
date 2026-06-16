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

  /// Длина QUIC payload (CRYPTO+PADDING) до шифрования. Рабочий эталон
  /// (🟡 QUIC-google, взлетел у Ильи): пакет=1250б, length-поле=1232,
  /// т.е. payload+pad = length - pkn(1) - tag(16) = 1215. Берём ровно 1215 →
  /// пакет 1250б, байт-в-байт по размеру с рабочим.
  static const int _minPayloadLen = 1215;

  /// Генерирует `i1` CPS-строку для заданного [sni]. Формат = ТОЧНО как
  /// **доказанно рабочий** узел (🟡 QUIC-google, взлетел у Ильи 2026-06-16):
  /// **1250-байтовый QUIC Initial, СПЛОШНОЙ `<b 0x…>`** (length-поле 1232,
  /// DCID=8, БЕЗ `<r>`). Уникальность — через рандомные DCID / TLS random[32]
  /// на каждый вызов (каждый i1 разный), как у рабочих конфигов.
  ///
  /// КРИТИЧНО — НЕ добавлять `<r>`-нарезку: узел с `<b><r><b><r>` (наш прежний
  /// генератор) у Ильи НЕ работал; сплошной `<b>` 1250б — работал. [level]
  /// оставлен для совместимости сигнатуры, не влияет.
  static String generate(String sni, {int level = 0}) {
    final ch = _clientHelloSniOnly(sni);
    final dcid = _randomBytes(8); // 8 байт (как в рабочем i1)
    final pkn = [0]; // packet number = 0
    // Один CRYPTO frame с ClientHello, затем PADDING (нули) до _minPayloadLen →
    // пакет 1250б (length-поле 1232, как у рабочего). Всё шифруется в общий <b>.
    final crypto = _cryptoFrame(ch, 0);
    final padLen = crypto.length < _minPayloadLen
        ? _minPayloadLen - crypto.length
        : 0;
    final payload = <int>[...crypto, ...List<int>.filled(padLen, 0)];
    final packet = _quicInitial(dcid, const [], const [], pkn, payload);
    // Весь пакет одним <b 0x…> — как quicToAWG(packet, null) в референсе.
    return _toAwg(packet, null);
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

  /// Сериализует пакет в `<b 0x…>` (сплошной). [parts] оставлен из квик.js на
  /// случай будущей `<r>`-нарезки, сейчас всегда null → один `<b>`.
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

class _Lengths {
  _Lengths(this.total, this.padding);
  final int total;
  final int padding;
}
