import '../../../models/node_spec.dart';
import '../../../models/node_warning.dart';
import '../transport.dart';
import '../uri_utils.dart';
import '../utls_fingerprint.dart';

// ════════════════════════════════════════════════════════════════════════════
// VLESS
// ════════════════════════════════════════════════════════════════════════════

VlessSpec? parseVless(String uri) {
  final p = Uri.tryParse(uri);
  if (p == null || p.host.isEmpty || p.userInfo.isEmpty) return null;

  final uuid = Uri.decodeComponent(p.userInfo.split(':').first);
  final server = p.host;
  final port = p.hasPort ? p.port : 443;
  final q = Map<String, String>.from(p.queryParameters);
  final label = decodeFragment(p.fragment);
  final tag = tagFromLabel(label, 'vless', server, port);

  final warnings = <NodeWarning>[];
  final transport = parseTransport(q, warnings: warnings);
  // §281 — fp вне словаря ядра = fatal всего конфига; канонизируем на входе.
  final tls = normalizeTlsFingerprint(
      parseVlessTls(q, server, port, warnings: warnings), warnings);

  var flow = (q['flow'] ?? '').trim();
  var packetEncoding = '';

  // v1 quirk: flow=xtls-rprx-vision-udp443 → vision + packet_encoding=xudp.
  if (flow == 'xtls-rprx-vision-udp443') {
    flow = 'xtls-rprx-vision';
    packetEncoding = 'xudp';
  }
  // §115 — flow = источник истины ссылка, НЕ угадываем по REALITY (раньше
  // bare-TCP+REALITY без flow получал навязанный vision → ломались валидные
  // none-сетапы). vision валиден только на голом TLS: с транспортом
  // (ws/grpc/xhttp) несовместим → гасим flow + warning (ядро такую
  // комбинацию не поднимет; XHTTP+Vision — protocol limitation).
  if (flow == 'xtls-rprx-vision' && transport != null) {
    warnings.add(VisionWithTransportWarning(q['type'] ?? 'transport'));
    flow = '';
  }
  // packet_encoding: sing-box принимает только {"", xudp, packetaddr};
  // xray-style `none` и любой мусор → panic в libbox. Allow-list нормализуем
  // на входе, чтобы emit'ить безопасно. См. normalizePacketEncoding.
  if (packetEncoding.isEmpty) {
    final raw = queryParamCI(q, 'packetEncoding') ?? '';
    packetEncoding = normalizePacketEncoding(raw, tag: tag, warnings: warnings);
  }

  if (tls.insecure) warnings.add(const InsecureTlsWarning());

  // §335 — постквантовый слой VLESS (ядро: SPEC 032). Берём как есть, без
  // нормализации и валидации: ключ — base64url до ~1600 символов, любую
  // порчу строки ядро отвергнет само. `none` = слой выключен, эквивалент
  // пустого значения (эмит его не пишет).
  final encryption = (q['encryption'] ?? '').trim();

  return VlessSpec(
    id: newUuidV4(),
    tag: tag,
    label: label,
    server: server,
    port: port,
    rawUri: uri,
    uuid: uuid,
    flow: flow,
    tls: tls,
    transport: transport,
    packetEncoding: packetEncoding,
    encryption: encryption,
    warnings: warnings,
  );
}
