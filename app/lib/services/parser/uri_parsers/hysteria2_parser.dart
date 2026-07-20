import '../../../models/node_spec.dart';
import '../../../models/node_warning.dart';
import '../../../models/tls_spec.dart';
import '../uri_utils.dart';
import '../utls_fingerprint.dart';

// ════════════════════════════════════════════════════════════════════════════
// Hysteria2
// ════════════════════════════════════════════════════════════════════════════

Hysteria2Spec? parseHysteria2(String uri) {
  final normalized = uri.startsWith('hy2://')
      ? uri.replaceFirst('hy2://', 'hysteria2://')
      : uri;
  final p = Uri.tryParse(normalized);
  if (p == null || p.host.isEmpty) return null;

  final password = Uri.decodeComponent(p.userInfo);
  if (password.isEmpty) return null;

  final server = p.host;
  final port = p.hasPort ? p.port : 443;
  final q = Map<String, String>.from(p.queryParameters);
  final label = decodeFragment(p.fragment);
  final tag = tagFromLabel(label, 'hysteria2', server, port);

  final obfs = q['obfs'] ?? '';
  final obfsPass = q['obfs-password'] ?? '';

  var sni = q['sni'] ?? '';
  if (sni.isEmpty || sni == '🔒' || (!sni.contains('.') && !sni.contains(':'))) {
    sni = server;
  }
  final fp = (q['fp'] ?? q['fingerprint'] ?? '').toLowerCase().trim();
  final alpn = (q['alpn'] ?? '').isEmpty
      ? const <String>[]
      : q['alpn']!.split(',').map((e) => e.trim()).toList();

  final warnings = <NodeWarning>[];
  // §281 — fp вне словаря ядра = fatal всего конфига (hysteria2 идёт через
  // тот же tls.NewClient ядра); канонизируем на входе.
  final tls = normalizeTlsFingerprint(
    TlsSpec(
      enabled: true,
      serverName: sni,
      fingerprint: fp.isEmpty ? null : fp,
      insecure: isTlsInsecure(q),
      alpn: alpn,
    ),
    warnings,
  );

  if (tls.insecure) warnings.add(const InsecureTlsWarning());

  // §084 H3: bandwidth hint'ы для round-trip с toUriHysteria2.
  final upMbps = int.tryParse(q['up_mbps'] ?? '');
  final downMbps = int.tryParse(q['down_mbps'] ?? '');

  return Hysteria2Spec(
    id: newUuidV4(),
    tag: tag,
    label: label,
    server: server,
    port: port,
    rawUri: uri,
    password: password,
    obfs: obfs,
    obfsPassword: obfsPass,
    tls: tls,
    upMbps: upMbps,
    downMbps: downMbps,
    warnings: warnings,
  );
}
