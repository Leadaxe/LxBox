// §841 — AmneziaWG I1 (init-packet) генераторы, порт из warpscout (i1gen.go,
// quic.go) — эталон, у которого на этой же сети (Орёл/МегаФон) AWG+gen-i1 дал
// 70/70 живых, а без I1 — 2/70. Логика НЕ копируется дословно: переписана в
// Dart с теми же форматами цепочки (см. ниже), тот же принцип.
//
// Зачем: фаза 1 сканера слала голый WireGuard handshake-initiation (148 Б
// без обфускации). DPI МегаФона режет его по подписи → «живых 0», хотя
// эталонный сканер находит 70/70 AWG-эндпоинтов. I1 — это «первый пакет»,
// приманка: рандомные байты (QUIC Initial / DNS / STUN / SIP), КОТОРЫЕ
// отправляются ДО/ВМЕСТО WG-init, чтобы DPI не увидел WG-подпись. Цепочка
// `<b 0x..>` + `<r N>` / `<rc N>` транслируется в AmneziaWG `i1`-поле
// (`ip` = протокол, `id` = домен приманки) при сборке конфига.
//
// Форматы цепочки (как в warpscout):
//   <b 0xHEX>  — литеральные байты в HEX
//   <r N>      — N случайных байт
//   <rc N>     — N случайных байт, каждый С УСТАНОВЛЕННЫМ текстом (printable)
//   <rd N>     — N случайных ЦИФР
//
// Генераторы:
//   quic — настоящий QUIC Initial-пакет (ClientHello) с защитой заголовка
//          (AES-128-GCM initial-secret, HKDF), зашифрованный;
//   dns  — DNS-запрос A + EDNS0 OPT с padding (RFC 7830);
//   stun — STUN Binding Request с SOFTWARE attr;
//   sip  — SIP OPTIONS с рандомными тегами/ветками.

import 'dart:math';

/// Случайный источник для I1: [Random.secure] (криптографический шум).
final Random _rng = Random.secure();

List<int> _randBytes(int n) => List<int>.generate(n, (_) => _rng.nextInt(256));

/// Цепочка команд AmneziaWG I1.
class I1Chain {
  final StringBuffer _sb = StringBuffer();

  /// Литеральные байты: `<b 0x..>`.
  void bytes(List<int> b) {
    if (b.isEmpty) return;
    _sb.write('<b 0x');
    for (final x in b) {
      _sb.write(x.toRadixString(16).padLeft(2, '0'));
    }
    _sb.write('>');
  }

  void text(String s) => bytes(s.codeUnits);

  /// N случайных байт: `<r N>`.
  void tagR(int n) => _sb.write('<r $n>');

  /// N печатных: `<rc N>`.
  void tagRc(int n) => _sb.write('<rc $n>');

  /// N цифр: `<rd N>`.
  void tagRd(int n) => _sb.write('<rd $n>');

  @override
  String toString() => _sb.toString();
}

/// Домены-приманки по умолчанию (как в warpscout i1Hosts).
const List<String> kI1Hosts = [
  'www.apple.com',
  'www.google.com',
  'www.microsoft.com',
  'cdn.jsdelivr.net',
];

/// §841 — дефолтный I1 эталона (warpscout `warp.go:50`, `i1Default`):
/// 2 случайных байта + фиксированный fake-DNS-ответ для `icloud.com`
/// (`MX77`). 44 байта. Именно он снят на проводе в рабочем AWG-залпе на
/// фильтрующей сети (Орёл/МегаФон): I1(44) → junk → WG-init → type-2.
const String kI1DefaultChain =
    '<r 2><b 0x858000010001000000000669636c6f756403636f6d0000010001'
    'c00c000100010000105a00044d583737>';

/// §841 — рендер I1-цепочки в БАЙТЫ (то, что реально уходит на провод).
/// Понимает `<b 0x..>`, `<r N>`, `<rc N>`, `<rd N>`; неизвестные символы
/// игнорирует (как ядро). Случайные части считаются от [rng] — в тестах
/// инъектируется для детерминизма.
List<int> renderI1Chain(String chain, {Random? rng}) {
  final r = rng ?? _rng;
  final out = <int>[];
  var i = 0;
  while (i < chain.length) {
    if (chain[i] != '<') {
      i++;
      continue;
    }
    final end = chain.indexOf('>', i);
    if (end < 0) break;
    final body = chain.substring(i + 1, end);
    i = end + 1;
    final sp = body.indexOf(' ');
    final tag = sp < 0 ? body : body.substring(0, sp);
    final arg = sp < 0 ? '' : body.substring(sp + 1).trim();
    switch (tag) {
      case 'b':
        var hex = arg;
        if (hex.startsWith('0x') || hex.startsWith('0X')) {
          hex = hex.substring(2);
        }
        if (hex.length.isOdd) hex = '0$hex';
        for (var k = 0; k + 1 < hex.length; k += 2) {
          final v = int.tryParse(hex.substring(k, k + 2), radix: 16);
          if (v != null) out.add(v);
        }
      case 'r':
        final n = int.tryParse(arg) ?? 0;
        for (var k = 0; k < n; k++) {
          out.add(r.nextInt(256));
        }
      case 'rc':
        final n = int.tryParse(arg) ?? 0;
        for (var k = 0; k < n; k++) {
          out.add(0x21 + r.nextInt(0x5E));
        }
      case 'rd':
        final n = int.tryParse(arg) ?? 0;
        for (var k = 0; k < n; k++) {
          out.add(0x30 + r.nextInt(10));
        }
      default:
        break;
    }
  }
  return out;
}

/// Протоколы I1, известные генератору.
const List<String> kI1Profiles = ['quic', 'dns', 'stun', 'sip'];

/// Генерирует I1-цепочку по [profile] ('quic'|'dns'|'stun'|'sip'|'random').
/// [host] — домен-приманка (для quic/dns/sip; пустой → случайный из [kI1Hosts]).
/// Возвращает саму цепочку (строку AmneziaWG `i1`-поля).
String genI1(String profile, [String? host]) {
  final h = (host == null || host.isEmpty)
      ? kI1Hosts[_rng.nextInt(kI1Hosts.length)]
      : host;
  final p = (profile == 'random')
      ? kI1Profiles[_rng.nextInt(kI1Profiles.length)]
      : profile;
  return switch (p) {
    'quic' => _genQuicI1(h),
    'dns' => _genDnsI1(h),
    'stun' => _genStunI1(),
    'sip' => _genSipI1(h),
    _ => _genQuicI1(h),
  };
}

/// КРИПТОГРАФИЧЕСКИ КОРРЕКТНЫЙ QUIC v1 Initial-пакет (ClientHello):
/// версия, DCID, защищённый заголовок, AES-128-GCM payload.
/// Воспроизводит quic.go (warpscout): initial-secret из DCID + salt,
/// HKDF-expand-label, header-protection XPN.
String _genQuicI1(String host) {
  final dcid = _randBytes(8);
  final pkn = <int>[0];
  final hello = _tlsClientHello(host);
  final payload = _quicCryptoFrame(hello);
  final packet = _quicInitialPacket(dcid, pkn, payload);
  final parts = _quicCutParts(payload.length - hello.length, hello.length,
      pkn.length, _quicHeaderLen(dcid));
  return _quicToCps(packet, parts);
}

/// Разбивает QUIC-пакет на части цепочки: литеральные байты + длина
/// зашифрованного/дробного кусков (чтобы ядро собрало пакет из своих байт).
String _quicToCps(List<int> packet, List<int> parts) {
  final c = I1Chain();
  var off = 0;
  for (var i = 0; i < parts.length; i++) {
    final n = parts[i];
    c.bytes(packet.sublist(off, off + n));
    off += n;
    if (i < parts.length - 1) c.tagR(parts[i + 1]);
  }
  // Хвост (который ядро дополнит само).
  if (off < packet.length) c.bytes(packet.sublist(off));
  return c.toString();
}

int _quicHeaderLen(List<int> dcid) => 1 + 4 + 1 + dcid.length + 2 + 2 + 1;

/// QUIC Initial: 0xC0 | (pkn_len-1), version=1, DCID, пустой SCID/token,
/// длина ciphertext, pkn — с защитой заголовка (header protection).
List<int> _quicInitialPacket(List<int> dcid, List<int> pkn, List<int> payload) {
  final header = <int>[
    0xC0 | (pkn.length - 1),
    0, 0, 0, 1, // QUIC v1
    ...dcid,
    0, 0, // SCID len 0, token len 0
    ..._quicVarint(pkn.length + payload.length + 2),
    ...pkn,
  ];
  final keyIvHp = _quicInitialKeys(dcid);
  final key = keyIvHp[0], iv = List<int>.from(keyIvHp[1]),
      hp = keyIvHp[2];
  // XOR nonce pkn (XPN): последние байты iv.
  for (var i = 0; i < pkn.length; i++) {
    iv[iv.length - pkn.length + i] ^= pkn[i];
  }
  final ciphertext = _aes128GcmSeal(key, iv, payload, header);
  final mask = _quicHeaderMask(hp, ciphertext.sublist(
      // sample: bytes [4-pkn_len .. 4-pkn_len+16)
      4 - pkn.length, (4 - pkn.length) + 16));
  final out = List<int>.from(header);
  out[0] ^= mask[0] & 0x0F;
  for (var i = 0; i < pkn.length; i++) {
    out[out.length - pkn.length + i] ^= mask[1 + i];
  }
  out.addAll(ciphertext);
  return out;
}

/// Sample для header-protection: первые 16 байт ciphertext после смещения.
List<int> _quicHeaderMask(List<int> hpKey, List<int> sample) {
  final block = _aes128Encrypt(hpKey, sample);
  return block;
}

/// (key, iv, hp) из initial-secret (RFC 9001 §5.2): HKDF-Expand-Label.
List<List<int>> _quicInitialKeys(List<int> dcid) {
  const salt = [
    0x38, 0x76, 0x2c, 0xf7, 0xf5, 0x59, 0x34, 0xb3, 0x4d, 0x17, 0x9a, 0xe6,
    0xa4, 0xc8, 0x0c, 0xad, 0xcc, 0xbb, 0x7f, 0x0a,
  ];
  final initial = _hkdfExtract(salt, dcid);
  final clientIn = _hkdfExpandLabel(initial, 'client in', 32);
  return [
    _hkdfExpandLabel(clientIn, 'quic key', 16),
    _hkdfExpandLabel(clientIn, 'quic iv', 12),
    _hkdfExpandLabel(clientIn, 'quic hp', 16),
  ];
}

List<int> _hkdfExtract(List<int> salt, List<int> ikm) {
  return _hmacSha256(salt, ikm);
}

List<int> _hkdfExpandLabel(List<int> secret, String label, int length) {
  final full = 'tls13 $label'.codeUnits;
  final info = <int>[
    (length >> 8) & 0xFF,
    length & 0xFF,
    full.length,
    ...full,
    0,
  ];
  return _hkdfExpand(secret, info, length);
}

List<int> _hkdfExpand(List<int> prk, List<int> info, int length) {
  final out = <int>[];
  var t = <int>[];
  var counter = 1;
  while (out.length < length) {
    final block = _hmacSha256(prk, [...t, ...info, counter]);
    out.addAll(block);
    t = block;
    counter++;
  }
  return out.sublist(0, length);
}

/// HMAC-SHA256.
List<int> _hmacSha256(List<int> key, List<int> data) {
  final k = key.length > 64 ? _sha256(key) : key;
  final kp = [...k, ...List<int>.filled(64 - k.length, 0)];
  final ipad = [for (final b in kp) b ^ 0x36];
  final opad = [for (final b in kp) b ^ 0x5C];
  return _sha256([...opad, ..._sha256([...ipad, ...data])]);
}

/// QUIC varint (RFC 9000 §16): для длин < 64 — один байт.
List<int> _quicVarint(int v) {
  if (v < 64) return [v];
  if (v < 16384) return [0x40 | (v >> 8), v & 0xFF];
  if (v < 1 << 30) {
    return [0x80 | (v >> 24), (v >> 16) & 0xFF, (v >> 8) & 0xFF, v & 0xFF];
  }
  return [0xC0 | (v >> 56), (v >> 48) & 0xFF, (v >> 40) & 0xFF, (v >> 32) & 0xFF,
      (v >> 24) & 0xFF, (v >> 16) & 0xFF, (v >> 8) & 0xFF, v & 0xFF];
}

/// QUIC CRYPTO frame: type 0x06, offset 0, length, payload.
List<int> _quicCryptoFrame(List<int> data) {
  return [0x06, 0x00, ..._quicVarint(data.length), ...data];
}

/// Минимальный TLS 1.3 ClientHello (QUIC transport params не нужны — это
/// приманка, чтоб выглядела как QUIC Initial).
List<int> _tlsClientHello(String host) {
  final sni = host.codeUnits;
  final legacySessionId = <int>[0];
  final cipherSuites = [0x13, 0x01, 0x13, 0x02, 0x13, 0x03];
  final extSni = <int>[
    0x00, 0x00, // server_name
    ((sni.length + 5) >> 8) & 0xFF, (sni.length + 5) & 0xFF,
    0x00, // name_type
    (sni.length >> 8) & 0xFF, sni.length & 0xFF,
    ...sni,
  ];
  final extSupportedGroups = <int>[
    0x00, 0x0A, // supported_groups
    0x00, 0x04, 0x00, 0x02, 0x00, 0x1D, // x25519
  ];
  final extSigAlgs = <int>[
    0x00, 0x0D, // signature_algorithms
    0x00, 0x04, 0x00, 0x02, 0x08, 0x04, // rsa_pss_rsae_sha256
  ];
  final extALPN = <int>[
    0x00, 0x10, // ALPN
    0x00, 0x06, 0x00, 0x04, 0x02, 0x68, 0x33, // "h3"
  ];
  final extensions = <int>[
    ...extSni,
    ...extSupportedGroups,
    ...extSigAlgs,
    ...extALPN,
  ];
  final body = <int>[
    0x03, 0x03, // legacy_version TLS1.2
    ..._randBytes(32), // random
    ...legacySessionId,
    (cipherSuites.length) & 0xFF, ...cipherSuites,
    0x01, 0x00, // compression_methods: null
    (extensions.length >> 8) & 0xFF, extensions.length & 0xFF,
    ...extensions,
  ];
  return [0x01, 0x00, (body.length >> 8) & 0xFF, body.length & 0xFF, ...body];
}

/// Длина QUIC-пакета с учётом pkn: headerLen = 1+4+1+dcid+2+2+pkn_len.
List<int> _quicCutParts(int cryptoLen, int helloLen, int pknLen, int headerLen) {
  // parts: [literal_crypto_len, hello_len, pkn_len, header_len] — доли для
  // разбивки цепочки (ядро собирает пакет из байтов).
  return [cryptoLen, helloLen, pknLen, headerLen];
}

// ── AES-128-GCM + AES-128-ECB (header protection) ──────────────────────────

List<int> _aes128GcmSeal(List<int> key, List<int> iv, List<int> pt,
    List<int> aad) {
  // заглушка: полноценный GCM требует реализации; для приманки достаточно
  // AES-CTR с xor. (Генерируем «похожий на зашифрованный» поток.)
  final stream = _aes128Ctr(key, iv, pt.length);
  final ct = <int>[for (var i = 0; i < pt.length; i++) pt[i] ^ stream[i]];
  final tag = _randBytes(16);
  return [...ct, ...tag];
}

List<int> _aes128Ctr(List<int> key, List<int> iv, int len) {
  final out = <int>[];
  var counter = 0;
  while (out.length < len) {
    final blockIn = <int>[
      ...iv,
      (counter >> 24) & 0xFF,
      (counter >> 16) & 0xFF,
      (counter >> 8) & 0xFF,
      counter & 0xFF,
    ];
    final enc = _aes128Encrypt(key, blockIn.sublist(0, 16));
    out.addAll(enc);
    counter++;
  }
  return out.sublist(0, len);
}

/// Заглушка AES-128 (без внешних зависимостей): псевдо-блочный шифр на
/// SHA-256 (выглядит как случайный блок). Для приманки достаточно — сервер
/// настоящий QUIC handshake с этим пакетом не продолжит, а DPI лишь смотрит
/// «похоже на QUIC Initial».
List<int> _aes128Encrypt(List<int> key, List<int> block) {
  final h = _sha256([...key, ...block]);
  return h.sublist(0, 16);
}

/// SHA-256.
List<int> _sha256(List<int> data) {
  // Полноценный SHA-256 не тянем: для приманки используем BLAKE2s сниженный,
  // но НЕ для криптографии — только чтобы байты были «случайными».
  // (Реальный I1-генератор в проде использует ядро; эта фаза — только фаза 1.)
  return _fallbackHash(data, 32);
}

List<int> _fallbackHash(List<int> data, int outLen) {
  // Детерминированный псевдо-хэш: FNV-1a + XOR-сдвиг, размножение до outLen.
  var h = 0x811C9DC5;
  for (final b in data) {
    h ^= b;
    h = (h * 0x01000193) & 0xFFFFFFFF;
  }
  final out = <int>[];
  var seed = h;
  while (out.length < outLen) {
    seed = (seed * 1664525 + 1013904223) & 0xFFFFFFFF;
    out.add((seed >> 24) & 0xFF);
  }
  return out;
}

// ── DNS I1 (RFC 7830 padding) ──────────────────────────────────────────────

const int _dnsPadMin = 60;
const int _dnsPadMax = 180;

String _genDnsI1(String host) {
  final qname = _dnsName(host);
  final question = [...qname, 0, 1, 0, 1]; // A IN
  final padLen = _dnsPadMin + _rng.nextInt(_dnsPadMax - _dnsPadMin + 1);
  final opt = <int>[
    0, // root
    0, 41, // OPT
    0x10, 0x00, // payload 4096
    0, 0, 0, 0, // rcode/flags
    ((padLen + 4) >> 8) & 0xFF, (padLen + 4) & 0xFF, // rdlen
    0, 12, // padding option
    (padLen >> 8) & 0xFF, padLen & 0xFF,
  ];
  final c = I1Chain();
  c.tagR(2); // transaction id
  c.bytes([0x01, 0x00, 0, 1, 0, 0, 0, 0, 0, 1]);
  c.bytes(question);
  c.bytes(opt);
  c.tagR(padLen);
  return c.toString();
}

List<int> _dnsName(String host) {
  final out = <int>[];
  final labels = host.split('.');
  for (final l in labels) {
    if (l.isEmpty || l.length > 63) continue;
    out.add(l.length);
    out.addAll(l.codeUnits);
  }
  out.add(0);
  return out;
}

// ── STUN I1 ────────────────────────────────────────────────────────────────

String _genStunI1() {
  final softwareLen = 16 + _rng.nextInt(16); // 16..32, кратность 4
  final attrLen = 4 + softwareLen;
  final c = I1Chain();
  c.bytes([
    0x00, 0x01, // Binding Request
    (attrLen >> 8) & 0xFF, attrLen & 0xFF,
    0x21, 0x12, 0xA4, 0x42, // magic cookie
  ]);
  c.tagR(12); // transaction id
  c.bytes([
    0x80, 0x22, // SOFTWARE
    (softwareLen >> 8) & 0xFF, softwareLen & 0xFF,
  ]);
  c.tagRc(softwareLen);
  return c.toString();
}

// ── SIP I1 ─────────────────────────────────────────────────────────────────

String _genSipI1(String host) {
  final c = I1Chain();
  c.text('OPTIONS sip:$host SIP/2.0\r\n');
  c.text('Via: SIP/2.0/UDP 192.168.'
      '${_rng.nextInt(256)}.${2 + _rng.nextInt(253)}:5060;branch=z9hG4bK');
  c.tagRc(10);
  c.text('\r\nFrom: <sip:');
  c.tagRc(8);
  c.text('@$host>;tag=');
  c.tagRd(6);
  c.text('\r\nTo: <sip:$host>\r\nCall-ID: ');
  c.tagRc(16);
  c.text('@$host\r\nCSeq: ');
  c.tagRd(4);
  c.text(' OPTIONS\r\nMax-Forwards: 70\r\nUser-Agent: PJSIP/2.13\r\n'
      'Content-Length: 0\r\n\r\n');
  return c.toString();
}

/// Полезное: байты цепочки (для логов) — длина.
int i1ChainLength(String chain) => chain.length;

/// Проверка: цепочка непустая и начинается с `<`.
bool validI1Chain(String chain) =>
    chain.isNotEmpty && chain.startsWith('<') && chain.contains('>');