import '../../../models/node_spec.dart';
import '../../../models/node_warning.dart';
import '../transport.dart';
import '../uri_utils.dart';
import '../utls_fingerprint.dart';

// ════════════════════════════════════════════════════════════════════════════
// Trojan
// ════════════════════════════════════════════════════════════════════════════

TrojanSpec? parseTrojan(String uri) {
  final p = Uri.tryParse(uri);
  if (p == null || p.host.isEmpty) return null;

  final userParts = p.userInfo.split(':');
  final password = Uri.decodeComponent(userParts.join(':'));
  if (password.isEmpty) return null;

  final server = p.host;
  final port = p.hasPort ? p.port : 443;
  final q = Map<String, String>.from(p.queryParameters);
  final label = decodeFragment(p.fragment);
  final tag = tagFromLabel(label, 'trojan', server, port);

  final warnings = <NodeWarning>[];
  final transport = parseTransport(q, warnings: warnings);
  // §281 — fp вне словаря ядра = fatal всего конфига; канонизируем на входе.
  final tls = normalizeTlsFingerprint(
      parseTrojanTls(q, server, warnings: warnings), warnings);

  if (tls.insecure) warnings.add(const InsecureTlsWarning());

  return TrojanSpec(
    id: newUuidV4(),
    tag: tag,
    label: label,
    server: server,
    port: port,
    rawUri: uri,
    password: password,
    tls: tls,
    transport: transport,
    warnings: warnings,
  );
}
