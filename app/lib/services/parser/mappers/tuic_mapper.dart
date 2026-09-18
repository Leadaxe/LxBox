/// §472 шаг 5 — маппер tuic: перевод диалекта ссылки в карту sing-box.
///
/// Словарь ссылки — `registry/protocols/tuic.json` → `uri`, общие части —
/// `tls.json`. Вторая QUIC-схема шага; про судьбу запрещённых на QUIC блоков
/// `tls.utls`/`tls.reality` см. doc `hysteria2_mapper.dart` — здесь всё то же
/// самое, и ровно поэтому в этом файле о QUIC не сказано ни слова.
///
/// Что маппер переводит (и не судит):
///
/// - **userinfo = `uuid:password`**, в отличие от hysteria2, где двоеточие
///   часть пароля. Пароль — всё ПОСЛЕ первого `:`, чтобы двоеточие внутри
///   пароля не потерялось;
/// - **три написания 0-RTT** — `reduce_rtt`, `zero_rtt`, `zero_rtt_handshake`
///   (`uri.query.reduce_rtt.aliases`; целевой набор контракта — объединение
///   обоих проектов, у Dart прежде не читался `zero_rtt_handshake`);
/// - **`heartbeat` голым числом** — правило `heartbeat_bare_number`: `10`
///   значит `10s`, а поле ядра это duration-строка;
/// - **`disable_sni=1`** — имя сервера не отправляется вовсе, то есть в теле
///   его нет. Это вопрос СТРУКТУРЫ («есть ли поле»), и отвечает на него
///   маппер: санитайзеру отсутствие ключа неотличимо от «не задано».
///
/// Чего маппер НЕ делает: не судит `congestion_control` и `udp_relay_mode`
/// (enum'ы реестра со своими кодами `tuic_congestion_invalid` и
/// `tuic_udp_relay_mode_invalid`), не проверяет форму `uuid`
/// (`format: uuid`), не трогает `alpn` и `insecure`.
library;

import '../../../models/node_warning.dart';
import '../uri_utils.dart';
import 'common_parts.dart';
import 'uri_mapper.dart';

/// Порт по умолчанию — как у прочих share-URI.
const _kDefaultPort = 443;

/// `tuic://uuid:password@host:port?…#label` → сырая карта sing-box.
///
/// `null` — ссылки нет: без хоста и без userinfo записи не построить. Требуем
/// ОБА непустыми, как и прежний парсер: `uuid` у схемы `required`, а пустой
/// пароль у tuic это отдельное расхождение строгости с Go
/// (`uri.userinfo.impl`), заводить которое этот шаг не уполномочен.
UriMapping? mapTuicUri(String uri) {
  final p = Uri.tryParse(uri);
  if (p == null || p.host.isEmpty || p.userInfo.isEmpty) return null;

  final userParts = p.userInfo.split(':');
  if (userParts.length < 2) return null;
  final uuid = Uri.decodeComponent(userParts.first);
  // Пароль — всё после ПЕРВОГО двоеточия: внутри него двоеточие законно.
  final password = Uri.decodeComponent(userParts.sublist(1).join(':'));
  if (uuid.isEmpty || password.isEmpty) return null;

  final server = p.host;
  final port = p.hasPort ? p.port : _kDefaultPort;
  final q = Map<String, String>.from(p.queryParameters);
  final warnings = <NodeWarning>[];

  // §103 D-016(в) — ключа не было в ссылке ⇒ поле не задано, и в тело оно не
  // попадает: дефолт подставит ядро. Значение вне enum'а уезжает в карту КАК
  // ЕСТЬ — его снимет реестр со своим кодом.
  final cc = (q['congestion_control'] ?? '').trim();
  final urm = (q['udp_relay_mode'] ?? '').trim();

  // `reduce_rtt` + два алиаса. Истина — та же тройка `1|true|yes`, что у
  // прочих query-bool контракта.
  final zeroRttRaw =
      q['reduce_rtt'] ?? q['zero_rtt'] ?? q['zero_rtt_handshake'] ?? '';
  final zeroRtt = queryTruthy(zeroRttRaw);

  // `heartbeat_bare_number` — голое число это секунды; форма записи, не
  // суждение. Реестр ждёт duration-строку (`type: duration`).
  final heartbeatRaw = (q['heartbeat'] ?? '').trim();

  final body = <String, dynamic>{
    'type': 'tuic',
    'server': server,
    'server_port': port,
    'uuid': uuid,
    'password': password,
    if (cc.isNotEmpty) 'congestion_control': cc,
    if (urm.isNotEmpty) 'udp_relay_mode': urm,
    if (zeroRtt) 'zero_rtt_handshake': true,
    if (heartbeatRaw.isNotEmpty)
      'heartbeat': normalizeSingboxDuration(heartbeatRaw),
  };

  final tls = tlsMapFromQuery(
    q,
    server,
    port,
    // Эвристики НАПИСАНИЯ у tuic нет: реестр говорит только про пустой `sni`
    // («пустой/мусорный → fallback на server», но LxBox всегда читал это как
    // «пустой»), и прежний парсер откатывался на сервер ровно на пустом.
    // Включать проверку точки и двоеточия здесь значило бы сдвинуть тела и
    // identity живых узлов — то же решение, что у trojan и vless.
    sniAliases: const ['sni'],
    fpAliases: const ['fp', 'fingerprint'],
    warnings: warnings,
  );
  // `tls` у tuic `required: true`: QUIC без TLS ядро не строит, и тело без
  // блока санитайзер снял бы целиком.
  final tlsMap =
      tls ?? <String, dynamic>{'enabled': true, 'server_name': server};

  // `disable_sni=1` — расширение SNI не отправляется вовсе, значит имени
  // сервера в теле быть не должно: прежний парсер выражал это через
  // `serverName: null`, и тело выходило как `tls: {enabled: true}`.
  //
  // Маппер снимает имя и кладёт САМ КЛЮЧ `disable_sni`, которого в прежнем
  // теле не было. Это не вольность: поле описано реестром (`tls.json` →
  // `disable_sni`, bool), ядро его понимает, а без него намерение автора в
  // теле не выражено ничем — тот же узел, пришедший sing-box-объектом с
  // `disable_sni: true`, нёс его и раньше (сквозной ключ,
  // `kTlsPassthroughKeys`). Прежняя форма теряла разницу между «SNI выключен»
  // и «имя просто не задано», и `toUri()` не мог вернуть `disable_sni=1`.
  //
  // Кейса на это ни в корпусе, ни в тестах не было — ни одного.
  if (queryTruthy(q['disable_sni'] ?? '')) {
    tlsMap.remove('server_name');
    tlsMap['disable_sni'] = true;
  }
  body['tls'] = tlsMap;

  // §453 dial-полей у QUIC-схемы нет — см. `hysteria2_mapper.dart`.
  return UriMapping(
    body: body,
    label: decodeFragment(p.fragment),
    warnings: warnings,
  );
}
