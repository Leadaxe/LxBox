/// §472 шаг 6 — маппер naive.
///
/// Словарь ссылки — `registry/protocols/naive.json` → `uri`. Он короток
/// намеренно: у naive ВСЕГО ДВА собственных query-параметра, `extra-headers`
/// и `padding`. Ни `sni`, ни `fp`, ни `alpn`, ни `insecure` диалект naive не
/// знает, и прежний парсер их не читал — поэтому здесь нет вызова
/// [tlsMapFromQuery], которым пользуются trojan/vless/anytls.
///
/// **Блок TLS у naive урезан не мапппером, а самим ядром.** naive-outbound
/// принимает только `enabled`/`server_name`/`certificate`/`certificate_path`/
/// `ech`, остальные поля отвергает при создании (fatal всего конфига).
/// Реестр записывает это правилом `forbidden_for: ["naive"]` на полях
/// `tls.json` с кодом `tls_field_unsupported_naive` (§454/§270), и исполняет
/// его САНИТАЙЗЕР — на входе тела, где такие поля реально приходят. Со
/// ссылки им взяться неоткуда: их некому написать. Маппер кладёт ровно то,
/// что клал прежний парсер, — `enabled` + имя сервера из адреса.
///
/// Что маппер переводит (и не судит):
///
/// - **§465 — одиночный userinfo это PASSWORD.** `naive+https://secret@host`
///   даёт `password=secret` с пустым `username` (конвенция DuckSoft, та же
///   что у hysteria2). Наличие `:` и отличает форму «только имя»: `user:` —
///   это username. Правило отменяло прежнее (текст до `:` = username), потому
///   что расходилось с собственным эмиттером — `toUriNaive` пишет пароль в
///   user-слот, и ссылка, отданная нами же, читалась обратно «наоборот»;
/// - **суффикс схемы задаёт транспорт** (§103 §9.B1): `naive+quic://` это
///   `quic: true` + `quic_congestion_control: bbr` (bbr — единственный
///   поддерживаемый, из ссылки не читается), `naive+https://` — HTTP/2;
/// - **`extra-headers`** — строка `H1: V1\r\nH2: V2` в карту тела. Битая пара
///   пропускается, остальные живут (правило `broken_header_pair_skipped`);
/// - **`padding`** — sing-box-эквивалента нет, параметр отбрасывается с кодом
///   (`naive_padding_ignored`). Это предупреждение О ПЕРЕВОДЕ: значения в теле
///   уже нет, и санитайзеру сказать о нём нечего.
library;

import '../../../models/node_warning.dart';
import '../../app_log.dart';
import '../uri_parsers/naive_parser.dart' show parseNaiveExtraHeaders;
import '../uri_utils.dart';
import 'common_parts.dart';
import 'uri_mapper.dart';

/// Порт по умолчанию (`uri.userinfo.impl` — каноничная форма DuckSoft).
const _kDefaultPort = 443;

/// Известные query-ключи; всё остальное — лог + игнор, как прежде.
///
/// §453 — dial-поля keep-alive в этом списке, иначе naive-узел с ними получал
/// бы ложное «unknown query param … ignoring» в логе на каждом разборе.
const _kKnownQueryKeys = <String>{
  'extra-headers',
  'padding',
  'disable_tcp_keep_alive',
  'tcp_keep_alive',
  'tcp_keep_alive_interval',
};

/// `naive+https://user:pass@host:port?…#label` → сырая карта sing-box.
///
/// [isQuic] — суффикс схемы `naive+quic` (диспетчер режет префикс и передаёт
/// признак явно, потому что транспорт задан ИМЕНЕМ СХЕМЫ, а не параметром).
///
/// `null` — ссылки нет. §463 / контракт §24.6: пустой host отбраковывается —
/// ядро на пустом адресе валит ВЕСЬ конфиг («invalid server address»), то есть
/// один такой узел из подписки оставлял человека вообще без VPN.
UriMapping? mapNaiveUri(String uri, {bool isQuic = false}) {
  final p = Uri.tryParse(uri);
  if (p == null || p.host.isEmpty) return null;

  // §465 — одиночный userinfo это password; см. doc библиотеки.
  var username = '';
  var password = '';
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
  final port = p.hasPort ? p.port : _kDefaultPort;
  final q = Map<String, String>.from(p.queryParameters);
  final warnings = <NodeWarning>[];

  // `padding` — эквивалента в sing-box нет. Код ставит маппер: значения в теле
  // уже не будет, и судить санитайзеру нечего.
  if (q.containsKey('padding')) {
    AppLog.I.warning(
      "naive: 'padding' parameter has no sing-box equivalent, ignoring",
    );
    warnings.add(NaivePaddingIgnoredWarning(q['padding'] ?? ''));
  }

  // Незнакомые query — лог + игнор (в тело они не попадают вовсе, поэтому
  // `unknown_key` санитайзера тут не при чём).
  for (final key in q.keys) {
    if (!_kKnownQueryKeys.contains(key)) {
      AppLog.I.warning("naive: unknown query param '$key', ignoring");
    }
  }

  final body = <String, dynamic>{
    'type': 'naive',
    'server': server,
    'server_port': port,
    if (username.isNotEmpty) 'username': username,
    if (password.isNotEmpty) 'password': password,
  };

  // §103 §9.B1 — транспорт из суффикса схемы.
  if (isQuic) {
    body['quic'] = true;
    body['quic_congestion_control'] = 'bbr';
  }

  // `broken_header_pair_skipped` — разбор строки в карту это СТРУКТУРА, то
  // есть работа маппера; код `naive_extra_headers_invalid` ставится один раз
  // на узел, о первой отброшенной паре.
  final headers =
      parseNaiveExtraHeaders(q['extra-headers'] ?? '', warnings: warnings);
  if (headers.isNotEmpty) {
    // Ключи сортируются лексикографически — так эмитят оба проекта, и так же
    // делал прежний путь (`emitNaive`). Порядок ключей входит в тело, то есть
    // в identity.
    final keys = headers.keys.toList()..sort();
    body['extra_headers'] = <String, dynamic>{
      for (final k in keys) k: headers[k]!,
    };
  }

  // TLS у naive всегда включён и всегда минимален — см. doc библиотеки.
  body['tls'] = <String, dynamic>{'enabled': true, 'server_name': server};

  return UriMapping(
    body: body,
    label: decodeFragment(p.fragment),
    warnings: warnings,
    extensionFields: tcpKeepAliveMapFromQuery(q),
  );
}

/// `naive+https://` — транспорт HTTP/2 (каноничная форма).
///
/// Отдельная функция, а не замыкание: таблица мапперов конвейера `const`, и
/// различие схем у naive лежит в ИМЕНИ СХЕМЫ, а не в query. Тот же приём, что
/// у `hy2` (алиас схемы отдельной записью таблицы).
UriMapping? mapNaiveHttpsUri(String uri) => mapNaiveUri(uri);

/// `naive+quic://` — транспорт QUIC (§103 §9.B1).
UriMapping? mapNaiveQuicUri(String uri) => mapNaiveUri(uri, isQuic: true);
