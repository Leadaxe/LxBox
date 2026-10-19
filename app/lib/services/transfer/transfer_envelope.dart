// §622 — конверт передачи: AES-256-GCM одноразовым ключом из QR.
//
// Тело `POST /transfer`: `{"v":1,"nonce":"<base64>","ct":"<base64>"}`, где
// `ct` — шифротекст вместе с 16-байтным тегом MAC, связанные данные —
// `lxbox-transfer/1` (фича 031, «Код передачи»). Расшифровка идёт до любого
// разбора содержимого: неаутентифицированный текст как JSON бэкапа не читается.

import 'dart:convert';
import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';

import 'transfer_code.dart';

/// Связанные данные конверта версии 1.
const kTransferAad = 'lxbox-transfer/$kTransferVersion';

const _nonceLength = 12;
const _macLength = 16;

/// Конверт не разобран: не JSON, не та версия, поля не base64 или не той
/// длины. Ответ получателя — 400.
class TransferEnvelopeFormatException implements Exception {
  const TransferEnvelopeFormatException(this.message);
  final String message;
  @override
  String toString() => 'TransferEnvelopeFormatException: $message';
}

/// Конверт не расшифровался этим ключом (чужой ключ, порченые nonce или
/// шифротекст). Ответ получателя — 403.
class TransferEnvelopeAuthException implements Exception {
  const TransferEnvelopeAuthException();
  @override
  String toString() => 'TransferEnvelopeAuthException';
}

final _cipher = AesGcm.with256bits();

/// Шифрует [plaintext] ключом [key] и возвращает JSON конверта.
/// [nonce] — только для тестов; по умолчанию новый случайный.
Future<String> sealTransferEnvelope(
  List<int> plaintext,
  List<int> key, {
  List<int>? nonce,
}) async {
  final box = await _cipher.encrypt(
    plaintext,
    secretKey: SecretKey(List<int>.of(key)),
    nonce: nonce ?? _cipher.newNonce(),
    aad: utf8.encode(kTransferAad),
  );
  final ct = Uint8List(box.cipherText.length + box.mac.bytes.length)
    ..setAll(0, box.cipherText)
    ..setAll(box.cipherText.length, box.mac.bytes);
  return jsonEncode({
    'v': kTransferVersion,
    'nonce': base64.encode(box.nonce),
    'ct': base64.encode(ct),
  });
}

/// Расшифровывает конверт [json] ключом [key].
///
/// Бросает [TransferEnvelopeFormatException], если конверт не разобран, и
/// [TransferEnvelopeAuthException], если ключ не тот или данные испорчены.
Future<Uint8List> openTransferEnvelope(String json, List<int> key) async {
  final Object? decoded;
  try {
    decoded = jsonDecode(json);
  } on FormatException {
    throw const TransferEnvelopeFormatException('not JSON');
  }
  if (decoded is! Map<String, dynamic>) {
    throw const TransferEnvelopeFormatException('not an object');
  }
  if (decoded['v'] != kTransferVersion) {
    throw const TransferEnvelopeFormatException('unsupported version');
  }
  final nonce = _b64(decoded['nonce']);
  final ct = _b64(decoded['ct']);
  if (nonce == null || nonce.length != _nonceLength) {
    throw const TransferEnvelopeFormatException('bad nonce');
  }
  if (ct == null || ct.length < _macLength) {
    throw const TransferEnvelopeFormatException('bad ct');
  }
  final cut = ct.length - _macLength;
  final box = SecretBox(
    ct.sublist(0, cut),
    nonce: nonce,
    mac: Mac(ct.sublist(cut)),
  );
  try {
    final clear = await _cipher.decrypt(
      box,
      secretKey: SecretKey(List<int>.of(key)),
      aad: utf8.encode(kTransferAad),
    );
    return Uint8List.fromList(clear);
  } on SecretBoxAuthenticationError {
    throw const TransferEnvelopeAuthException();
  }
}

Uint8List? _b64(Object? v) {
  if (v is! String) return null;
  try {
    return base64.decode(v);
  } on FormatException {
    return null;
  }
}
