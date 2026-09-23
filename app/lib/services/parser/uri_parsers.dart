import '../../models/node_spec.dart';
import '../../models/node_warning.dart';
import 'amnezia_link.dart';
import 'mappers/uri_pipeline.dart';
export 'drop_verdict.dart' show XrayDropVerdict;

import 'drop_verdict.dart';
import 'engine/section_loader.dart' show MapperSections;
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
///
/// §512 — ЗАПАСНОЙ набор: основной даёт реестр ([_wireguardSchemes]), потому
/// что написания перечисляет `detect.scheme_in` секции, а не этот код.
const _kWireguardSchemesFallback = <String>{'wireguard', 'wg', 'awg'};

/// §512 — написания той же секции wireguard по РЕЕСТРУ: всё, что реестр
/// переводит в тип тела `wireguard`.
///
/// Контракт 1.1.48 добавил третье написание (`amneziawg`), и оно обязано
/// попасть сюда без правки литерала: у схемы вторая форма
/// (`<base64 .conf>`), и без этого набора ссылка ушла бы в конвейер, где
/// payload не URI, вместо `parseWireguardUri`.
/// Литералы остаются в объединении: `wg://` реестр в `scheme_in` не объявляет
/// намеренно (разрыв с Go, см. [pipelineSchemes]), а вторая форма у него та же.
Set<String> _wireguardSchemes() {
  final out = <String>{..._kWireguardSchemesFallback};
  for (final s in pipelineSchemes()) {
    if (registrySchemeType(s) == 'wireguard') out.add(s);
  }
  return out;
}

/// §506 — СЛУЖЕБНЫЕ схемы панелей провайдера: строки тела подписки, которые
/// узлами не являются вовсе (правила роутинга Happ/Incy: `incy://routing/…`,
/// `happ://routing/onadd/…`). Их игнор ТИХИЙ — в отличие от незнакомой схемы
/// узла, о которой пользователю говорят кодом `protocol_unsupported`.
///
/// Разделение нужно именно здесь: без него список причин у обычной подписки
/// Happ заполнялся бы строками, о которых пользователю решать нечего, и
/// настоящая потеря узла терялась бы среди них.
///
/// §512 — ЗАПАСНОЙ набор: основной объявляет реестр (контракт 1.1.48,
/// `source_kinds.json` → `uri_lines.service_schemes`), см.
/// [_serviceSchemeCode].
const _kProviderServiceSchemesFallback = <String>{'incy', 'happ'};

/// §512 — код служебной строки по РЕЕСТРУ, либо `null` — строка служебной не
/// является.
///
/// Реестр 1.1.48 требует хвост `routing/` и даёт info-код
/// `service_record_ignored`: выпадение перестаёт быть МОЛЧАЛИВЫМ (иначе оно
/// неотличимо от потерянного узла), но и ошибкой не становится — шторка §500
/// показывает причины только когда узлов не нашлось ни одного, а у живой
/// подписки Happ они есть.
///
/// Без реестра — прежний тихий игнор по литералам, без кода: `''` означает
/// «служебная, кода нет».
String? _serviceSchemeCode(String line, String scheme) {
  final src = MapperSections.I.documents?.sourceByKind('uri_lines');
  final code = src?.serviceSchemeCode(line);
  if (code != null) return code;
  if (src?.serviceSchemes != null) return null;
  return _kProviderServiceSchemesFallback.contains(scheme) ? '' : null;
}

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
    //
    // §512 — набор схем даёт РЕЕСТР (`detect.scheme_in` секций `mappers.uri`),
    // и написание, приехавшее контрактом, работает без правки кода. Ветка
    // wireguard ниже — по такому же набору, а не по литералам.
    final wireguardSchemes = _wireguardSchemes();
    if (pipelineSchemes().contains(scheme) &&
        !wireguardSchemes.contains(scheme)) {
      return parseUriViaPipeline(t, scheme, dropped: dropped);
    }
    // §097 §450 §512 — wireguard/AWG/AmneziaWG: та же endpoint-логика у всех
    // написаний секции, включая приехавшие реестром.
    if (wireguardSchemes.contains(scheme)) {
      return parseWireguardUri(t, dropped: dropped);
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
      // §512 — ветка wireguard снята: её написания перечисляет реестр, и
      // маршрут стоит ВЫШЕ switch'а (`_wireguardSchemes`). Литералы `wg`/
      // `wireguard`/`awg` здесь были четвёртой копией того же списка.
      case 'masque': // §130 — MASQUE-WARP (CONNECT-IP)
        return parseMasqueUri(t);
      case 'vpn': // §103 §9.B12 — Amnezia vpn:// строкой внутри URI-списка
        final n = parseAmneziaVpnUri(t, dropped: dropped);
        // §506 — профиль не разобран: ни контейнера с WG/AWG, ни голого
        // `.conf`. Причину назвать нечем, кроме рода тела, — но молчать
        // нельзя: строка была узнана как ссылка на профиль.
        //
        // §512 (контракт 1.1.49, CANON §4.1) — код `form_unrecognized`, а НЕ
        // `protocol_unsupported`: схему `vpn` секция ведёт, и протокол тут при
        // чём не был — не раскрылась ОБОЛОЧКА (битый base64, обрезанный или
        // раздутый payload), то есть ни одна форма секции текст не прочитала.
        if (n == null && dropped != null && dropped.reason == null) {
          dropped.reason = const RegistryWarning(
            code: 'form_unrecognized',
            params: {'scheme': 'vpn'},
          );
        }
        return n;
      default:
        // §506 — СЛУЖЕБНЫЕ строки провайдера: не узлы по смыслу, и код
        // «схема не поддержана» на них был бы ложной тревогой. Панели Happ /
        // Incy кладут их в тело подписки рядом с узлами (правила роутинга,
        // баннеры), поэтому игнор тихий и намеренный.
        //
        // §512 — набор и код объявляет РЕЕСТР (1.1.48). Код info, а не
        // молчание: выпадение обязано быть названным, иначе оно неотличимо от
        // потерянного узла. Шума в UI это не даёт — шторка §500 показывает
        // причины только когда не нашлось НИ ОДНОГО узла.
        final serviceCode = _serviceSchemeCode(t, scheme);
        if (serviceCode != null) {
          if (serviceCode.isNotEmpty) {
            dropped?.reason = RegistryWarning(
              code: serviceCode,
              params: {'scheme': scheme},
              value: scheme,
            );
          }
          return null;
        }
        // §506 — строка БЕЗ схемы вовсе (`split('://')` отдал её целиком):
        // это не «протокол не поддержан», а «ввод не распознан», и код о
        // протоколе назвал бы мусор именем протокола. Молчим, как и §500:
        // причины нет, потому что узла тут никто и не обещал.
        if (!t.contains('://')) return null;
        // §506 — незнакомая схема: раньше `return null` молча, и строка
        // исчезала без следа (4 строки `amneziawg://` из подписки — вход D
        // диагностики). Схему называем в `value`: пользователю нужно знать
        // ИМЕННО её, чтобы спросить провайдера.
        //
        // §512 (контракт 1.1.49, CANON §4.1) — граница двух кодов
        // непрочитанного: `scheme_unsupported` СТРОКЕ формы `xxx://`, схему
        // которой не ведёт ни одна секция реестра (это ровно наш случай), а
        // `protocol_unsupported` — записи, чей ТИП неизвестен внутри
        // опознанного тела (Xray/sing-box). До 1.1.49 второй код стоял и
        // здесь, то есть о схеме сообщалось словом «протокол».
        dropped?.reason = RegistryWarning(
          code: 'scheme_unsupported',
          params: {'scheme': scheme},
          value: scheme,
        );
        return null;
    }
  } catch (_) {
    return null;
  }
}
