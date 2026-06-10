import '../../../models/node_spec.dart';
import '../../../models/node_warning.dart';
import '../../../models/tls_spec.dart';
import '../uri_utils.dart';

// ════════════════════════════════════════════════════════════════════════════
// TUIC v5 — новый протокол в v2.
// ════════════════════════════════════════════════════════════════════════════

TuicSpec? parseTuic(String uri) {
  final p = Uri.tryParse(uri);
  if (p == null || p.host.isEmpty || p.userInfo.isEmpty) return null;

  final userParts = p.userInfo.split(':');
  if (userParts.length < 2) return null;
  final uuid = Uri.decodeComponent(userParts.first);
  final password = Uri.decodeComponent(userParts.sublist(1).join(':'));
  if (uuid.isEmpty || password.isEmpty) return null;

  final server = p.host;
  final port = p.hasPort ? p.port : 443;
  final q = Map<String, String>.from(p.queryParameters);
  final label = decodeFragment(p.fragment);
  final tag = tagFromLabel(label, 'tuic', server, port);

  final cc = (q['congestion_control'] ?? 'cubic').toLowerCase().trim();
  final urm = (q['udp_relay_mode'] ?? 'native').toLowerCase().trim();
  final zeroRtt = (q['reduce_rtt'] ?? q['zero_rtt'] ?? '0') == '1' ||
      (q['reduce_rtt'] ?? q['zero_rtt'] ?? '').toLowerCase() == 'true';

  var sni = q['sni'] ?? '';
  if (sni.isEmpty) sni = server;
  final alpn = (q['alpn'] ?? 'h3').split(',').map((e) => e.trim()).toList();

  final tls = TlsSpec(
    enabled: true,
    serverName: q['disable_sni'] == '1' ? null : sni,
    alpn: alpn,
    insecure: isTlsInsecure(q),
  );

  final warnings = <NodeWarning>[];
  if (tls.insecure) warnings.add(const InsecureTlsWarning());

  return TuicSpec(
    id: newUuidV4(),
    tag: tag,
    label: label,
    server: server,
    port: port,
    rawUri: uri,
    uuid: uuid,
    password: password,
    congestionControl: _normalizeCongestion(cc),
    udpRelayMode: urm == 'quic' ? 'quic' : 'native',
    zeroRtt: zeroRtt,
    tls: tls,
    warnings: warnings,
  );
}

String _normalizeCongestion(String s) =>
    {'bbr', 'cubic', 'new_reno'}.contains(s) ? s : 'cubic';
