import '../../models/node_spec.dart';
import '../../models/node_warning.dart';
import 'amnezia_link.dart';
import 'mappers/uri_pipeline.dart';
export 'drop_verdict.dart' show XrayDropVerdict;

import 'drop_verdict.dart';
import 'engine/interpreter.dart' show formMatchesText;
import 'engine/section_loader.dart' show MapperSections;
import 'uri_utils.dart';
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

/// §472 шаг 7 / §562 — ФОРМЫ ССЫЛКИ, которые движок ссылок не исполняет, и
/// парсер, который их читает. Ключ — пространство формы (`forms[].space`
/// секции `mappers.uri`), а не написание схемы: какая схема такую форму
/// несёт, объявляет реестр.
///
/// Сегодня такая форма одна — `ini` (`<схема>://<base64 .conf>`, §450): её
/// payload не URI, и распознать её надо ДО конвейера. Парсер сам пробует
/// обе формы и отдаёт ссылочную конвейеру, поэтому схема с такой формой
/// целиком идёт через него.
const _kOutOfEngineLinkForms =
    <String, NodeSpec? Function(String, {XrayDropVerdict? dropped})>{
  'ini': parseWireguardUri,
};

/// Парсер вне движка для типа тела [type] — по формам его секции; `null` —
/// все формы исполняет движок.
///
/// §551 — считается один раз на маршрут схем ([schemeRouteToken]), а не на
/// каждой ссылке.
NodeSpec? Function(String, {XrayDropVerdict? dropped})? _outOfEngineParser(
    String type) {
  final token = schemeRouteToken();
  if (!identical(token, _outOfEngineToken)) {
    _outOfEngineCache.clear();
    _outOfEngineToken = token;
  }
  return _outOfEngineCache.putIfAbsent(type, () {
    final forms = MapperSections.I.sectionFor('uri', type)?.forms;
    if (forms == null) return null;
    for (final f in forms) {
      final p = _kOutOfEngineLinkForms[f.space];
      if (p != null) return p;
    }
    return null;
  });
}

Object? _outOfEngineToken;
final _outOfEngineCache =
    <String, NodeSpec? Function(String, {XrayDropVerdict? dropped})?>{};

/// §110 / §562 — строка-КОНТЕЙНЕР профиля (Amnezia): признак объявляет вид
/// источника `amnezia_link` в `source_kinds.json` (`detect`), а не литерал
/// префикса здесь. Тот же признак у тела подписки и у строки внутри списка
/// ссылок. Реестра нет — контейнера нет.
bool _isContainerLine(String line) {
  final src = MapperSections.I.documents?.sourceByKind('amnezia_link');
  if (src == null || src.detect == null) return false;
  return formMatchesText(src.detect, line);
}

/// §506 / §512 — код служебной строки провайдера по РЕЕСТРУ (контракт
/// 1.1.48, `source_kinds.json` → `uri_lines.service_schemes`), либо `null` —
/// строка служебной не является.
///
/// СЛУЖЕБНЫЕ строки (правила роутинга панелей) узлами не являются вовсе, и
/// код «схема не поддержана» на них был бы ложной тревогой. Реестр даёт
/// info-код `service_record_ignored`: выпадение названо, но ошибкой не
/// становится. §562 — литерального запасного набора больше нет: реестра нет
/// — служебных схем нет.
String? _serviceSchemeCode(String line) => MapperSections.I.documents
    ?.sourceByKind('uri_lines')
    ?.serviceSchemeCode(line);

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
  final node = _parseUriInner(uri, dropped: dropped);
  if (node == null) return null;
  // §514 / контракт 1.1.52 (D133-55) — БАННЕР ПРОВАЙДЕРА, ПРИТВОРИВШИЙСЯ
  // ССЫЛКОЙ. Проверка идёт ПОСЛЕ разбора, а не по тексту строки: цель надо
  // прочитать, а до чтения `vless://…@0.0.0.0:1` от годной ссылки ничем не
  // отличается. Прежде признаком баннера было отсутствие `://`, и обе крупные
  // панели проходили насквозь, становясь полноценным узлом-пустышкой:
  // Remnawave при истёкшей подписке отдаёт `vless://…@0.0.0.0:1#⚠ Subscription
  // expired` с нулевым uuid, 3x-ui — `socks://127.0.0.1:1080#<remark>`, причём
  // при expired/depleted ЕДИНСТВЕННОЙ записью тела: подписка выглядела рабочей
  // и одноузловой, и человек видел сервер, которого нет, вместо причины.
  final banner = _providerBannerWarning(node, uri);
  if (banner != null) {
    dropped?.explicit = true;
    dropped?.reason = banner;
    return null;
  }
  return node;
}

/// Ремарка после `#` — ТО САМОЕ сообщение, ради которого запись написана
/// (`message_from: fragment`): выбросить её значило бы отбраковать баннер
/// вместе с единственным его содержимым. Метка узла к этому моменту уже
/// раскодирована разбором, поэтому берётся она, а не сырой хвост ссылки.
RegistryWarning? _providerBannerWarning(NodeSpec node, String uri) {
  final src = MapperSections.I.documents?.sourceByKind('uri_lines');
  if (src == null || !src.isBannerTarget(node.server)) return null;
  final code = src.bannerCode;
  if (code == null || code.isEmpty) return null;
  return RegistryWarning(
    code: code,
    params: {'message': node.tag},
    value: node.server,
  );
}

NodeSpec? _parseUriInner(String uri, {XrayDropVerdict? dropped}) {
  final t = uri.trim();
  if (t.isEmpty) return null;
  final scheme = t.split('://').first.toLowerCase();
  // Контейнер профиля проверяется своим потолком (maxAmneziaLinkLength):
  // профиль везёт целый конфиг и штатно перерастает общий лимит — под ним
  // ссылка молча терялась, хотя десктоп её принимал (§103 §9.B12).
  final container = _isContainerLine(t);
  if (!container && uri.length > maxURILength) {
    // §506 — раньше молча: длинная строка исчезала, и «0 узлов» ничем не
    // отличалось от пустого тела. Код реестра для этого уже есть.
    dropped?.reason = RegistryWarning(
      code: 'uri_too_long',
      params: {'length': '${uri.length}', 'limit': '$maxURILength'},
    );
    return null;
  }
  try {
    // §562 — схему ведёт РЕЕСТР: написание → тип тела по `scheme_in` секций
    // `mappers.uri` и `aliases` протоколов ([registrySchemeType]). Имён схем
    // здесь нет: написание, приехавшее контрактом, работает без правки кода,
    // а снятое реестром перестаёт приниматься с кодом `scheme_unsupported`.
    final type = registrySchemeType(scheme);
    if (type != null) {
      // §472 шаг 7 / §450 — у части секций есть форма, которую движок ссылок
      // не исполняет (payload не URI); такую схему читает свой парсер, и
      // выбирается он по форме секции, а не по написанию.
      final outOfEngine = _outOfEngineParser(type);
      if (outOfEngine != null) return outOfEngine(t, dropped: dropped);
      return parseUriViaPipeline(t, scheme, dropped: dropped);
    }
    // §103 §9.B12 — контейнер профиля строкой внутри списка ссылок.
    if (container) {
      final n = parseAmneziaVpnUri(t, dropped: dropped);
      // §506 — профиль не разобран: ни контейнера с WG/AWG, ни голого
      // `.conf`. Причину назвать нечем, кроме рода тела, — но молчать
      // нельзя: строка была узнана как ссылка на профиль.
      //
      // §512 (контракт 1.1.49, PARSING_PRINCIPLES §4.1) — код `form_unrecognized`, а НЕ
      // `protocol_unsupported`: не раскрылась ОБОЛОЧКА (битый base64,
      // обрезанный или раздутый payload), то есть ни одна форма текст не
      // прочитала.
      if (n == null && dropped != null && dropped.reason == null) {
        dropped.reason = RegistryWarning(
          code: 'form_unrecognized',
          params: {'scheme': scheme},
        );
      }
      return n;
    }
    // §506 / §512 — СЛУЖЕБНЫЕ строки провайдера: не узлы по смыслу. Набор и
    // код объявляет реестр; код info, а не молчание: выпадение обязано быть
    // названным, иначе оно неотличимо от потерянного узла. Шума в UI это не
    // даёт — шторка §500 показывает причины только когда не нашлось НИ
    // ОДНОГО узла.
    final serviceCode = _serviceSchemeCode(t);
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
    // §506 / §512 (контракт 1.1.49, PARSING_PRINCIPLES §4.1) — незнакомая схема: строке
    // формы `xxx://`, схему которой не ведёт ни одна секция реестра, код
    // `scheme_unsupported` (а `protocol_unsupported` — записи, чей ТИП
    // неизвестен внутри опознанного тела). Схему называем в `value`:
    // пользователю нужно знать ИМЕННО её, чтобы спросить провайдера.
    dropped?.reason = RegistryWarning(
      code: 'scheme_unsupported',
      params: {'scheme': scheme},
      value: scheme,
    );
    return null;
  } catch (_) {
    return null;
  }
}
