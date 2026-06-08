import '../../../models/node_spec.dart';
import '../uri_utils.dart';

// ════════════════════════════════════════════════════════════════════════════
// SOCKS 5
// ════════════════════════════════════════════════════════════════════════════

SocksSpec? parseSocks(String uri) {
  final p = Uri.tryParse(uri);
  if (p == null || p.host.isEmpty) return null;

  final userParts = p.userInfo.split(':');
  final username = userParts.isEmpty || userParts.first.isEmpty
      ? ''
      : Uri.decodeComponent(userParts.first);
  final password = userParts.length > 1
      ? Uri.decodeComponent(userParts.sublist(1).join(':'))
      : '';

  final server = p.host;
  final port = p.hasPort ? p.port : 1080;
  final label = decodeFragment(p.fragment);
  final tag = tagFromLabel(label, 'socks', server, port);

  return SocksSpec(
    id: newUuidV4(),
    tag: tag,
    label: label,
    server: server,
    port: port,
    rawUri: uri,
    username: username,
    password: password,
  );
}
