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

  // §103 D-016(в) — не подставлять дефолт на разборе: null, если параметра не
  // было в URI вовсе, иначе нормализованное значение (мусор → тоже null, как
  // будто параметра не было — эмиттер тогда не пишет поле, ядро подставит
  // дефолт само).
  final cc = _normalizeCongestion(q['congestion_control']);
  final urmRaw = q['udp_relay_mode'];
  final urm = urmRaw == null
      ? null
      : (urmRaw.toLowerCase().trim() == 'quic' ? 'quic' : 'native');
  final zeroRtt = (q['reduce_rtt'] ?? q['zero_rtt'] ?? '0') == '1' ||
      (q['reduce_rtt'] ?? q['zero_rtt'] ?? '').toLowerCase() == 'true';

  var sni = q['sni'] ?? '';
  if (sni.isEmpty) sni = server;
  // §103 D-016(в) — alpn=h3 у TUIC это дефолт ПРОТОКОЛА (не эмитится Go, если
  // в URI не было явного alpn), не наше подставленное значение.
  final alpnRaw = q['alpn'];
  final alpn = (alpnRaw == null || alpnRaw.isEmpty)
      ? const <String>[]
      : alpnRaw.split(',').map((e) => e.trim()).toList();

  final tls = TlsSpec(
    enabled: true,
    serverName: q['disable_sni'] == '1' ? null : sni,
    alpn: alpn,
    insecure: isTlsInsecure(q),
  );

  final warnings = <NodeWarning>[];
  if (tls.insecure) warnings.add(const InsecureTlsWarning());

  // §103 D-024 — heartbeat: голое число (секунды) → duration-строка с
  // суффиксом `s`; параметра не было в URI вовсе → null (не эмитим).
  final heartbeatRaw = q['heartbeat'];
  final heartbeat = (heartbeatRaw == null || heartbeatRaw.trim().isEmpty)
      ? null
      : normalizeSingboxDuration(heartbeatRaw.trim());

  return TuicSpec(
    id: newUuidV4(),
    tag: tag,
    label: label,
    server: server,
    port: port,
    rawUri: uri,
    uuid: uuid,
    password: password,
    congestionControl: cc,
    udpRelayMode: urm,
    zeroRtt: zeroRtt,
    tls: tls,
    heartbeat: heartbeat,
    warnings: warnings,
  );
}

/// `null` при отсутствии параметра ИЛИ мусорном значении — оба случая
/// «не задано явно» для эмиттера (§103 D-016(в)): битое значение не должно
/// протащить в конфиг псевдо-явный `cubic`.
String? _normalizeCongestion(String? raw) {
  if (raw == null) return null;
  final s = raw.toLowerCase().trim();
  return {'bbr', 'cubic', 'new_reno'}.contains(s) ? s : null;
}
