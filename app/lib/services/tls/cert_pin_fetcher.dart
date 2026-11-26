/// Снятие отпечатка сертификата сервера для `tls.peer_fingerprint`: TLS
/// прямо из процесса приложения, без проверки цепочки, первый сертификат
/// (лист) → `pin-sha256:<base64(sha256(SubjectPublicKeyInfo DER))>` —
/// формат ядра sing-box-lx. Без Flutter: подменяется в тестах через
/// [CertPinFetcher].
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';

/// Префикс отпечатка SPKI в формате ядра.
const kPinSha256Prefix = 'pin-sha256:';

/// Адрес сервера для TLS: хост (IPv6 без скобок) и порт.
typedef CertPinTarget = ({String host, int port});

/// Разобрать поле `server` формы: `host`, `host:port`,
/// `https://host[:port][/path]`, `[v6]:port`, голый IPv6. Порт по умолчанию
/// 443. Пусто или негодно — `null`.
CertPinTarget? parseCertPinTarget(String raw) {
  final s = raw.trim();
  if (s.isEmpty) return null;
  // Голый IPv6 без скобок: двоеточий больше одного, схемы и скобок нет.
  if (!s.contains('://') &&
      !s.contains('[') &&
      ':'.allMatches(s).length > 1) {
    return InternetAddress.tryParse(s) == null ? null : (host: s, port: 443);
  }
  final Uri uri;
  try {
    uri = Uri.parse(s.contains('://') ? s : 'https://$s');
  } on FormatException {
    return null;
  }
  final host = uri.host;
  if (host.isEmpty || host.contains(' ')) return null;
  final port = uri.hasPort ? uri.port : 443;
  if (port < 1 || port > 65535) return null;
  return (host: host, port: port);
}

/// Почему отпечаток не снят.
enum CertPinError { noAddress, resolve, timeout, notTls, other }

class CertPinException implements Exception {
  const CertPinException(this.kind, [this.detail]);
  final CertPinError kind;
  final String? detail;
  @override
  String toString() => 'CertPinException($kind${detail == null ? '' : ': $detail'})';
}

/// Что показать пользователю перед закреплением.
class CertPinInfo {
  const CertPinInfo({
    required this.subject,
    required this.issuer,
    required this.notAfter,
    required this.pin,
  });

  /// На кого выдан (CN, иначе строка subject целиком).
  final String subject;

  /// Кем подписан (CN, иначе строка issuer целиком).
  final String issuer;

  /// Действует до.
  final DateTime? notAfter;

  /// `pin-sha256:<base64>`.
  final String pin;
}

/// Снимает отпечаток с сервера.
abstract class CertPinFetcher {
  /// [server] — значение поля `server`; [serverName] — SNI (`tls.server_name`),
  /// пусто — хост из адреса. Ошибка — [CertPinException].
  Future<CertPinInfo> fetch(String server, {String? serverName});
}

/// Реальный fetcher: `Socket.connect` + `SecureSocket.secure`.
class IoCertPinFetcher implements CertPinFetcher {
  const IoCertPinFetcher({this.timeout = const Duration(seconds: 10)});

  final Duration timeout;

  @override
  Future<CertPinInfo> fetch(String server, {String? serverName}) async {
    final target = parseCertPinTarget(server);
    if (target == null) throw const CertPinException(CertPinError.noAddress);
    final sni = (serverName ?? '').trim();
    Socket? raw;
    SecureSocket? tls;
    try {
      raw = await Socket.connect(target.host, target.port, timeout: timeout);
      tls = await SecureSocket.secure(
        raw,
        host: sni.isEmpty ? target.host : sni,
        onBadCertificate: (_) => true,
      ).timeout(timeout);
      final cert = tls.peerCertificate;
      if (cert == null) throw const CertPinException(CertPinError.notTls);
      return CertPinInfo(
        subject: distinguishedNameCn(cert.subject),
        issuer: distinguishedNameCn(cert.issuer),
        notAfter: cert.endValidity,
        pin: pinFromCertificateDer(cert.der),
      );
    } on CertPinException {
      rethrow;
    } on TimeoutException {
      throw const CertPinException(CertPinError.timeout);
    } on SocketException catch (e) {
      final msg = e.message.toLowerCase();
      if (msg.contains('timed out')) {
        throw CertPinException(CertPinError.timeout, e.message);
      }
      if (msg.contains('lookup') || msg.contains('host')) {
        throw CertPinException(CertPinError.resolve, e.message);
      }
      throw CertPinException(CertPinError.other, e.message);
    } on HandshakeException catch (e) {
      throw CertPinException(CertPinError.notTls, e.message);
    } on TlsException catch (e) {
      throw CertPinException(CertPinError.notTls, e.message);
    } on FormatException catch (e) {
      throw CertPinException(CertPinError.notTls, e.message);
    } finally {
      tls?.destroy();
      if (tls == null) raw?.destroy();
    }
  }
}

/// CN из строки DN вида `/C=US/O=Org/CN=name` или `CN=name, O=Org`; нет CN —
/// строка целиком.
String distinguishedNameCn(String dn) {
  final m = RegExp(r'(?:^|[/,]\s*)CN=([^/,]+)').firstMatch(dn);
  return m == null ? dn.trim() : m.group(1)!.trim();
}

/// `pin-sha256:` по DER сертификата X.509. Негодный DER — [FormatException].
String pinFromCertificateDer(Uint8List der) =>
    '$kPinSha256Prefix${base64.encode(sha256.convert(spkiFromCertificateDer(der)).bytes)}';

/// Байты SubjectPublicKeyInfo (TLV целиком) из DER сертификата:
/// Certificate → tbsCertificate → [version] serial sigAlg issuer validity
/// subject **spki**.
Uint8List spkiFromCertificateDer(Uint8List der) {
  final cert = _tlv(der, 0);
  if (cert.tag != 0x30) throw const FormatException('certificate: not a SEQUENCE');
  final tbs = _tlv(der, cert.valueStart);
  if (tbs.tag != 0x30) throw const FormatException('tbsCertificate: not a SEQUENCE');
  var pos = tbs.valueStart;
  var first = _tlv(der, pos);
  // [0] version есть у v2/v3, у v1 его нет.
  if (first.tag == 0xA0) pos = first.end;
  // serial, signature, issuer, validity, subject.
  for (var i = 0; i < 5; i++) {
    pos = _tlv(der, pos).end;
  }
  final spki = _tlv(der, pos);
  if (spki.tag != 0x30 || spki.end > tbs.end) {
    throw const FormatException('subjectPublicKeyInfo: not found');
  }
  return Uint8List.sublistView(der, spki.start, spki.end);
}

typedef _Tlv = ({int tag, int start, int valueStart, int end});

_Tlv _tlv(Uint8List b, int start) {
  if (start + 2 > b.length) throw const FormatException('DER: truncated');
  final tag = b[start];
  if (tag & 0x1F == 0x1F) throw const FormatException('DER: long tag');
  var p = start + 1;
  var len = b[p++];
  if (len & 0x80 != 0) {
    final n = len & 0x7F;
    if (n == 0 || n > 4 || p + n > b.length) {
      throw const FormatException('DER: bad length');
    }
    len = 0;
    for (var i = 0; i < n; i++) {
      len = (len << 8) | b[p++];
    }
  }
  final end = p + len;
  if (end > b.length) throw const FormatException('DER: truncated');
  return (tag: tag, start: start, valueStart: p, end: end);
}
