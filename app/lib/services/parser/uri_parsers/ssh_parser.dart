import '../../../models/node_spec.dart';
import '../uri_utils.dart';

// ════════════════════════════════════════════════════════════════════════════
// SSH
// ════════════════════════════════════════════════════════════════════════════

SshSpec? parseSsh(String uri) {
  final p = Uri.tryParse(uri);
  if (p == null || p.host.isEmpty || p.userInfo.isEmpty) return null;

  final userParts = p.userInfo.split(':');
  final user = Uri.decodeComponent(userParts.first);
  final password = userParts.length > 1
      ? Uri.decodeComponent(userParts.sublist(1).join(':'))
      : '';
  if (user.isEmpty) return null;

  final server = p.host;
  final port = p.hasPort ? p.port : 22;
  final q = Map<String, String>.from(p.queryParameters);
  final label = decodeFragment(p.fragment);
  final tag = tagFromLabel(label, 'ssh', server, port);

  final hostKey = (q['host_key'] ?? '').isEmpty
      ? const <String>[]
      : q['host_key']!
          .split(',')
          .map((e) => e.trim())
          .where((e) => e.isNotEmpty)
          .toList();
  final hostKeyAlgorithms = (q['host_key_algorithms'] ?? '').isEmpty
      ? const <String>[]
      : q['host_key_algorithms']!
          .split(',')
          .map((e) => e.trim())
          .where((e) => e.isNotEmpty)
          .toList();

  return SshSpec(
    id: newUuidV4(),
    tag: tag,
    label: label,
    server: server,
    port: port,
    rawUri: uri,
    user: user,
    password: password,
    privateKey: q['private_key'] ?? '',
    privateKeyPassphrase: q['private_key_passphrase'] ?? '',
    hostKey: hostKey,
    hostKeyAlgorithms: hostKeyAlgorithms,
  );
}
