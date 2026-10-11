// §834 — WireGuard handshake-initiation probe, порт логики cf-scanner/warpscout
// (реальный WG Init-пакет по UDP; живой WARP-эндпоинт отвечает 92-байтным
// type-2 (92 Б), либо 64-байтным cookie-reply type-3).
//
// Зачем: TCP/443 доступен почти везде, но WARP по UDP отдаёт данные только
// тому, кто прислал валидный (криптографически корректный) WG-handshake —
// поэтому именно этот пробник отличает «порт открыт файрволом» от «эндпоинт
// реально отвечает WARP».
//
// Крипта — Noise_IKpsk2_25519_ChaChaPoly_BLAKE2s, первый ход инициатора
// (WireGuard whitepaper §5). Проверяется golden-вектором в
// test/warp/scan/scan_wg_handshake_test.dart (эталон сгенерирован тем же
// алгоритмом на Python/cryptography и сверен байт-в-байт).
//
// Ключи/время/индекс инъектируются — тест детерминированный; в рантайме
// эфемерный ключ каждый раз новый (как и положено Noise).

import 'dart:math';
import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';

/// Ход handshake, который шлёт инициатор (WG message type 1).
const _msgTypeInitiation = 1;

/// Статические части строк построителя (совпадают с wireguard-go/noise.c).
final _construction = _ascii('Noise_IKpsk2_25519_ChaChaPoly_BLAKE2s');
final _identifier = _ascii('WireGuard v1 zx2c4 Jason@zx2c4.com');
final _labelMac1 = _ascii('mac1----');

List<int> _ascii(String s) => Uint8List.fromList(s.codeUnits);

/// Публичный статический ключ пира WARP (одинаков для всех WARP-эндпоинтов).
final warpServerPubRaw = _b64('bmXOC+F1FxEMF9dyiK2H5/1SUtzH0JuVo51h2wPfgyo=');

/// Результат одиночной WG-пробы.
enum WgProbeKind {
  /// 92-байтный type-2 handshake response — эндпоинт жив и принял handshake.
  response,

  /// 64-байтный type-3 cookie reply — сервер под rate-limit, но ЖИВ.
  cookie,

  /// Ничего за таймаут — порт закрыт/заблокирован/эндпоинт мёртв.
  timeout,

  /// Мусор/чужой протокол — не WARP.
  junk,

  /// TCP-порт открыт (fallback, когда UDP режется провайдером).
  tcpOpen,
}

class WgProbeResult {
  const WgProbeResult(this.kind, {this.rttMs = 0, this.detail = ''});

  final WgProbeKind kind;
  final int rttMs;

  /// §835 — человекочитаемая деталь ответа/сбоя для журнала скана:
  /// `type2 handshake-response 92B`, `type3 cookie 64B`, `timeout 3000ms`,
  /// `bind: …`, `send: …`. Пусто — деталь не собиралась.
  final String detail;

  /// Эндпоинт признан живым (response, cookie или TCP-открыт).
  bool get alive =>
      kind == WgProbeKind.response ||
      kind == WgProbeKind.cookie ||
      kind == WgProbeKind.tcpOpen;

  /// Строгая валидность — получен полноценный response.
  bool get strict => kind == WgProbeKind.response;
}

/// Собирает WG handshake-initiation. [serverPubRaw] — 32 байта статического
/// pubkey пира (по умолчанию [warpServerPubRaw]). Возвращает 148-байтный пакет:
/// `type|reserved|sender_index|ephemeral|enc_static|enc_timestamp|mac1|mac2`.
///
/// [staticPrivRaw]/[ephPrivRaw]/[tai64nBytes]/[senderIndex] инъектируются для
/// теста; в рантайме не передаются (генерация/текущее время).
Future<Uint8List> buildWgInitiation({
  List<int>? serverPubRaw,
  List<int>? staticPrivRaw,
  List<int>? ephPrivRaw,
  List<int>? tai64nBytes,
  int? senderIndex,
}) async {
  final x25519 = X25519();
  final chacha = Chacha20.poly1305Aead();
  final blake2s = Blake2s();
  final blake2s16 = Blake2s(hashLengthInBytes: 16);

  final serverPub = SimplePublicKey(
    serverPubRaw ?? warpServerPubRaw,
    type: KeyPairType.x25519,
  );
  final staticPair = staticPrivRaw != null
      ? await x25519.newKeyPairFromSeed(staticPrivRaw)
      : await x25519.newKeyPair();
  final ephPair = ephPrivRaw != null
      ? await x25519.newKeyPairFromSeed(ephPrivRaw)
      : await x25519.newKeyPair();

  final staticPub = await staticPair.extractPublicKey();
  final ephPub = await ephPair.extractPublicKey();

  Future<List<int>> h(List<int> data) async => (await blake2s.hash(data)).bytes;

  // HMAC-BLAKE2s вручную: пакет `cryptography` для HMAC-BLAKE2s берёт блочный
  // размер 32 вместо 64 (у BLAKE2s блок 64Б), из-за чего KDF/ck расходятся с
  // WG-спецификацией. Считаем по RFC 2104 с корректным блоком.
  Future<List<int>> hmacB2s(List<int> key, List<int> data) async {
    const block = 64;
    final k = key.length > block ? (await blake2s.hash(key)).bytes : key;
    final kpad = [...k, ...List<int>.filled(block - k.length, 0)];
    final ipad = [for (final b in kpad) b ^ 0x36];
    final opad = [for (final b in kpad) b ^ 0x5C];
    final inner = (await blake2s.hash([...ipad, ...data])).bytes;
    return (await blake2s.hash([...opad, ...inner])).bytes;
  }

  Future<List<int>> mac(List<int> key, List<int> data) async =>
      (await blake2s16.calculateMac(data, secretKey: SecretKey(key))).bytes;

  // KDF (whitepaper): T0 = HMAC(K, input); T1 = HMAC(T0, 0x1) — новый chaining
  // key; T2 = HMAC(T0, T1|0x2) — ключ шифрования.
  Future<(List<int> ck, List<int> key)> kdf2(
    List<int> key,
    List<int> input,
  ) async {
    final t0 = await hmacB2s(key, input);
    final t1 = await hmacB2s(t0, const [1]);
    final t2 = await hmacB2s(t0, [...t1, 2]);
    return (t1, t2);
  }

  // AEAD ChaCha20-Poly1305 → ciphertext||tag (SecretBox держит раздельно).
  Future<List<int>> aead(
    List<int> key,
    List<int> plaintext,
    List<int> aad,
  ) async {
    final box = await chacha.encrypt(
      plaintext,
      secretKey: SecretKey(key),
      nonce: Uint8List(12),
      aad: aad,
    );
    return [...box.cipherText, ...box.mac.bytes];
  }

  var ck = await h(_construction);
  var hs = await h([...ck, ..._identifier]);
  hs = await h([...hs, ...serverPub.bytes]);
  hs = await h([...hs, ...ephPub.bytes]);
  ck = await hmacB2s(ck, ephPub.bytes);
  ck = await hmacB2s(ck, const [1]);

  final ss1 = await (await x25519.sharedSecretKey(
    keyPair: ephPair,
    remotePublicKey: serverPub,
  )).extractBytes();
  final (ck1, key1) = await kdf2(ck, ss1);
  ck = ck1;
  final encStatic = await aead(key1, staticPub.bytes, hs);
  hs = await h([...hs, ...encStatic]);

  final ss2 = await (await x25519.sharedSecretKey(
    keyPair: staticPair,
    remotePublicKey: serverPub,
  )).extractBytes();
  final (_, key2) = await kdf2(ck, ss2);
  final encTs = await aead(key2, tai64nBytes ?? _nowTai64n(), hs);

  final idx = senderIndex ?? _randomUint32();
  final out = BytesBuilder()
    ..addByte(_msgTypeInitiation)
    ..add(const [0, 0, 0]) // reserved
    ..add(_u32le(idx))
    ..add(ephPub.bytes)
    ..add(encStatic)
    ..add(encTs);

  final mac1 = await mac(
    await h([..._labelMac1, ...serverPub.bytes]),
    out.toBytes(),
  );
  out
    ..add(mac1)
    ..add(Uint8List(16)); // mac2 — нули (timestamps не ставим)
  return out.toBytes();
}

/// Классификация ответа эндпоинта. Пустой/короткий ответ, чужой type — junk.
/// [rttMs] подставляется вызывающим (мы измеряем его в сокете).
///
/// §837 — типы сообщений WireGuard (проверено по спецификации,
/// https://www.wireguard.com/protocol/):
///   1 — Handshake Initiation  (148 Б) — это мы и отправляем;
///   2 — Handshake Response    ( 92 Б) ← ТАК отвечает живой сервер;
///   3 — Cookie Reply          ( 64 Б) — сервер под нагрузкой, но ЖИВ;
///   4 — Transport Data        (32+ Б) — транзитный трафик, НЕ ответ на init.
///
/// Раньше 92-байтный ответ принимался только при `type == 4`, то есть живой
/// ответ (type 2) уходил в junk → скан не находил НИ ОДНОГО рабочего
/// эндпоинта. Это и была причина «сканер не находит рабочие».
WgProbeResult classifyWgResponse(List<int>? data, {int rttMs = 0}) {
  if (data == null || data.isEmpty) {
    return WgProbeResult(WgProbeKind.timeout, rttMs: rttMs, detail: 'empty');
  }
  final type = data[0];
  if (data.length == 92 && type == 2) {
    return WgProbeResult(
      WgProbeKind.response,
      rttMs: rttMs,
      detail: 'type2 handshake-response 92B',
    );
  }
  if (data.length == 64 && type == 3) {
    return WgProbeResult(
      WgProbeKind.cookie,
      rttMs: rttMs,
      detail: 'type3 cookie 64B',
    );
  }
  // Диагностика: для «почти ответа» показываем, что именно пришло, чтобы
  // в журнале было видно (148 Б = наше же эхо, 92 Б с чужим type и т.п.).
  final hint = switch ((data.length, type)) {
    (92, _) => ' (92B but type=$type, ждали type=2)',
    (64, _) => ' (64B but type=$type, ждали type=3)',
    (148, 1) => ' (echo нашей же initiation)',
    _ => '',
  };
  return WgProbeResult(
    WgProbeKind.junk,
    rttMs: rttMs,
    detail: 'junk ${data.length}B type=$type$hint',
  );
}

List<int> _u32le(int v) => [
  v & 0xFF,
  (v >> 8) & 0xFF,
  (v >> 16) & 0xFF,
  (v >> 24) & 0xFF,
];

List<int> _u32be(int v) => [
  (v >> 24) & 0xFF,
  (v >> 16) & 0xFF,
  (v >> 8) & 0xFF,
  v & 0xFF,
];

int _randomUint32() {
  final r = Random.secure();
  return r.nextInt(1 << 32) & 0xFFFFFFFF;
}

/// TAI64N: `u64 (secs + 2^62 + 10)` || `u32 (nanos)`.
List<int> _nowTai64n([DateTime? now]) {
  final t = now ?? DateTime.now().toUtc();
  final secs = 0x400000000000000A + (t.millisecondsSinceEpoch ~/ 1000);
  final nanos = (t.millisecondsSinceEpoch % 1000) * 1000000;
  final out = BytesBuilder();
  for (var shift = 56; shift >= 0; shift -= 8) {
    out.addByte((secs >> shift) & 0xFF);
  }
  out.add(_u32be(nanos));
  return out.toBytes();
}

Uint8List _b64(String s) => Uint8List.fromList(_base64Decode(s));

Uint8List _base64Decode(String s) {
  // Локальный base64 (dart:convert я не тяну — файл держим без лишних импортов).
  const table =
      'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/';
  final clean = s.replaceAll(RegExp(r'[^A-Za-z0-9+/=]'), '');
  final out = <int>[];
  var buffer = 0;
  var bits = 0;
  for (final ch in clean.codeUnits) {
    if (ch == 0x3D) break; // '='
    final v = table.indexOf(String.fromCharCode(ch));
    if (v < 0) continue;
    buffer = (buffer << 6) | v;
    bits += 6;
    if (bits >= 8) {
      bits -= 8;
      out.add((buffer >> bits) & 0xFF);
    }
  }
  return Uint8List.fromList(out);
}
