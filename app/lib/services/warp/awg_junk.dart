import 'dart:math';

import '../util/pseudo_gen.dart';

/// §126 — генератор junk-пакета `i1` для AmneziaWG 1.5 обфускации WARP.
///
/// `i1` — это «лишний» пакет, который AmneziaWG шлёт ПЕРЕД настоящим WG
/// handshake. Сервер (Cloudflare = обычный WG) его игнорирует, а DPI видит
/// поток, начинающийся НЕ с ожидаемой WG-сигнатуры `01 00 00 00`+148b → не
/// матчит шаблон. Цель — мимикрия под другой трафик + уникальность каждого
/// пакета (нет общей сигнатуры между юзерами).
///
/// Формат — CPS-тег AmneziaWG `<b 0xHEX>` (байты пакета в hex). Совместим с
/// `Awg.strKeys` / `parseWireguardUri` (i* как строки, регистр сохраняется).
///
/// **Реверс `warp-generator.github.io` (2026-06-15):** их `i1` —
/// захардкоженные константы (pseudo-WG `<b 0xce000000…>` и канонический
/// RFC 3261 `INVITE sip:bob@biloxi.com`). Мы НЕ копируем константу: копия =
/// общий DPI-маяк. Генерируем своё с рандомизацией.
enum JunkTemplate {
  /// Маскирует junk под «ещё один WG-пакет»: fake type-байт + `00 00 00`
  /// (как reserved в WG-заголовке) + случайное тело ~1250 байт.
  wgTraffic,

  /// Маскирует junk под VoIP: валидный по RFC 3261 SIP-INVITE со ВСЕМИ
  /// рандомизированными полями (DPI обычно не режет телефонию).
  sipTraffic,
}

/// Генерирует `i1` для выбранного шаблона. Возвращает CPS-тег `<b 0xHEX>`.
/// Каждый вызов уникален ([Random.secure]).
String generateJunkI1(JunkTemplate template) {
  final bytes = switch (template) {
    JunkTemplate.wgTraffic => _wgTrafficJunk(),
    JunkTemplate.sipTraffic => _sipTrafficJunk(),
  };
  return _toCpsTag(bytes);
}

final Random _rng = Random.secure();

/// `<b 0x<hex>>` — байты → непрерывный lowercase-hex.
String _toCpsTag(List<int> bytes) {
  final hex = StringBuffer();
  for (final b in bytes) {
    hex.write((b & 0xff).toRadixString(16).padLeft(2, '0'));
  }
  return '<b 0x$hex>';
}

/// Template A — WG-traffic.
///
/// `byte[0]` = fake type (НЕ 1/2/3/4 — иначе примут за валидный WG-тип),
/// `byte[1..3]` = `00 00 00` (как reserved в WG), `byte[4..]` = случайные
/// байты, общая длина ~1200–1400 (рандомизируем в диапазоне).
List<int> _wgTrafficJunk() {
  // fake type ∈ [5..255] (исключаем валидные WG message-types 1..4 и 0).
  final fakeType = 5 + _rng.nextInt(251);
  final bodyLen = 1200 + _rng.nextInt(201); // 1200..1400
  final out = <int>[fakeType, 0, 0, 0];
  for (var i = 0; i < bodyLen; i++) {
    out.add(_rng.nextInt(256));
  }
  return out;
}

/// Template B — SIP-traffic. Валидный по RFC 3261 INVITE, но КАЖДОЕ поле
/// рандомизировано (user/host — [PseudoGen], branch/tag/Call-ID/CSeq/port —
/// случайный hex/digits). Никаких узнаваемых констант (`bob@biloxi.com` и т.п.).
List<int> _sipTrafficJunk() {
  final user1 = PseudoGen.user();
  final user2 = PseudoGen.user();
  final host1 = PseudoGen.host();
  final host2 = PseudoGen.host();
  final viaHost = PseudoGen.host();
  final port1 = _randPort();
  final port2 = _randPort();
  final branch = _randHex(20);
  final tag = _randDigits(10);
  final callId = '${_randHex(24)}@$host2';
  final cseq = 1 + _rng.nextInt(99999);

  // \r\n — канонический CRLF SIP-разделитель.
  final lines = [
    'INVITE sip:$user1@$host1 SIP/2.0',
    'Via: SIP/2.0/UDP $viaHost:$port1;branch=z9hG4bK$branch',
    'Max-Forwards: 70',
    'To: <sip:$user1@$host1>',
    'From: <sip:$user2@$host2>;tag=$tag',
    'Call-ID: $callId',
    'CSeq: $cseq INVITE',
    'Contact: <sip:$user2@$host2:$port2>',
    'Content-Type: application/sdp',
    'Content-Length: 0',
    '',
    '',
  ];
  return _ascii(lines.join('\r\n'));
}

/// Случайный порт 1024..65535 (как у реальных SIP-эндпоинтов).
int _randPort() => 1024 + _rng.nextInt(64512);

/// Строка из `len` hex-символов (lowercase).
String _randHex(int len) {
  const hex = '0123456789abcdef';
  final b = StringBuffer();
  for (var i = 0; i < len; i++) {
    b.write(hex[_rng.nextInt(16)]);
  }
  return b.toString();
}

/// Строка из `len` цифр (первая не 0 — выглядит как реальное число).
String _randDigits(int len) {
  final b = StringBuffer()..write(1 + _rng.nextInt(9));
  for (var i = 1; i < len; i++) {
    b.write(_rng.nextInt(10));
  }
  return b.toString();
}

/// ASCII-байты строки (SIP — текстовый ASCII-протокол; PseudoGen даёт только
/// `[a-z0-9._:@-]`, всё < 128).
List<int> _ascii(String s) => s.codeUnits;
