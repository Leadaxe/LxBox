import '../../../models/node_spec.dart';
import '../../../models/tls_spec.dart';
import '../../app_log.dart';
import '../uri_utils.dart';

// ════════════════════════════════════════════════════════════════════════════
// NaïveProxy — see spec 037.
// ════════════════════════════════════════════════════════════════════════════

/// Известные query-keys; всё остальное — log warning + ignore.
const _naiveKnownQueryKeys = <String>{'extra-headers', 'padding'};

NaiveSpec? parseNaive(String uri) {
  final p = Uri.tryParse(uri);
  if (p == null || p.host.isEmpty) return null;

  // userinfo: только password (без `:`) → password=userinfo, username='';
  // user:pass → split; пустой → both empty.
  String username = '';
  String password = '';
  if (p.userInfo.isNotEmpty) {
    final colon = p.userInfo.indexOf(':');
    if (colon < 0) {
      password = Uri.decodeComponent(p.userInfo);
    } else {
      username = Uri.decodeComponent(p.userInfo.substring(0, colon));
      password = Uri.decodeComponent(p.userInfo.substring(colon + 1));
    }
  }

  final server = p.host;
  final port = p.hasPort ? p.port : 443;
  final q = Map<String, String>.from(p.queryParameters);
  final label = decodeFragment(p.fragment);
  final tag = tagFromLabel(label, 'naive', server, port);

  // padding не имеет соответствия в sing-box — silently drop с log-warn.
  if (q.containsKey('padding')) {
    AppLog.I.warning(
      "naive: 'padding' parameter has no sing-box equivalent, ignoring",
    );
  }

  // Незнакомые query — лог + игнор.
  for (final key in q.keys) {
    if (!_naiveKnownQueryKeys.contains(key)) {
      AppLog.I.warning("naive: unknown query param '$key', ignoring");
    }
  }

  // extra-headers: уже URL-decoded внутри queryParameters.
  final headers = parseNaiveExtraHeaders(q['extra-headers'] ?? '');

  // Naive accepts ТОЛЬКО enabled/server_name/cert/ECH в TLS-блоке.
  // Никаких alpn/utls/insecure/reality — sing-box валидатор отклонит.
  final tls = TlsSpec(enabled: true, serverName: server);

  return NaiveSpec(
    id: newUuidV4(),
    tag: tag,
    label: label,
    server: server,
    port: port,
    rawUri: uri,
    username: username,
    password: password,
    tls: tls,
    extraHeaders: headers,
  );
}

/// Парсит уже-URL-decoded строку `Header1: Value1\r\nHeader2: Value2`.
/// Невалидные пары (нет `:`, имя нарушает charset, пустое имя) — drop с warn.
Map<String, String> parseNaiveExtraHeaders(String raw) {
  if (raw.isEmpty) return const {};
  final out = <String, String>{};
  for (final line in raw.split('\r\n')) {
    final l = line.trim();
    if (l.isEmpty) continue;
    final colon = l.indexOf(':');
    if (colon <= 0) {
      AppLog.I.warning("naive: invalid extra-headers entry '$l', skipping");
      continue;
    }
    final name = l.substring(0, colon).trim();
    final value = l.substring(colon + 1).trim();
    if (!isValidNaiveHeaderName(name)) {
      AppLog.I
          .warning("naive: invalid header name '$name' in extra-headers, skipping");
      continue;
    }
    out[name] = value;
  }
  return out;
}
