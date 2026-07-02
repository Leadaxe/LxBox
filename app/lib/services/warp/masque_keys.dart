import 'dart:convert';
import 'dart:math' show Random;
import 'dart:typed_data';

import 'package:asn1lib/asn1lib.dart';
import 'package:pointycastle/export.dart';

/// §130 — ECDSA P-256 keygen + DER-сериализация для MASQUE-WARP.
///
/// Контракт с ядром (sing-box-lx SPEC 021) БАЙТ-В-БАЙТ:
/// - `private_key` = base64(SEC1 `ECPrivateKey` DER) — ядро парсит
///   `x509.ParseECPrivateKey`.
/// - `public_key`  = base64(PKIX/SPKI DER)          — ядро парсит
///   `x509.ParsePKIXPublicKey`.
///
/// Keygen — через `pointycastle` (pure-Dart, работает на Android). Пакет
/// `cryptography` (X25519 в §025) P-256 **keygen НЕ реализует** — `DartEcdsa`
/// бросает `UnimplementedError`, реальный keygen только на Apple-платформах. DER
/// собираем сами из сырых `d`/`x`/`y` через `asn1lib` — pointycastle-сериализатор
/// не гарантирует SEC1/PKIX-формат, а несовпадение с Go-парсером = fatal при старте.
///
/// base64 — СТАНДАРТНЫЙ (`base64.encode`, с `=`-паддингом), НЕ url-safe: ядро
/// декодит `base64.StdEncoding`.
class MasqueKeys {
  /// P-256 named curve OID `prime256v1` = `1.2.840.10045.3.1.7`.
  static const _oidP256 = '1.2.840.10045.3.1.7';

  /// `id-ecPublicKey` = `1.2.840.10045.2.1`.
  static const _oidEcPublicKey = '1.2.840.10045.2.1';

  /// Длина каждой координаты P-256 в байтах (256 бит).
  static const _coordLen = 32;

  // §219 — module/class-level: раньше компилились на каждый normalizeServerPubKey
  // (MASQUE-регистрация).
  static final _wsRe = RegExp(r'\s');
  static final _pemHeaderRe = RegExp(r'-----(BEGIN|END)[^-]*-----');

  /// Сгенерированный ECDSA P-256 keypair, готовый к отправке в CF и ядро.
  ///
  /// - [privateKeyDer] / [publicKeyDer] — base64(DER), контракт с ядром.
  /// - [rawX] / [rawY] / [rawD] — сырые 32-байтные координаты (для тестов).
  static MasqueKeyMaterial generate() {
    final gen = ECKeyGenerator()
      ..init(ParametersWithRandom(
        ECKeyGeneratorParameters(ECCurve_secp256r1()),
        _secureRandom(),
      ));
    final pair = gen.generateKeyPair();
    final priv = pair.privateKey;
    final pub = pair.publicKey;

    final d = _bigIntToFixed(priv.d!, _coordLen);
    final x = _bigIntToFixed(pub.Q!.x!.toBigInteger()!, _coordLen);
    final y = _bigIntToFixed(pub.Q!.y!.toBigInteger()!, _coordLen);

    return MasqueKeyMaterial(
      privateKeyDer: base64.encode(encodeSec1PrivateKey(d: d, x: x, y: y)),
      publicKeyDer: base64.encode(encodePkixPublicKey(x: x, y: y)),
      rawD: d,
      rawX: x,
      rawY: y,
    );
  }

  /// Криптостойкий генератор для keygen: FortunaRandom, засеянный из
  /// `Random.secure()` (ОС-энтропия). Без seed pointycastle бросает при первом
  /// использовании.
  static SecureRandom _secureRandom() {
    final rnd = FortunaRandom();
    final seed = Uint8List.fromList(
      List<int>.generate(32, (_) => Random.secure().nextInt(256)),
    );
    rnd.seed(KeyParameter(seed));
    return rnd;
  }

  /// BigInt → big-endian [len]-байтовый буфер (левые нули добиваются).
  static Uint8List _bigIntToFixed(BigInt v, int len) {
    final out = Uint8List(len);
    var tmp = v;
    for (var i = len - 1; i >= 0; i--) {
      out[i] = (tmp & BigInt.from(0xff)).toInt();
      tmp = tmp >> 8;
    }
    return out;
  }

  /// Несжатая EC-точка `0x04 ‖ X ‖ Y` (65 байт для P-256).
  static Uint8List _uncompressedPoint(Uint8List x, Uint8List y) {
    final out = Uint8List(1 + x.length + y.length);
    out[0] = 0x04;
    out.setRange(1, 1 + x.length, x);
    out.setRange(1 + x.length, out.length, y);
    return out;
  }

  /// SEC1 `ECPrivateKey` (RFC 5915), как ждёт `x509.ParseECPrivateKey`:
  ///
  /// ```
  /// ECPrivateKey ::= SEQUENCE {
  ///   version        INTEGER { ecPrivkeyVer1(1) },
  ///   privateKey     OCTET STRING,          -- d, 32 байта
  ///   parameters [0] EXPLICIT ECParameters, -- namedCurve OID prime256v1
  ///   publicKey  [1] EXPLICIT BIT STRING    -- 0x04‖X‖Y
  /// }
  /// ```
  static Uint8List encodeSec1PrivateKey({
    required Uint8List d,
    required Uint8List x,
    required Uint8List y,
  }) {
    final seq = ASN1Sequence();
    // version = 1
    seq.add(ASN1Integer(BigInt.one));
    // privateKey OCTET STRING (сырые 32 байта d, без ведущего знака)
    seq.add(ASN1OctetString(d));
    // [0] EXPLICIT namedCurve OID
    final oid = ASN1ObjectIdentifier.fromComponentString(_oidP256);
    seq.add(_explicit(0xA0, oid.encodedBytes));
    // [1] EXPLICIT BIT STRING (несжатая точка)
    final bits = ASN1BitString(_uncompressedPoint(x, y).toList());
    seq.add(_explicit(0xA1, bits.encodedBytes));
    return seq.encodedBytes;
  }

  /// PKIX/SPKI `SubjectPublicKeyInfo`, как ждёт `x509.ParsePKIXPublicKey`:
  ///
  /// ```
  /// SubjectPublicKeyInfo ::= SEQUENCE {
  ///   algorithm SEQUENCE {
  ///     algorithm  OID id-ecPublicKey,
  ///     parameters OID prime256v1
  ///   },
  ///   subjectPublicKey BIT STRING  -- 0x04‖X‖Y
  /// }
  /// ```
  static Uint8List encodePkixPublicKey({
    required Uint8List x,
    required Uint8List y,
  }) {
    final algId = ASN1Sequence()
      ..add(ASN1ObjectIdentifier.fromComponentString(_oidEcPublicKey))
      ..add(ASN1ObjectIdentifier.fromComponentString(_oidP256));
    final spki = ASN1Sequence()
      ..add(algId)
      ..add(ASN1BitString(_uncompressedPoint(x, y).toList()));
    return spki.encodedBytes;
  }

  /// Достаёт сырую несжатую точку из серверного PKIX-pubkey. Принимает и PEM
  /// (`-----BEGIN PUBLIC KEY-----`), и голый base64(DER) — Cloudflare отдаёт
  /// pubkey как PEM, ядру нужен чистый base64(DER).
  static String normalizeServerPubKey(String raw) {
    final trimmed = raw.trim();
    if (!trimmed.contains('-----BEGIN')) {
      // уже base64(DER) — возвращаем как есть (убрав пробелы/переводы строк)
      return trimmed.replaceAll(_wsRe, '');
    }
    final body = trimmed.replaceAll(_pemHeaderRe, '').replaceAll(_wsRe, '');
    // валидируем, что это парсится в base64 (иначе бросит FormatException)
    base64.decode(body);
    return body;
  }

  /// EXPLICIT context-specific-тег `[n]`: оборачивает уже закодированный DER
  /// вложенного объекта в конструированный context-тег ([tag] = 0xA0|0xA1|...).
  static ASN1Object _explicit(int tag, Uint8List innerDer) =>
      ASN1Object.preEncoded(tag, innerDer);
}

/// Результат генерации: DER-строки (для ядра/CF) + сырые координаты (для тестов).
class MasqueKeyMaterial {
  const MasqueKeyMaterial({
    required this.privateKeyDer,
    required this.publicKeyDer,
    required this.rawD,
    required this.rawX,
    required this.rawY,
  });

  /// base64(SEC1 DER) приватного ключа — СЕКРЕТ, не логировать.
  final String privateKeyDer;

  /// base64(PKIX DER) публичного ключа клиента (шлём в CF PATCH).
  final String publicKeyDer;

  final Uint8List rawD;
  final Uint8List rawX;
  final Uint8List rawY;
}
