/// §472 шаг 3 — маппер vless: перевод диалекта ссылки в карту sing-box.
///
/// Словарь ссылки — `registry/protocols/vless.json` → `uri`, общие части —
/// `tls.json` и `transports.json`. Отличия от trojan выражены АРГУМЕНТАМИ
/// общих частей (шаг 2 писал их под это):
///
/// - `plaintextPorts` — правило `plaintext_port_no_tls`: на открытом
///   HTTP-порту ссылка без `security` читается как открытый TCP;
/// - `fpAliases` — `fp` у vless читается и как `fingerprint`;
/// - `defaultFingerprint: random` — правило `fp_empty_defaults_to_random`
///   (D-009, конвенция обеих сторон, а не дефолт ядра);
/// - `reality: true` — правило `pbk_makes_reality_block`: НАЛИЧИЕ блока
///   решает маппер, годность ключа судит реестр (`base64_32`).
///
/// Собственных полей у vless три — `flow`, `packetEncoding`, `encryption`, — и
/// маппер трогает из них только ПЕРЕВОД написания:
///
/// - `vision_udp443_is_a_compound_name` (`vless.json` mapper):
///   `flow=xtls-rprx-vision-udp443` — это составное ИМЯ, а не значение,
///   известное ядру: оно раскладывается на `flow=xtls-rprx-vision` и
///   `packet_encoding=xudp`. Порт узла при этом НЕ переписывается (DRIFT
///   §7.4, решение владельца);
/// - `packet_encoding_none_means_absent`: `none` в диалекте подписок значит
///   «без особой инкапсуляции», то есть синоним отсутствия ключа. Прочий
///   мусор уезжает в карту КАК ЕСТЬ — его снимет реестр с кодом
///   `packet_encoding_unknown`;
/// - ключ `packetEncoding` читается в любом регистре (`uri.query` реестра:
///   «оба парсера читают ключ case-insensitively»).
///
/// Что маппер НЕ судит и не подставляет: годность `pbk`, форму `sid`,
/// значение `key_share`, написание `fp`, длину и форму `encryption`. Всё это
/// — правила значений реестра, и исполняет их санитайзер (см. таблицу в
/// `uri_parsers/vless_parser.dart`).
library;

import '../../../models/node_warning.dart';
import '../uri_utils.dart';
import 'common_parts.dart';
import 'uri_mapper.dart';

/// Порт по умолчанию — тот же, что у trojan (share-URI без порта).
const _kDefaultPort = 443;

/// Составное имя из `vless.json` → mapper → `vision_udp443_is_a_compound_name`.
const _kVisionUdp443 = 'xtls-rprx-vision-udp443';
const _kVision = 'xtls-rprx-vision';

/// `vless://uuid@host:port?…#label` → сырая карта sing-box.
///
/// `null` — ссылки нет: без хоста или без userinfo записи не построить
/// (`uuid` у схемы `required`, и пустой userinfo = drop узла — `uri.userinfo`
/// реестра).
UriMapping? mapVlessUri(Uri p) {
  if (p.host.isEmpty || p.userInfo.isEmpty) return null;

  // `uri.userinfo.impl` — часть до `:` (Go Username(), Dart split(':').first).
  final uuid = Uri.decodeComponent(p.userInfo.split(':').first);
  final server = p.host;
  final port = p.hasPort ? p.port : _kDefaultPort;
  final q = Map<String, String>.from(p.queryParameters);
  final warnings = <NodeWarning>[];

  // `vision_udp443_is_a_compound_name` — раскладка составного имени. Судить
  // тут нечего: `xtls-rprx-vision-udp443` в enum ядра не входит вовсе, и
  // санитайзер увидел бы только мусор вне набора.
  var flow = (q['flow'] ?? '').trim();
  String? packetEncoding;
  if (flow == _kVisionUdp443) {
    flow = _kVision;
    packetEncoding = 'xudp';
  } else {
    // `packet_encoding_none_means_absent` — `none` синоним отсутствия ключа;
    // прочее уезжает как есть (в том числе регистр: `normalize: trim_lower`
    // реестра сведёт `XUDP` к `xudp` сам).
    final raw = (queryParamCI(q, 'packetEncoding') ?? '').trim();
    if (raw.isNotEmpty && raw.toLowerCase() != 'none') packetEncoding = raw;
  }

  final transport = transportMapFromQuery(q, warnings: warnings);

  // §115 / корпус `flow_vision_*_suppressed` — vision несовместим с
  // транспортом, и flow гасится. Правило реестра (`flow.conflicts.transport`)
  // этого НЕ делает: `flow` идёт раньше `transport` в `body.order`, а
  // конфликт снимает МЛАДШЕЕ поле, то есть уцелели бы оба. Пока правило
  // реестра так записано, решение остаётся здесь — с рукописным кодом
  // `vision_with_transport`, которого корпус и ждёт от LxBox
  // (`flow_vision_ws_suppressed.expected.lxbox.json`). См. отчёт шага 3:
  // это первый пункт запроса к лаунчеру.
  if (flow == _kVision && transport.map != null) {
    warnings.add(VisionWithTransportWarning(q['type'] ?? 'transport'));
    flow = '';
  }

  // §335 — постквантовый слой: значение как есть, `none` = слой выключен
  // (`vless.json` → `uri.query.encryption`). Закрытого enum у поля нет.
  final encryption = (q['encryption'] ?? '').trim();

  final body = <String, dynamic>{
    'type': 'vless',
    'server': server,
    'server_port': port,
    'uuid': uuid,
    if (flow.isNotEmpty) 'flow': flow,
    if (encryption.isNotEmpty && encryption.toLowerCase() != 'none')
      'encryption': encryption,
    'packet_encoding': ?packetEncoding,
  };

  final tls = tlsMapFromQuery(
    q,
    server,
    port,
    plaintextPorts: plaintextVlessPorts,
    fpAliases: const ['fp', 'fingerprint'],
    defaultFingerprint: 'random',
    reality: true,
    warnings: warnings,
  );
  if (tls != null) body['tls'] = tls;

  // `tls_insecure` — правила значения у реестра НЕТ: `tls.insecure` в
  // `tls.json` объявлен обычным `bool` без `advisory`, и санитайзер на нём
  // молчит. Код info-шный (узел работает, но защита от MITM снята), корпус
  // его ждёт (`reality_vision_full.expected.lxbox.json`), поэтому ставит его
  // по-прежнему разбор. Второй пункт запроса к лаунчеру: правило `advisory`
  // на `tls.insecure`, как у `utls.fingerprint`. Так же осталось и у trojan
  // после шага 2 — снимется у обеих схем разом.
  if (tls?['insecure'] == true) warnings.add(const InsecureTlsWarning());

  if (transport.map != null) body['transport'] = transport.map;

  return UriMapping(
    body: body,
    label: decodeFragment(p.fragment),
    warnings: warnings,
    // §453 — dial-поля мимо санитайзера: см. `UriMapping.extensionFields`.
    extensionFields: tcpKeepAliveMapFromQuery(q),
    wsEarlyDataHeaderImplicit: transport.wsEarlyDataHeaderImplicit,
  );
}
