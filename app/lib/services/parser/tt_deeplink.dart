/// §717 — бинарная полезная нагрузка deep-link-ссылки TrustTunnel: TLV поверх
/// varint, без имени схемы в логике.
///
/// Здесь только ФОРМАТ: varint, TLV, строковые массивы, DER↔PEM, разбор
/// `host:port`. Какой ссылкой этот формат приезжает и куда уходят его поля,
/// решает секция реестра (черновик `assets/contract_draft/uri/`), а движок
/// зовёт [decodeTtPayload] декодером формы по имени `tt_deeplink`.
///
/// Формат — крейт `deeplink` репозитория TrustTunnel (`types.rs`,
/// `encode.rs`, `decode.rs`, `varint.rs`); текстовой спецификации нет.
///
/// - **varint** — QUIC (RFC 9000 §16), НЕ LEB128: два старших бита первого
///   байта задают длину 1/2/4/8, значение big-endian в остальных 6/14/30/62
///   битах.
/// - **TLV** — tag varint, длина varint, значение.
/// - **bool** — ровно один байт `0x00`/`0x01`.
/// - **строковый массив** — подряд «varint-длина + UTF-8».
///
/// Функции записи ([writeVarint], [encodeTlv], [encodeStringArray],
/// [pemToDer]) — зеркало чтения: энкодер Share (`tt://` из тела) соберётся из
/// них, когда реестр объявит форму эмита.
library;

import 'dart:convert' show base64, utf8;

/// Теги TLV (`types.rs: TlvTag`).
abstract final class TtTag {
  static const version = 0x00;
  static const hostname = 0x01;
  static const address = 0x02;
  static const customSni = 0x03;
  static const hasIpv6 = 0x04;
  static const username = 0x05;
  static const password = 0x06;
  static const skipVerification = 0x07;
  static const certificate = 0x08;
  static const upstreamProtocol = 0x09;
  static const antiDpi = 0x0A;
  static const clientRandomPrefix = 0x0B;
  static const name = 0x0C;
  static const dnsUpstreams = 0x0D;
  static const subscriptionUrl = 0x0E;
  static const clientRandomAuthKey = 0x0F;
}

/// Старшая версия формата, которую читает декодер (`CURRENT_VERSION`).
const kTtMaxVersion = 2;

/// Исход разбора полезной нагрузки.
enum TtFailure {
  /// Битый base64, обрыв varint/TLV, не-UTF-8, неверный bool/протокол,
  /// версия выше [kTtMaxVersion].
  invalid,

  /// Ссылка несёт только адрес подписки, полей узла нет.
  subscriptionOnly,
}

/// Результат [decodeTtPayload]: объект пространства формы либо причина отказа.
typedef TtDecodeResult = ({Map<String, dynamic>? doc, TtFailure? failure});

class _TtFormatError implements Exception {
  const _TtFormatError();
}

/// QUIC-varint с позиции [offset]: значение и позиция за ним.
(int, int) readVarint(List<int> data, int offset) {
  if (offset >= data.length) throw const _TtFormatError();
  final first = data[offset] & 0xFF;
  final len = 1 << (first >> 6);
  if (offset + len > data.length) throw const _TtFormatError();
  var value = first & 0x3F;
  for (var i = 1; i < len; i++) {
    value = (value << 8) | (data[offset + i] & 0xFF);
  }
  return (value, offset + len);
}

/// QUIC-varint значения [value] (0 … 2^62−1) — зеркало [readVarint].
List<int> writeVarint(int value) {
  if (value < 0) throw ArgumentError.value(value, 'value');
  if (value <= 0x3F) return [value];
  if (value <= 0x3FFF) return [0x40 | (value >> 8), value & 0xFF];
  if (value <= 0x3FFFFFFF) {
    return [
      0x80 | (value >> 24),
      (value >> 16) & 0xFF,
      (value >> 8) & 0xFF,
      value & 0xFF,
    ];
  }
  return [
    0xC0 | ((value >> 56) & 0x3F),
    for (var s = 48; s >= 0; s -= 8) (value >> s) & 0xFF,
  ];
}

/// Одно поле TLV — зеркало разбора в [decodeTtPayload].
List<int> encodeTlv(int tag, List<int> value) =>
    [...writeVarint(tag), ...writeVarint(value.length), ...value];

/// Строковый массив: «varint-длина + UTF-8» подряд.
List<int> encodeStringArray(Iterable<String> items) => [
      for (final s in items) ...[
        ...writeVarint(utf8.encode(s).length),
        ...utf8.encode(s),
      ],
    ];

List<String> _decodeStringArray(List<int> data) {
  final out = <String>[];
  var off = 0;
  while (off < data.length) {
    final (len, next) = readVarint(data, off);
    if (next + len > data.length) throw const _TtFormatError();
    out.add(_utf8(data.sublist(next, next + len)));
    off = next + len;
  }
  return out;
}

String _utf8(List<int> bytes) {
  try {
    return utf8.decode(bytes);
  } on FormatException {
    throw const _TtFormatError();
  }
}

bool _bool(List<int> v) {
  if (v.length != 1 || v[0] > 1) throw const _TtFormatError();
  return v[0] == 1;
}

/// DER сертификата → PEM: base64 строками по 64 символа.
String derToPem(List<int> der) {
  final b64 = base64.encode(der);
  final lines = <String>[
    for (var i = 0; i < b64.length; i += 64)
      b64.substring(i, i + 64 > b64.length ? b64.length : i + 64),
  ];
  return '-----BEGIN CERTIFICATE-----\n${lines.join('\n')}\n'
      '-----END CERTIFICATE-----';
}

/// PEM → DER первого блока `CERTIFICATE`; `null` — блока нет или base64 битый.
List<int>? pemToDer(String pem) {
  final m = RegExp(
          r'-----BEGIN CERTIFICATE-----([\s\S]*?)-----END CERTIFICATE-----')
      .firstMatch(pem);
  if (m == null) return null;
  try {
    return base64.decode(m.group(1)!.replaceAll(RegExp(r'\s+'), ''));
  } on FormatException {
    return null;
  }
}

/// `host:port` / `[v6]:port` / `host` → адрес без скобок и порт (`null` —
/// порта нет или он не число 1…65535).
(String, int?) splitHostPort(String address) {
  final a = address.trim();
  if (a.startsWith('[')) {
    final close = a.indexOf(']');
    if (close > 0) {
      final host = a.substring(1, close);
      final rest = a.substring(close + 1);
      return (host, rest.startsWith(':') ? _port(rest.substring(1)) : null);
    }
  }
  final colon = a.lastIndexOf(':');
  // Двоеточий больше одного без скобок — голый IPv6 без порта.
  if (colon < 0 || a.indexOf(':') != colon) return (a, null);
  return (a.substring(0, colon), _port(a.substring(colon + 1)));
}

int? _port(String s) {
  final p = int.tryParse(s);
  return p != null && p > 0 && p <= 0xFFFF ? p : null;
}

/// Разобрать байты полезной нагрузки (уже из base64url) в объект
/// пространства формы.
///
/// Ключи объекта — имена полей формата (`hostname`, `custom_sni`, …); ключа
/// нет, если нет тега. Булевы поля кладутся, только когда отличаются от
/// умолчания формата (`has_ipv6` — `false`, `anti_dpi` и
/// `skip_verification` — `true`): умолчание человек не просил, и называть
/// его непрочитанным незачем. `upstream_protocol` есть всегда (`http2`, если
/// тега нет). Производные первого адреса — `address`, `server`,
/// `server_port`; адреса со второго — `extra_addresses`.
///
/// Неизвестный тег пропускается (как у референса).
TtDecodeResult decodeTtPayload(List<int> payload) {
  try {
    return (doc: _decode(payload), failure: null);
  } on _TtFormatError {
    return (doc: null, failure: TtFailure.invalid);
  } on _TtSubscriptionOnly {
    return (doc: null, failure: TtFailure.subscriptionOnly);
  }
}

class _TtSubscriptionOnly implements Exception {
  const _TtSubscriptionOnly();
}

Map<String, dynamic> _decode(List<int> payload) {
  if (payload.isEmpty) throw const _TtFormatError();
  final doc = <String, dynamic>{};
  final addresses = <String>[];
  var protocol = 'http2';
  var off = 0;
  while (off < payload.length) {
    final (tag, afterTag) = readVarint(payload, off);
    final (len, afterLen) = readVarint(payload, afterTag);
    if (afterLen + len > payload.length) throw const _TtFormatError();
    final v = payload.sublist(afterLen, afterLen + len);
    off = afterLen + len;
    switch (tag) {
      case TtTag.version:
        final (ver, _) = readVarint(v, 0);
        if (ver > kTtMaxVersion) throw const _TtFormatError();
        doc['version'] = ver;
      case TtTag.hostname:
        doc['hostname'] = _utf8(v);
      case TtTag.address:
        addresses.add(_utf8(v));
      case TtTag.customSni:
        doc['custom_sni'] = _utf8(v);
      case TtTag.hasIpv6:
        if (!_bool(v)) doc['has_ipv6'] = false;
      case TtTag.username:
        doc['username'] = _utf8(v);
      case TtTag.password:
        doc['password'] = _utf8(v);
      case TtTag.skipVerification:
        if (_bool(v)) doc['skip_verification'] = true;
      case TtTag.certificate:
        if (v.isNotEmpty) doc['certificate'] = derToPem(v);
      case TtTag.upstreamProtocol:
        if (v.length != 1) throw const _TtFormatError();
        protocol = switch (v[0]) {
          0x01 => 'http2',
          0x02 => 'http3',
          _ => throw const _TtFormatError(),
        };
      case TtTag.antiDpi:
        if (_bool(v)) doc['anti_dpi'] = true;
      case TtTag.clientRandomPrefix:
        doc['client_random_prefix'] = _utf8(v);
      case TtTag.name:
        doc['name'] = _utf8(v);
      case TtTag.dnsUpstreams:
        final list = _decodeStringArray(v);
        if (list.isNotEmpty) doc['dns_upstreams'] = list;
      case TtTag.subscriptionUrl:
        doc['subscription_url'] = _utf8(v);
      case TtTag.clientRandomAuthKey:
        doc['client_random_auth_key'] = _utf8(v);
      default:
        break;
    }
  }
  doc['upstream_protocol'] = protocol;
  if (addresses.isNotEmpty) {
    doc['address'] = addresses.first;
    final (host, port) = splitHostPort(addresses.first);
    doc['server'] = host;
    if (port != null) doc['server_port'] = port;
    if (addresses.length > 1) doc['extra_addresses'] = addresses.sublist(1);
  }
  if (doc.containsKey('subscription_url') &&
      !doc.containsKey('hostname') &&
      addresses.isEmpty &&
      !doc.containsKey('username') &&
      !doc.containsKey('password')) {
    throw const _TtSubscriptionOnly();
  }
  return doc;
}
