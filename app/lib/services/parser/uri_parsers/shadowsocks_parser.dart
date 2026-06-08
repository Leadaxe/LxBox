import '../../../models/node_spec.dart';
import '../uri_utils.dart';

// ════════════════════════════════════════════════════════════════════════════
// Shadowsocks (SIP002 + legacy base64)
// ════════════════════════════════════════════════════════════════════════════

ShadowsocksSpec? parseShadowsocks(String uri) {
  var body = uri.substring('ss://'.length);
  var fragment = '';
  final hashIdx = body.indexOf('#');
  if (hashIdx >= 0) {
    fragment = body.substring(hashIdx + 1);
    body = body.substring(0, hashIdx);
  }
  body = body.trim();

  String method = '';
  String password = '';
  String rest = '';

  final atIdx = body.indexOf('@');
  if (atIdx > 0) {
    // SIP002: ss://base64(method:password)@host:port
    final encoded = Uri.decodeComponent(body.substring(0, atIdx));
    rest = body.substring(atIdx + 1);
    final decoded = decodeBase64Safe(encoded);
    if (decoded == null) return null;
    final s = utf8Lossy(decoded);
    final colonIdx = s.indexOf(':');
    if (colonIdx <= 0) return null;
    method = s.substring(0, colonIdx).trim();
    password = s.substring(colonIdx + 1);
  } else {
    // Legacy: ss://base64(method:password@host:port)
    final decoded = decodeBase64Safe(Uri.decodeComponent(body));
    if (decoded == null) return null;
    final s = utf8Lossy(decoded);
    final at = s.indexOf('@');
    if (at <= 0) return null;
    final left = s.substring(0, at);
    rest = s.substring(at + 1).trim();
    final colonIdx = left.indexOf(':');
    if (colonIdx <= 0) return null;
    method = left.substring(0, colonIdx).trim();
    password = left.substring(colonIdx + 1);
  }

  if (!isValidShadowsocksMethod(method) || password.isEmpty) return null;

  // rest = "host:port?query" or "host:port"
  final qIdx = rest.indexOf('?');
  final hostPort = qIdx < 0 ? rest : rest.substring(0, qIdx);
  final q = qIdx < 0
      ? const <String, String>{}
      : Uri.splitQueryString(rest.substring(qIdx + 1));

  // Parse host:port (IPv6 bracketed).
  String server;
  int port;
  if (hostPort.startsWith('[')) {
    final close = hostPort.indexOf(']');
    if (close < 0) return null;
    server = hostPort.substring(1, close);
    final tail = hostPort.substring(close + 1);
    port = int.tryParse(tail.startsWith(':') ? tail.substring(1) : tail) ?? 8388;
  } else {
    final colonIdx = hostPort.lastIndexOf(':');
    if (colonIdx <= 0) return null;
    server = hostPort.substring(0, colonIdx);
    port = int.tryParse(hostPort.substring(colonIdx + 1)) ?? 8388;
  }

  final label = decodeFragment(fragment);
  final tag = tagFromLabel(label, 'shadowsocks', server, port);

  return ShadowsocksSpec(
    id: newUuidV4(),
    tag: tag,
    label: label,
    server: server,
    port: port,
    rawUri: uri,
    method: method,
    password: password,
    plugin: _ssPluginName(q['plugin']),
    pluginOpts: _ssPluginOpts(q['plugin']) ?? (q['plugin_opts'] ?? ''),
  );
}

/// SIP003: `plugin` query содержит `name;k=v;k=v…`. Имя — до первого `;`.
String _ssPluginName(String? raw) {
  if (raw == null || raw.isEmpty) return '';
  final i = raw.indexOf(';');
  return i < 0 ? raw : raw.substring(0, i);
}

/// SIP003: всё после первого `;` — opts. Null если отдельного `plugin_opts`
/// надо взять (старый split не применим).
String? _ssPluginOpts(String? raw) {
  if (raw == null || raw.isEmpty) return null;
  final i = raw.indexOf(';');
  return i < 0 ? null : raw.substring(i + 1);
}
