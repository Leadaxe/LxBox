import '../../models/node_spec.dart';
import 'amnezia_link.dart';
import 'mappers/uri_pipeline.dart';
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

/// §472 шаг 7 — схемы, у которых конвейер вызывает НЕ `parseUri`, а сам
/// парсер схемы: у wireguard две формы записи, и вторая
/// (`awg://<base64 .conf>`, §450) не URI.
const _kWireguardSchemes = <String>{'wireguard', 'wg', 'awg'};

/// Диспетчер по схеме URI. Возвращает NodeSpec или null (skip).
/// Ошибки структуры (отсутствие host, uuid) — null, не throw.
NodeSpec? parseUri(String uri) {
  final t = uri.trim();
  if (t.isEmpty) return null;
  final scheme = t.split('://').first.toLowerCase();
  // vpn:// проверяется своим потолком (maxAmneziaLinkLength): профиль везёт
  // целый конфиг и штатно перерастает общий лимит — под ним ссылка молча
  // терялась, хотя десктоп её принимал (§103 §9.B12).
  if (scheme != 'vpn' && uri.length > maxURILength) return null;
  try {
    // §472 шаг 2 — схемы, переехавшие на конвейер «маппер → санитайзер по
    // реестру → модель», идут им; остальные пока своим парсером. Список
    // растёт по шагу за протокол (спека 472, раздел 4).
    //
    // §472 шаг 7 — wireguard и его алиасы в списке ЕСТЬ (страж покрытия
    // mapper-правил читает его), но маршрутизируются они по-прежнему через
    // `parseWireguardUri`: у схемы есть ВТОРАЯ ФОРМА `awg://<base64 .conf>`
    // (§450), и распознать её надо ДО конвейера — её payload не URI вовсе.
    if (kPipelineSchemes.contains(scheme) && !_kWireguardSchemes.contains(scheme)) {
      return parseUriViaPipeline(t, scheme);
    }
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
      case 'naive+quic': // §103 §9.B1 — QUIC-транспорт вместо HTTP/2
        return parseNaive(t, isQuic: true);
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
      case 'vpn': // §103 §9.B12 — Amnezia vpn:// строкой внутри URI-списка
        return parseAmneziaVpnUri(t);
      default:
        return null;
    }
  } catch (_) {
    return null;
  }
}
