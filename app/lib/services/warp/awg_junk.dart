import 'dart:math';

import '../util/pseudo_gen.dart';
import 'quic_i1.dart';

/// §126/§136 — генератор junk-пакета `i1` для AmneziaWG обфускации WARP.
///
/// `i1` — это «лишний» пакет, который AmneziaWG шлёт ПЕРЕД настоящим WG
/// handshake. Сервер (Cloudflare = обычный WG) его игнорирует, а DPI видит
/// поток, начинающийся НЕ с ожидаемой WG-сигнатуры `01 00 00 00`+148b → не
/// матчит шаблон. Цель — мимикрия под живой протокол + уникальность каждого
/// пакета (нет общей сигнатуры между юзерами).
///
/// Формат — CPS-теги AmneziaWG (`<b 0xHEX>`, `<r N>`). Совместим с
/// `Awg.strKeys` / `parseWireguardUri` (i* как строки, регистр сохраняется).
///
/// **§136 (реверс `warp-generator.github.io`, 2026-06-16):** слабый WG-traffic
/// decoy УБРАН — эмпирически не пробивал DPI (field-report Iliya). Заменён на
/// **QUIC** (настоящий QUIC Initial с `<r>`-нарезкой, см. [QuicI1]). SIP оставлен
/// как второй вариант.
enum JunkTemplate {
  /// Настоящий QUIC Initial (голый SNI-ClientHello) с CPS-нарезкой `<b>/<r>`.
  /// Главный шаблон — мимикрия под HTTP/3 к популярному домену. См. [QuicI1].
  quic,

  /// Маскирует junk под VoIP: валидный по RFC 3261 SIP-INVITE со ВСЕМИ
  /// рандомизированными полями (DPI обычно не режет телефонию).
  sip,
}

/// Параметры QUIC-шаблона (Advanced). [sni] пустой → caller подставляет рандом
/// из пула. [level] 0–4 — стратегия нарезки `<b>/<r>` (как `level` в quic.js).
class QuicParams {
  const QuicParams({
    this.sni = '',
    this.level = 0,
    this.jc = 4,
    this.jmin = 40,
    this.jmax = 70,
  });

  final String sni;
  final int level;
  final int jc;
  final int jmin;
  final int jmax;

  QuicParams copyWith({String? sni, int? level, int? jc, int? jmin, int? jmax}) =>
      QuicParams(
        sni: sni ?? this.sni,
        level: level ?? this.level,
        jc: jc ?? this.jc,
        jmin: jmin ?? this.jmin,
        jmax: jmax ?? this.jmax,
      );
}

/// Генерирует `i1` для SIP-шаблона. Возвращает CPS-тег `<b 0xHEX>`.
/// Каждый вызов уникален ([Random.secure]). Для QUIC см. [QuicI1.generate].
String generateSipI1() => _toCpsTag(_sipTrafficJunk());

/// Генерирует `i1` для QUIC-шаблона ([sni] не пустой). Делегат в [QuicI1].
String generateQuicI1(String sni, {int level = 0}) =>
    QuicI1.generate(sni, level: level);

final Random _rng = Random.secure();

/// `<b 0x<hex>>` — байты → непрерывный lowercase-hex.
String _toCpsTag(List<int> bytes) {
  final hex = StringBuffer();
  for (final b in bytes) {
    hex.write((b & 0xff).toRadixString(16).padLeft(2, '0'));
  }
  return '<b 0x$hex>';
}

/// SIP-traffic. Валидный по RFC 3261 INVITE, но КАЖДОЕ поле
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
