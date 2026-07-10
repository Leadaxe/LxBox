import '../../../models/node_spec.dart';
import '../../../models/node_warning.dart';
import '../../../models/tls_spec.dart';
import '../transport.dart';
import '../uri_utils.dart';
import 'naive_parser.dart';

// ════════════════════════════════════════════════════════════════════════════
// HTTP(S) CONNECT proxy — see task 222.
// ════════════════════════════════════════════════════════════════════════════

/// Обе схемы: `proxy-http://` (plain) и `proxy-https://` (TLS). Кастомная
/// схема вместо голых `http(s)://` — те перехватываются `isSubscriptionUrl`
/// раньше `isDirectLink`, а в телах подписок промо-ссылки стали бы «нодами».
/// §268 — плюс-формы `proxy+http://` / `proxy+https://` эквивалентны.
HttpSpec? parseHttpProxy(String uri) {
  final p = Uri.tryParse(uri);
  if (p == null || p.host.isEmpty) return null;

  // TLS-дискриминатор — суффикс `https` (покрывает и дефис-, и плюс-форму);
  // `proxy-http` / `proxy+http` → plain.
  final secure = p.scheme.toLowerCase().endsWith('https');

  // userinfo как у socks: user | user:pass | :pass (только пароль).
  final userParts = p.userInfo.split(':');
  final username = userParts.isEmpty || userParts.first.isEmpty
      ? ''
      : Uri.decodeComponent(userParts.first);
  final password = userParts.length > 1
      ? Uri.decodeComponent(userParts.sublist(1).join(':'))
      : '';

  final server = p.host;
  final port = p.hasPort ? p.port : (secure ? 443 : 80);
  final q = Map<String, String>.from(p.queryParameters);
  final label = decodeFragment(p.fragment);
  final tag = tagFromLabel(label, 'http', server, port);

  // headers: та же сериализация, что naive extra-headers
  // (`Header1: V1\r\nHeader2: V2`, URL-encoded).
  final headers = parseNaiveExtraHeaders(q['headers'] ?? '');

  // TLS-параметры — конвенции trojan (sni/peer/host, fp, alpn,
  // insecure-алиасы). Схема — дискриминатор: proxy-http → TLS выключен.
  final tls = secure ? parseTrojanTls(q, server) : TlsSpec.disabled;

  final warnings = <NodeWarning>[];
  if (tls.insecure) warnings.add(const InsecureTlsWarning());

  return HttpSpec(
    id: newUuidV4(),
    tag: tag,
    label: label,
    server: server,
    port: port,
    rawUri: uri,
    username: username,
    password: password,
    path: q['path'] ?? '',
    headers: headers,
    tls: tls,
    warnings: warnings,
  );
}
