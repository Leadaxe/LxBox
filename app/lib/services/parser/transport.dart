import '../../models/transport_spec.dart';
import '../../models/tls_spec.dart';
import 'uri_utils.dart';

/// Разбор query-параметров URI в `TransportSpec?`.
///
/// sing-box поддерживает: http | ws | quic | grpc | httpupgrade.
/// XHTTP → `XhttpTransport` (fallback в toSingbox).
///
/// [networkOverride] — если транспорт лежит под другим ключом, чем `type`
/// (VMess хранит в `network`). [defaultHost] — fallback для h2 когда
/// `q['host']`/`q['sni']` пусты.
TransportSpec? parseTransport(
  Map<String, String> q, {
  String? networkOverride,
  String? defaultHost,
}) {
  var typ = ((networkOverride ?? q['type']) ?? '').toLowerCase().trim();
  final headerType = (q['headerType'] ?? '').toLowerCase().trim();

  if ((typ == 'raw' || typ == 'tcp') && headerType == 'http') {
    final path = q['path'] ?? '/';
    final host = q['host'] ?? '';
    return HttpTransport(
      path: path,
      hosts: host.isNotEmpty ? [host] : const [],
    );
  }

  switch (typ) {
    case 'ws':
      final path = q['path'] ?? '/';
      var host = (q['host'] ?? '').trim();
      if (host.isEmpty) host = (q['sni'] ?? '').trim();
      if (host.isEmpty) host = (q['obfsParam'] ?? '').trim();
      return WsTransport(path: path, host: host);
    case 'grpc':
      final sn = (q['serviceName'] ?? q['service_name'] ?? q['path'] ?? '').trim();
      return GrpcTransport(serviceName: sn);
    case 'http':
      final path = q['path'] ?? '/';
      final host = (q['host'] ?? '').trim();
      return HttpTransport(
        path: path,
        hosts: host.isNotEmpty ? [host] : const [],
      );
    case 'h2':
      final path = q['path'] ?? '/';
      var host = (q['host'] ?? '').trim();
      if (host.isEmpty) host = (q['sni'] ?? '').trim();
      if (host.isEmpty && defaultHost != null) host = defaultHost;
      return HttpTransport(
        path: path,
        hosts: host.isNotEmpty ? [host] : const [],
      );
    case 'httpupgrade':
      final path = q['path'] ?? '/';
      var host = (q['host'] ?? '').trim();
      if (host.isEmpty) host = (q['sni'] ?? '').trim();
      return HttpUpgradeTransport(path: path, host: host);
    case 'xhttp':
      final path = q['path'] ?? '/';
      var host = (q['host'] ?? '').trim();
      if (host.isEmpty) host = (q['sni'] ?? '').trim();
      return XhttpTransport(path: path, host: host);
    case 'raw':
    case 'tcp':
    case '':
      return null;
    default:
      return null;
  }
}

/// TLS parameters for VLESS (с поддержкой REALITY через `pbk`/`sid`).
TlsSpec parseVlessTls(Map<String, String> q, String server, int port) {
  final sec = (q['security'] ?? '').toLowerCase().trim();
  final pbk = (q['pbk'] ?? '').trim();

  if (sec == 'none') return TlsSpec.disabled;

  var sni = q['sni'] ?? q['peer'] ?? '';
  if (sni.isEmpty) sni = server;
  var fp = (q['fp'] ?? q['fingerprint'] ?? '').toLowerCase().trim();
  if (fp.isEmpty) fp = 'random';

  if (pbk.isNotEmpty) {
    return TlsSpec(
      enabled: true,
      serverName: sni,
      fingerprint: fp,
      reality: RealitySpec(
        publicKey: pbk,
        shortId: normalizeRealityShortId(q['sid'] ?? ''),
      ),
      insecure: isTlsInsecure(q),
      alpn: _alpnFromQuery(q),
    );
  }

  if (sec == 'reality') {
    return TlsSpec(
      enabled: true,
      serverName: sni,
      fingerprint: fp,
      insecure: isTlsInsecure(q),
      alpn: _alpnFromQuery(q),
    );
  }

  if (sec.isEmpty && plaintextVlessPorts.contains(port)) return TlsSpec.disabled;

  return TlsSpec(
    enabled: true,
    serverName: sni,
    fingerprint: fp,
    insecure: isTlsInsecure(q),
    alpn: _alpnFromQuery(q),
  );
}

/// TLS parameters for Trojan.
TlsSpec parseTrojanTls(Map<String, String> q, String server) {
  final sec = (q['security'] ?? '').toLowerCase().trim();
  if (sec == 'none') return TlsSpec.disabled;

  var sni = q['sni'] ?? q['peer'] ?? q['host'] ?? '';
  if (sni.isEmpty) sni = server;
  final fp = (q['fp'] ?? '').toLowerCase().trim();

  return TlsSpec(
    enabled: true,
    serverName: sni,
    fingerprint: fp.isEmpty ? null : fp,
    insecure: isTlsInsecure(q),
    alpn: _alpnFromQuery(q),
  );
}

/// TLS parameters for VMess (активируется при `tls=tls` или `h2`).
TlsSpec parseVmessTls(Map<String, dynamic> cfg, String server, String net) {
  final tlsEnabled = cfg['tls'] == 'tls' || net == 'h2';
  if (!tlsEnabled) return TlsSpec.disabled;

  var sni = cfg['sni']?.toString() ?? '';
  if (sni.isEmpty) sni = cfg['host']?.toString() ?? '';
  if (sni.isEmpty) sni = server;

  final alpn = cfg['alpn']?.toString() ?? '';
  final fp = (cfg['fp']?.toString() ?? '').toLowerCase().trim();

  return TlsSpec(
    enabled: true,
    serverName: sni,
    fingerprint: fp.isEmpty ? null : fp,
    insecure: cfg['insecure'] == '1' || cfg['insecure'] == true,
    alpn:
        alpn.isEmpty ? const [] : alpn.split(',').map((e) => e.trim()).toList(),
  );
}

List<String> _alpnFromQuery(Map<String, String> q) {
  final raw = q['alpn'] ?? '';
  if (raw.isEmpty) return const [];
  return raw.split(',').map((e) => e.trim()).where((e) => e.isNotEmpty).toList();
}

/// Emit TransportSpec → строка query для `toUri()`. Возвращает пары
/// `type`/`path`/`host`/`serviceName`, игнорируя пустые.
Map<String, String> transportToQuery(TransportSpec t) {
  switch (t) {
    case WsTransport(path: final p, host: final h):
      return {
        'type': 'ws',
        if (p.isNotEmpty && p != '/') 'path': p,
        if (h.isNotEmpty) 'host': h,
      };
    case GrpcTransport(serviceName: final sn):
      return {
        'type': 'grpc',
        if (sn.isNotEmpty) 'serviceName': sn,
      };
    case HttpTransport(path: final p, hosts: final hs):
      return {
        'type': 'http',
        if (p.isNotEmpty && p != '/') 'path': p,
        if (hs.isNotEmpty) 'host': hs.join(','),
      };
    case HttpUpgradeTransport(path: final p, host: final h):
      return {
        'type': 'httpupgrade',
        if (p.isNotEmpty && p != '/') 'path': p,
        if (h.isNotEmpty) 'host': h,
      };
    case XhttpTransport(path: final p, host: final h):
      return {
        'type': 'xhttp',
        if (p.isNotEmpty && p != '/') 'path': p,
        if (h.isNotEmpty) 'host': h,
      };
  }
}
