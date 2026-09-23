import '../../models/node_spec.dart';
import '../../models/node_warning.dart';
import 'amnezia_link.dart';
import 'mappers/uri_pipeline.dart';
export 'drop_verdict.dart' show XrayDropVerdict;

import 'drop_verdict.dart';
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

/// §506 — СЛУЖЕБНЫЕ схемы панелей провайдера: строки тела подписки, которые
/// узлами не являются вовсе (правила роутинга Happ/Incy: `incy://routing/…`,
/// `happ://routing/onadd/…`). Их игнор ТИХИЙ — в отличие от незнакомой схемы
/// узла, о которой пользователю говорят кодом `protocol_unsupported`.
///
/// Разделение нужно именно здесь: без него список причин у обычной подписки
/// Happ заполнялся бы строками, о которых пользователю решать нечего, и
/// настоящая потеря узла терялась бы среди них.
const _kProviderServiceSchemes = <String>{'incy', 'happ'};

/// Диспетчер по схеме URI. Возвращает NodeSpec или null (skip).
/// Ошибки структуры (отсутствие host, uuid) — null, не throw.
///
/// §481 (контракт 1.1.11) — [dropped]: КОД отбраковки наружу. `code` в
/// `dropped[]` нормативен (D-088), `reason` — нет, а `null` в ответе сам по
/// себе о причине не говорит: отличить «узел выброшен за негодный ключ WG» от
/// «за пересечение заголовков» вызывающему было нечем, и проверить перенос
/// правил в реестр — тоже. Заполняется на схемах конвейера; там, где схема ещё
/// идёт своим парсером, остаётся пустым, и вызывающий сверяет один `ref`.
NodeSpec? parseUri(String uri, {XrayDropVerdict? dropped}) {
  final t = uri.trim();
  if (t.isEmpty) return null;
  final scheme = t.split('://').first.toLowerCase();
  // vpn:// проверяется своим потолком (maxAmneziaLinkLength): профиль везёт
  // целый конфиг и штатно перерастает общий лимит — под ним ссылка молча
  // терялась, хотя десктоп её принимал (§103 §9.B12).
  if (scheme != 'vpn' && uri.length > maxURILength) {
    // §506 — раньше молча: длинная строка исчезала, и «0 узлов» ничем не
    // отличалось от пустого тела. Код реестра для этого уже есть.
    dropped?.reason = RegistryWarning(
      code: 'uri_too_long',
      params: {'length': '${uri.length}', 'limit': '$maxURILength'},
    );
    return null;
  }
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
      return parseUriViaPipeline(t, scheme, dropped: dropped);
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
      // §475 — четыре схемы, одно тело: версию несёт схема.
      case 'socks':
      case 'socks5':
      case 'socks4':
      case 'socks4a':
        return parseSocks(t);
      case 'proxy-http': // §222 — HTTP(S) CONNECT proxy
      case 'proxy-https':
      case 'proxy+http': // §268 — плюс-алиасы (единообразие с naive+https)
      case 'proxy+https':
        return parseHttpProxy(t);
      case 'wg':
      case 'wireguard':
      case 'awg': // §097 — AmneziaWG2 алиас (та же endpoint-логика, что WG)
        return parseWireguardUri(t, dropped: dropped);
      case 'masque': // §130 — MASQUE-WARP (CONNECT-IP)
        return parseMasqueUri(t);
      case 'vpn': // §103 §9.B12 — Amnezia vpn:// строкой внутри URI-списка
        final n = parseAmneziaVpnUri(t, dropped: dropped);
        // §506 — профиль не разобран: ни контейнера с WG/AWG, ни голого
        // `.conf`. Причину назвать нечем, кроме рода тела, — но молчать
        // нельзя: строка была узнана как ссылка на профиль.
        if (n == null && dropped != null && dropped.reason == null) {
          dropped.reason = const RegistryWarning(
            code: 'protocol_unsupported',
            params: {'scheme': 'vpn'},
          );
        }
        return n;
      default:
        // §506 — СЛУЖЕБНЫЕ строки провайдера: не узлы по смыслу, и код
        // «схема не поддержана» на них был бы ложной тревогой. Панели Happ /
        // Incy кладут их в тело подписки рядом с узлами (правила роутинга,
        // баннеры), поэтому игнор тихий и намеренный.
        if (_kProviderServiceSchemes.contains(scheme)) return null;
        // §506 — строка БЕЗ схемы вовсе (`split('://')` отдал её целиком):
        // это не «протокол не поддержан», а «ввод не распознан», и код о
        // протоколе назвал бы мусор именем протокола. Молчим, как и §500:
        // причины нет, потому что узла тут никто и не обещал.
        if (!t.contains('://')) return null;
        // §506 — незнакомая схема: раньше `return null` молча, и строка
        // исчезала без следа (4 строки `amneziawg://` из подписки — вход D
        // диагностики). Схему называем в `value`: пользователю нужно знать
        // ИМЕННО её, чтобы спросить провайдера.
        dropped?.reason = RegistryWarning(
          code: 'protocol_unsupported',
          params: {'scheme': scheme},
          value: scheme,
        );
        return null;
    }
  } catch (_) {
    return null;
  }
}
