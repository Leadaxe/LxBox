import '../../../models/node_spec.dart';
import '../../../models/node_warning.dart';
import '../transport.dart';
import '../uri_utils.dart';
import '../utls_fingerprint.dart';

// ════════════════════════════════════════════════════════════════════════════
// AnyTLS — see task 269.
// ════════════════════════════════════════════════════════════════════════════
// URI-стандарта у AnyTLS нет; принимаем trojan-подобную форму
// `anytls://password@host:port?sni=..&fp=..&alpn=..&pbk=..&insecure=..#label`.
// AnyTLS всегда поверх TLS — TLS форсим enabled даже при security=none.

AnyTlsSpec? parseAnyTls(String uri) {
  final p = Uri.tryParse(uri);
  if (p == null || p.host.isEmpty) return null;

  // userinfo = password (как trojan): user:pass схлопываем, `:`-разделённый
  // пароль остаётся целым.
  final userParts = p.userInfo.split(':');
  final password = Uri.decodeComponent(userParts.join(':'));
  if (password.isEmpty) return null;

  final server = p.host;
  final port = p.hasPort ? p.port : 443;
  final q = Map<String, String>.from(p.queryParameters);
  final label = decodeFragment(p.fragment);
  final tag = tagFromLabel(label, 'anytls', server, port);

  // TLS через VLESS-конвенцию — она несёт REALITY (pbk/sid), sni/fp/alpn/insecure.
  // AnyTLS всегда поверх TLS: security=none для него бессмысленен и не должен
  // терять параметры — снимаем security перед парсингом, чтобы не получить
  // disabled (обнулив весь TLS-блок).
  final tlsQuery = Map<String, String>.from(q)..remove('security');
  final warnings = <NodeWarning>[];
  // §281 — fp вне словаря ядра = fatal всего конфига; канонизируем на входе.
  final tls = normalizeTlsFingerprint(
      parseVlessTls(tlsQuery, server, port, warnings: warnings), warnings);

  if (tls.insecure) warnings.add(const InsecureTlsWarning());

  return AnyTlsSpec(
    id: newUuidV4(),
    tag: tag,
    label: label,
    server: server,
    port: port,
    rawUri: uri,
    password: password,
    tls: tls,
    idleSessionCheckInterval: q['idle_session_check_interval'] ?? '',
    idleSessionTimeout: q['idle_session_timeout'] ?? '',
    minIdleSession: int.tryParse(q['min_idle_session'] ?? ''),
    warnings: warnings,
  );
}
