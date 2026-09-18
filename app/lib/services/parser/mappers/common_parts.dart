/// §472 шаг 2 — общие части маппера в форме КАРТЫ.
///
/// Те же диалекты, что читал `transport.dart`, но результат — карта sing-box,
/// а не типизированный `TransportSpec`/`TlsSpec`. Разница не в форме записи:
/// типизированная модель по дороге СУДИТ значения (отбрасывает негодный путь,
/// канонизирует отпечаток, режет ALPN-мусор), а карта несёт то, что сказала
/// ссылка, и судит её потом санитайзер по реестру — один раз на все входы.
///
/// Пишется под переиспользование: trojan переехал на шаге 2, vless идёт
/// шагом 3 и берёт [tlsMapFromQuery] с `reality: true` и [transportMapFromQuery]
/// как есть. Поэтому параметры различий (алиасы `fp`, дефолт отпечатка,
/// plaintext-порты, REALITY) — аргументы, а не ветки по схеме внутри.
library;

import '../../../models/node_warning.dart';
import '../transport.dart'
    show
        decodeResidualPercent,
        mergeXhttpExtra,
        splitEarlyDataPath,
        warnEchIgnored;
import '../utls_fingerprint.dart'
    show kUtlsFingerprints, normalizeUtlsFingerprintValue;

/// Ключи `insecure` в форме прибытия — объединение обоих проектов
/// (реестр `tls.json` /tls/params/insecure, DRIFT §2(a)).
///
/// Сверка идёт по lower со снятием `-`/`_`, как записано в контракте: иначе
/// таблица разъезжается с Go на каждом новом написании.
const _kInsecureKeys = {
  'insecure',
  'allowinsecure',
  'skipcertverify',
  'noverify',
};

/// Истина query-bool в форме прибытия: `1`, `true`, `yes` (контракт —
/// единообразно у обеих сторон).
bool _queryTruthy(String v) {
  final s = v.trim().toLowerCase();
  return s == '1' || s == 'true' || s == 'yes';
}

/// `tls.insecure` из query по семейству имён.
///
/// Судить тут нечего: ключ либо просили, либо нет. Значение вне тройки
/// `1|true|yes` — это «не просили» у обеих сторон, а не мусор под код.
bool insecureFromQuery(Map<String, String> q) {
  for (final e in q.entries) {
    final k = e.key.toLowerCase().replaceAll('-', '').replaceAll('_', '');
    if (_kInsecureKeys.contains(k) && _queryTruthy(e.value)) return true;
  }
  return false;
}

/// §472 — `tls` в форме карты sing-box, либо `null` (блока нет вовсе).
///
/// `null` вместо `{enabled: false}` — правило реестра `security_none_no_tls`
/// (`tls.json` mapper): ссылка без TLS даёт тело ВОВСЕ без ключа `tls`, а
/// явный `enabled:false` роняет ядра lx.5–lx.18 в SIGSEGV (SPEC 045). Это
/// вопрос СТРУКТУРЫ («есть ли блок»), и отвечает на него маппер: санитайзеру
/// отсутствие ключа неотличимо от «не задано».
///
/// [plaintextPorts] — правило `plaintext_port_no_tls` (только vless, шаг 3):
/// на известном открытом порту ссылка без `security` читается как открытый
/// TCP. У trojan такой эвристики нет — дефолт «TLS включён»
/// (`protocols/trojan.json`, `query.security.impl`).
///
/// [fpAliases] — правило `fp` у vless читается и как `fingerprint`, у trojan
/// только как `fp` (`protocols/trojan.json`: «алиас `fingerprint` у trojan НЕ
/// читается»). [defaultFingerprint] — правило `fp_empty_defaults_to_random`
/// (vless/anytls); у trojan дефолта нет, пустой `fp` блока не даёт.
///
/// Значения кладутся КАК ПРИШЛИ: отпечаток в чужом написании
/// (`HelloChrome_120`), ALPN с остатком percent-кодирования, `short_id` не в
/// hex. Написание диалекта — работа маппера, годность — работа реестра.
/// [sniHeuristic] — правило `sni_heuristic_falls_back_to_server`: имя без
/// точки и двоеточия (либо `🔒` из витрин подписок) адресом быть не может и
/// уступает серверу. Реестр объявляет его у hysteria2 и anytls; у trojan и
/// vless его НЕТ ни на одном входе LxBox, и включение там сдвинуло бы тела и
/// identity живых узлов (расхождение названо в `mapper_rules_coverage_test`).
/// Поэтому это аргумент, а не общее поведение.
Map<String, dynamic>? tlsMapFromQuery(
  Map<String, String> q,
  String server,
  int port, {
  Set<int> plaintextPorts = const {},
  List<String> sniAliases = const ['sni', 'peer', 'host'],
  List<String> fpAliases = const ['fp'],
  String defaultFingerprint = '',
  bool reality = false,
  bool sniHeuristic = false,
  List<NodeWarning>? warnings,
}) {
  // §320 — `ech=` в тело не переносится (правило `ech_param_dropped_with_code`
  // реестра): ключа ECH ссылка не несёт, а чужой ключ рвёт рукопожатие. О
  // потере говорит маппер — в теле этого значения уже нет, санитайзеру сказать
  // о нём нечего.
  if (warnings != null) warnEchIgnored(q, warnings);

  final sec = (q['security'] ?? '').toLowerCase().trim();
  // `security_none_no_tls` — блока нет.
  if (sec == 'none') return null;
  // `plaintext_port_no_tls` — тот же вопрос «есть ли блок».
  if (sec.isEmpty && plaintextPorts.contains(port)) return null;

  // `sni_heuristic_falls_back_to_server` — выбор ИСТОЧНИКА поля, а не
  // суждение о значении: цепочка алиасов и откат на адрес сервера.
  //
  // [sniAliases] — сама цепочка. Диалекты расходятся её серединой: у
  // share-URI это `sni` → `peer` → `host`, у контейнера v2rayN — `sni` →
  // `host` (ключа `peer` у него нет, `protocols/vmess.json` →
  // `uri.query.sni.impl`). Аргумент, а не ветка по схеме внутри.
  var sni = '';
  for (final alias in sniAliases) {
    final v = q[alias] ?? '';
    if (v.isNotEmpty) {
      sni = v;
      break;
    }
  }
  // `sni_heuristic_falls_back_to_server` — выбор ИСТОЧНИКА поля: имя без
  // точки и двоеточия адресом быть не может, `🔒` это витринный значок
  // подписки. Оба проекта судят так у hysteria2 и anytls.
  if (sniHeuristic &&
      sni.isNotEmpty &&
      (sni == '🔒' || (!sni.contains('.') && !sni.contains(':')))) {
    sni = '';
  }
  if (sni.isEmpty) sni = server;

  var fp = '';
  for (final alias in fpAliases) {
    final v = (q[alias] ?? '').trim();
    if (v.isNotEmpty) {
      fp = v;
      break;
    }
  }
  if (fp.isEmpty) fp = defaultFingerprint;

  final tls = <String, dynamic>{
    'enabled': true,
    'server_name': sni,
  };

  if (insecureFromQuery(q)) tls['insecure'] = true;

  // `alpn_comma_list` — одна строка ссылки → список тела, каждый элемент
  // обрезан. Реестр зовёт `tls.alpn` listable БЕЗ нормализации («пишется в
  // той форме, в какой пришло»), потому что фиксированного enum у ядра нет:
  // раскрутить `http%252F1.1` до `http/1.1` — это дочитать ЗАПИСЬ значения,
  // работа маппера, а не суждение о нём.
  final alpn = [
    for (final e in (q['alpn'] ?? '').split(','))
      if (_decodeAlpnElement(e).isNotEmpty) _decodeAlpnElement(e),
  ];
  if (alpn.isNotEmpty) tls['alpn'] = alpn;

  // `utls` — блок появляется РОВНО когда отпечаток задан (или есть дефолт
  // схемы). Пустой `fp` у trojan блока не даёт: ядро возьмёт свой дефолт, а
  // пустой `utls` менял бы тело на ровном месте.
  //
  // `utls_xray_hello_names` — написание отпечатка в диалекте uTLS
  // (`HelloChrome_120`) переводится в имя семейства, которое понимает
  // sing-box. Это перевод НАПИСАНИЯ (`kind: spelling` у правила), а не
  // суждение: enum реестра знает только имена семейств, и неопознанный мусор
  // санитайзер сам сведёт к `chrome` с кодом `utls_fp_unknown`.
  if (fp.isNotEmpty) {
    tls['utls'] = <String, dynamic>{
      'enabled': true,
      'fingerprint': utlsSpellingToFamily(fp),
    };
  }

  // `pbk_makes_reality_block` — НАЛИЧИЕ блока решает маппер, годность ключа
  // судит реестр (`tls.reality.public_key`, format `base64_32`).
  if (reality) {
    final pbk = (q['pbk'] ?? '').trim();
    if (pbk.isNotEmpty) {
      tls['reality'] = <String, dynamic>{
        'enabled': true,
        'public_key': pbk,
        if ((q['sid'] ?? '').trim().isNotEmpty) 'short_id': q['sid']!.trim(),
        if ((q['key_share'] ?? '').trim().isNotEmpty)
          'key_share': q['key_share']!.trim(),
      };
    }
  }

  return tls;
}

/// Результат перевода транспорта: карта тела плюс то, чего в теле не
/// выразить.
///
/// §103 D-008 — заголовок early data подставлен САМОЙ формой `?ed=N` хвостом
/// пути, а не написан автором. Телу эта разница не видна
/// (`early_data_header_name` стоит в обоих случаях, так требует корпус), а
/// `toUri()` без неё дописывал бы в ссылку `eh=`, которого в ней не было:
/// Go для path-tail формы тоже пишет обратно только `?ed=N`
/// (`shareuri_helpers.go`).
final class TransportMapping {
  const TransportMapping(this.map, {this.wsEarlyDataHeaderImplicit = false});

  /// Карта транспорта; `null` — транспорта нет.
  final Map<String, dynamic>? map;

  final bool wsEarlyDataHeaderImplicit;
}

/// §472 — `transport` в форме карты sing-box, либо `null` (транспорта нет).
///
/// Перевод имён — правило `transport_name_dialect` реестра
/// (`transports.json` mapper): `headerType=http` поверх `tcp|raw` → `http`,
/// `net=h2` → `http`, Xray `splithttp` → `xhttp`. Перевод раскладки —
/// `ws_early_data_path_suffix`: `?ed=N` хвостом пути становится
/// `max_early_data` + `early_data_header_name`.
///
/// [networkOverride] — транспорт лежит под другим ключом, чем `type` (VMess
/// хранит в `network`). [defaultHost] — откат host для `h2`.
///
/// Путь кладётся КАК ПРИШЁЛ после снятия остаточного percent-кодирования
/// (§320: это довод декодирования до конца, а не суждение). Битый путь
/// (`%zz`) остаётся в карте — его снимет реестр по `format: url_path`, и код
/// `type_invalid` придёт оттуда с путём и значением.
TransportMapping transportMapFromQuery(
  Map<String, String> q, {
  String? networkOverride,
  String? defaultHost,
  List<NodeWarning>? warnings,
}) {
  final typ = ((networkOverride ?? q['type']) ?? '').toLowerCase().trim();
  final headerType = (q['headerType'] ?? '').toLowerCase().trim();

  // `transport_name_dialect` — Xray-камуфляж поверх TCP/RAW зовётся `http`.
  if ((typ == 'raw' || typ == 'tcp') && headerType == 'http') {
    return TransportMapping(_httpMap(q, q['path'] ?? '/', (q['host'] ?? '').trim()));
  }

  switch (typ) {
    case 'ws':
      // §103 D-016(в) — ключа не было вовсе → путь не задан (не эмитим).
      final pathPresent = q.containsKey('path');
      final (splitPath, edFromPath) =
          splitEarlyDataPath(decodeResidualPercent(q['path'] ?? ''));
      var host = (q['host'] ?? '').trim();
      if (host.isEmpty) host = (q['sni'] ?? '').trim();
      if (host.isEmpty) host = (q['obfsParam'] ?? '').trim();

      // `ws_early_data_path_suffix` — хвост пути в приоритете над плоским
      // `ed`: он адресует конкретный путь, а не ссылку целиком.
      final ed = edFromPath ?? _positiveInt(q['ed']);
      // `eh` без `ed` — ничто: режим включает `max_early_data > 0`.
      // §103 D-008 — path-tail форма подразумевает дефолтный заголовок (Go
      // подставляет его при разборе самого хвоста), плоские `ed`/`eh` — нет.
      final eh = ed == null
          ? ''
          : _nonEmpty(q['eh']) ??
              (edFromPath != null ? 'Sec-WebSocket-Protocol' : '');

      // Путь уехал в тело НЕ буквально — о переводе говорит маппер.
      if (edFromPath != null) {
        warnings?.add(WsEarlyDataConvertedWarning(edFromPath));
      }
      return TransportMapping(
        <String, dynamic>{
          'type': 'ws',
          if (pathPresent) 'path': splitPath,
          if (host.isNotEmpty) 'headers': <String, dynamic>{'Host': host},
          'max_early_data': ?ed,
          if (eh.isNotEmpty) 'early_data_header_name': eh,
        },
        wsEarlyDataHeaderImplicit:
            edFromPath != null && _nonEmpty(q['eh']) == null,
      );
    case 'grpc':
      // §468 — значение идёт ядру как есть, ведущий «/» разбирает ядро само.
      final sn =
          (q['serviceName'] ?? q['service_name'] ?? q['path'] ?? '').trim();
      return TransportMapping(<String, dynamic>{
        'type': 'grpc',
        if (sn.isNotEmpty) 'service_name': sn,
      });
    case 'http':
      return TransportMapping(
          _httpMap(q, q['path'] ?? '/', (q['host'] ?? '').trim()));
    case 'h2':
      // SPEC 103 CANON — голый `type=h2` в query ссылки Go не распознаёт
      // вовсе; `h2` законен только как VMess `net` ([networkOverride]).
      if (networkOverride == null) return const TransportMapping(null);
      var host = (q['host'] ?? '').trim();
      if (host.isEmpty) host = (q['sni'] ?? '').trim();
      if (host.isEmpty && defaultHost != null) host = defaultHost;
      return TransportMapping(_httpMap(q, q['path'] ?? '/', host));
    case 'httpupgrade':
      // §303 — early data у httpupgrade в sing-box нет: хвост срезаем, `ed`
      // отбрасываем (иначе он уедет в путь и даст 404), включая плоскую форму.
      final hasPath = q.containsKey('path');
      final (splitPath, _) =
          splitEarlyDataPath(decodeResidualPercent(q['path'] ?? ''));
      // §103 D-016(в) — у httpupgrade отката host на sni НЕТ (в отличие от ws).
      final host = (q['host'] ?? '').trim();
      return TransportMapping(<String, dynamic>{
        'type': 'httpupgrade',
        if (hasPath) 'path': splitPath,
        if (host.isNotEmpty) 'host': host,
      });
    // `transport_name_dialect` — `splithttp` = прежнее имя `xhttp` в Xray.
    case 'splithttp':
    case 'xhttp':
      return TransportMapping(_xhttpMap(mergeXhttpExtra(q)));
    case 'raw':
    case 'tcp':
    case '':
      return const TransportMapping(null);
    default:
      return const TransportMapping(null);
  }
}

/// `http`-транспорт тела: путь и список хостов.
///
/// `hosts` у ядра — массив, а ссылка несёт одну строку: та же `split`-форма
/// перевода, что у ALPN.
Map<String, dynamic> _httpMap(
  Map<String, String> q,
  String path,
  String host,
) =>
    <String, dynamic>{
      'type': 'http',
      if (path.isNotEmpty && path != '/') 'path': path,
      if (host.isNotEmpty) 'host': <String>[host],
    };

/// XHTTP — плоские ключи ссылки в обеих формах (camelCase Xray и snake_case
/// sing-box) → карта тела в ключах sing-box.
///
/// Состав полей — тот же, что читает `xhttpFromMap` (§399): расхождение схем
/// между входами это дефект. Здесь только перевод НАПИСАНИЯ ключа; числовые
/// формы (`30.0` → `30`) и диапазоны судит реестр.
Map<String, dynamic> _xhttpMap(Map<String, String> m) {
  final out = <String, dynamic>{'type': 'xhttp'};
  final hasPath = m.containsKey('path');
  final (splitPath, _) = splitEarlyDataPath(m['path'] ?? '');
  if (hasPath && splitPath.isNotEmpty) out['path'] = splitPath;
  final host = (m['host'] ?? '').trim();
  if (host.isNotEmpty) out['host'] = host;
  for (final e in _kXhttpKeys.entries) {
    final v = (m[e.key] ?? m[e.value] ?? '').trim();
    if (v.isNotEmpty) out[e.value] = v;
  }
  return out;
}

/// XHTTP: написание camelCase (Xray URI) → ключ sing-box. camelCase в
/// приоритете, как у `xhttpFromMap`.
const _kXhttpKeys = <String, String>{
  'mode': 'mode',
  'xPaddingBytes': 'x_padding_bytes',
  'noGRPCHeader': 'no_grpc_header',
  'sessionPlacement': 'session_placement',
  'sessionKey': 'session_key',
  'seqPlacement': 'seq_placement',
  'seqKey': 'seq_key',
  'uplinkDataPlacement': 'uplink_data_placement',
  'uplinkDataKey': 'uplink_data_key',
  'uplinkChunkSize': 'uplink_chunk_size',
  'uplinkHTTPMethod': 'uplink_http_method',
  'xPaddingObfsMode': 'x_padding_obfs_mode',
  'xPaddingKey': 'x_padding_key',
  'xPaddingHeader': 'x_padding_header',
  'xPaddingPlacement': 'x_padding_placement',
  'xPaddingMethod': 'x_padding_method',
  'scMaxEachPostBytes': 'sc_max_each_post_bytes',
  'scMinPostsIntervalMs': 'sc_min_posts_interval_ms',
  'scStreamUpServerSecs': 'sc_stream_up_server_secs',
  'scMaxBufferedPosts': 'sc_max_buffered_posts',
  'noSSEHeader': 'no_sse_header',
  'maxConnections': 'max_connections',
  'maxConcurrency': 'max_concurrency',
  'cMaxReuseTimes': 'c_max_reuse_times',
  'hMaxRequestTimes': 'h_max_request_times',
  'hMaxReusableSecs': 'h_max_reusable_secs',
  'hKeepAlivePeriod': 'h_keep_alive_period',
};

/// §472 — правило реестра `utls_xray_hello_names` (`tls.json` mapper):
/// написание отпечатка идентификатором библиотеки uTLS → имя семейства,
/// которое понимает sing-box.
///
/// Таблица префиксов — одна на проект ([normalizeUtlsFingerprintValue],
/// `utls_fingerprint.dart`): второй копии заводить нельзя, она разъехалась бы
/// на первом же бампе. Отсюда берётся ТОЛЬКО перевод написания: значение, в
/// котором таблица псевдонима не нашла, возвращается КАК ПРИШЛО — судит его
/// санитайзер (`utls.fingerprint`, enum + `on_invalid: coerce chrome` с кодом
/// `utls_fp_unknown`). Прежний `normalizeUtlsFingerprintValue` на таком
/// значении сам подставлял `chrome` — это суждение, и на конвейере оно уходит
/// в реестр.
String utlsSpellingToFamily(String raw) {
  final s = raw.trim().toLowerCase();
  if (s.isEmpty) return s;
  if (kUtlsFingerprints.contains(s)) return s;
  final n = normalizeUtlsFingerprintValue(s);
  // `junk` — псевдоним не опознан: значение идёт в карту как есть.
  return n.junk ? s : n.value;
}

/// §151 F2 / §320 — дочитать запись элемента ALPN до конца.
///
/// Агрегаторы шлют `alpn=http%252F1.1` (а встречается и вложенное вчетверо):
/// `Uri.queryParameters` декодирует ровно один раз, и в теле остаётся
/// `%XX`-хвост. Раскрутка до стабильной точки — это чтение того же значения,
/// а не подмена: `h2`, `http/1.1`, `h3` она не трогает. Эталон Go —
/// `normalizePercentDecodeLoop` (node_parser_transport.go).
///
/// Потолок 16 проходов — защита от патологического ввода: легитимный
/// multiply-encoding стабилизируется за 3–5.
String _decodeAlpnElement(String raw) {
  var e = raw.trim();
  var guard = 0;
  while (e.contains('%') && guard < 16) {
    final decoded = Uri.tryParse('x://x?a=$e')?.queryParameters['a'];
    if (decoded == null || decoded == e) break;
    e = decoded.trim();
    guard++;
  }
  return e;
}

/// Положительное целое из query-значения; иначе `null`.
int? _positiveInt(String? v) {
  final n = int.tryParse((v ?? '').trim());
  return n != null && n > 0 ? n : null;
}

/// Непустая обрезанная строка; иначе `null`.
String? _nonEmpty(String? v) {
  final s = (v ?? '').trim();
  return s.isEmpty ? null : s;
}

/// §453 — dial-поля keep-alive в ключах sing-box.
///
/// Имена параметров ссылки уже совпадают с ключами тела (прецедент §453),
/// поэтому переводить нечего — только разложить по ключам. Guard на
/// Go-duration тут НЕ ставится: форму значения судит реестр
/// (`dialer.json`, `type: duration`), как и у всех прочих полей.
Map<String, dynamic> tcpKeepAliveMapFromQuery(Map<String, String> q) {
  final out = <String, dynamic>{};
  final disabled = (q['disable_tcp_keep_alive'] ?? '').toLowerCase().trim();
  if (disabled == '1' || disabled == 'true') {
    out['disable_tcp_keep_alive'] = true;
  }
  final idle = (q['tcp_keep_alive'] ?? '').trim();
  if (idle.isNotEmpty) out['tcp_keep_alive'] = idle;
  final interval = (q['tcp_keep_alive_interval'] ?? '').trim();
  if (interval.isNotEmpty) out['tcp_keep_alive_interval'] = interval;
  return out;
}
