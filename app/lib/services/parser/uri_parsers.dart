import '../../models/node_spec.dart';
import 'uri_utils.dart';
import 'uri_parsers/anytls_parser.dart';
import 'uri_parsers/http_parser.dart';
import 'uri_parsers/hysteria2_parser.dart';
import 'uri_parsers/masque_parser.dart';
import 'uri_parsers/naive_parser.dart';
import 'uri_parsers/shadowsocks_parser.dart';
import 'uri_parsers/socks_parser.dart';
import 'uri_parsers/ssh_parser.dart';
import 'uri_parsers/trojan_parser.dart';
import 'uri_parsers/tuic_parser.dart';
import 'uri_parsers/vless_parser.dart';
import 'uri_parsers/vmess_parser.dart';
import 'uri_parsers/wireguard_parser.dart';

// Per-protocol parsers live under uri_parsers/. Re-exported here so existing
// imports of 'uri_parsers.dart' keep resolving every parse* entry point.
export 'uri_parsers/anytls_parser.dart';
export 'uri_parsers/http_parser.dart';
export 'uri_parsers/hysteria2_parser.dart';
export 'uri_parsers/masque_parser.dart';
export 'uri_parsers/naive_parser.dart';
export 'uri_parsers/shadowsocks_parser.dart';
export 'uri_parsers/socks_parser.dart';
export 'uri_parsers/ssh_parser.dart';
export 'uri_parsers/trojan_parser.dart';
export 'uri_parsers/tuic_parser.dart';
export 'uri_parsers/vless_parser.dart';
export 'uri_parsers/vmess_parser.dart';
export 'uri_parsers/wireguard_parser.dart';

/// Диспетчер по схеме URI. Возвращает NodeSpec или null (skip).
/// Ошибки структуры (отсутствие host, uuid) — null, не throw.
NodeSpec? parseUri(String uri) {
  if (uri.length > maxURILength) return null;
  final t = uri.trim();
  if (t.isEmpty) return null;
  final scheme = t.split('://').first.toLowerCase();
  try {
    switch (scheme) {
      case 'vless':
        return parseVless(t);
      case 'vmess':
        return parseVmess(t);
      case 'trojan':
        return parseTrojan(t);
      case 'ss':
        return parseShadowsocks(t);
      case 'hysteria2':
      case 'hy2':
        return parseHysteria2(t);
      case 'naive+https':
        return parseNaive(t);
      case 'anytls': // §269 — AnyTLS (trojan-подобная URI-форма)
        return parseAnyTls(t);
      case 'tuic':
        return parseTuic(t);
      case 'ssh':
        return parseSsh(t);
      case 'socks':
      case 'socks5':
        return parseSocks(t);
      case 'proxy-http': // §222 — HTTP(S) CONNECT proxy
      case 'proxy-https':
      case 'proxy+http': // §268 — плюс-алиасы (единообразие с naive+https)
      case 'proxy+https':
        return parseHttpProxy(t);
      case 'wg':
      case 'wireguard':
      case 'awg': // §097 — AmneziaWG2 алиас (та же endpoint-логика, что WG)
        return parseWireguardUri(t);
      case 'masque': // §130 — MASQUE-WARP (CONNECT-IP)
        return parseMasqueUri(t);
      default:
        return null;
    }
  } catch (_) {
    return null;
  }
}
