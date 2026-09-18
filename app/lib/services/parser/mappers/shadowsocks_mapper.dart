/// §472 шаг 4 — маппер shadowsocks: перевод ссылки в карту sing-box.
///
/// Как и у vmess, ссылка здесь не URI: пара «метод:пароль» лежит в base64, и
/// у legacy-формы внутрь base64 уехали ещё и адрес с портом. `Uri.tryParse`
/// приводит authority к нижнему регистру и такой payload разрушает, поэтому
/// маппер работает с текстом (см. [UriMapper]).
///
/// Три формы записи, все — вопрос СТРУКТУРЫ, то есть работа маппера:
///
/// - **SIP002** — `ss://base64(method:password)@host:port[?query]#name`:
///   userinfo кодирован, адрес открыт;
/// - **legacy** — `ss://base64(method:password@host:port)#name`: в base64
///   уехала вся запись, до-SIP002 формат;
/// - **SS2022** (`2022-blake3-*`) — та же SIP002-форма, особенность в
///   ПАРОЛЕ: он base64-ключ (а у `2022-blake3-aes-*` бывает составным,
///   `k1:k2` — ключ сервера и ключ пользователя). Отдельной ветки не
///   требует: пароль — это всё, что идёт после ПЕРВОГО `:`, и составной
///   пароль сохраняется целиком именно поэтому.
///
/// Судит значения реестр (`protocols/shadowsocks.json` → `body.fields`):
/// метод вне набора из восемнадцати — `drop_node` с `ss_method_invalid`,
/// девять stream-шифров — `advisory` с `ss_method_legacy` (D-122). Рукописных
/// правил значения у схемы не осталось ни одного.
library;

import '../uri_utils.dart';
import 'common_parts.dart';
import 'uri_mapper.dart';

/// Порт по умолчанию, когда `host:port` не даёт разбираемого числа.
/// Поведение сохранено как было — identity живых узлов не двигается.
const _kDefaultPort = 8388;

/// `ss://…` → сырая карта sing-box.
///
/// `null` — ссылки нет: payload не base64, нет `:` в userinfo, пустой пароль,
/// нет адреса. Годность МЕТОДА здесь не проверяется: это правило значения, и
/// исполняет его санитайзер (`drop_node`), после чего узла точно так же не
/// будет.
UriMapping? mapShadowsocksUri(String uri) {
  if (!uri.toLowerCase().startsWith('ss://')) return null;
  var payload = uri.substring('ss://'.length);
  var fragment = '';
  final hashIdx = payload.indexOf('#');
  if (hashIdx >= 0) {
    fragment = payload.substring(hashIdx + 1);
    payload = payload.substring(0, hashIdx);
  }
  payload = payload.trim();

  String method;
  String password;
  String rest;

  final atIdx = payload.indexOf('@');
  if (atIdx > 0) {
    // SIP002. Userinfo сперва percent-декодируется, потом base64 — панели
    // экранируют `=`-паддинг (`%3D`), корпус `sip002_escaped_padding`.
    final encoded = Uri.decodeComponent(payload.substring(0, atIdx));
    rest = payload.substring(atIdx + 1);
    final decoded = decodeBase64Safe(encoded);
    if (decoded == null) return null;
    final s = utf8Lossy(decoded);
    final colonIdx = s.indexOf(':');
    if (colonIdx <= 0) return null;
    method = s.substring(0, colonIdx).trim();
    // Пароль — ВСЁ после первого `:`: у SS2022 он бывает составным (`k1:k2`),
    // и резать его по второму двоеточию значило бы потерять ключ.
    password = s.substring(colonIdx + 1);
  } else {
    // Legacy: в base64 уехала вся запись целиком.
    final decoded = decodeBase64Safe(Uri.decodeComponent(payload));
    if (decoded == null) return null;
    final s = utf8Lossy(decoded);
    final at = s.indexOf('@');
    if (at <= 0) return null;
    final left = s.substring(0, at);
    rest = s.substring(at + 1).trim();
    final colonIdx = left.indexOf(':');
    if (colonIdx <= 0) return null;
    method = left.substring(0, colonIdx).trim();
    password = left.substring(colonIdx + 1);
  }

  // Пустой пароль — «записи нет» (`uri.query.password.impl`: «Пустой → drop
  // ноды»). Это структура: поля, которое санитайзеру судить, в карте бы не
  // возникло вовсе.
  if (password.isEmpty) return null;

  // rest = `host:port[?query]`.
  final qIdx = rest.indexOf('?');
  final hostPort = qIdx < 0 ? rest : rest.substring(0, qIdx);
  final q = qIdx < 0
      ? const <String, String>{}
      : Uri.splitQueryString(rest.substring(qIdx + 1));

  final String server;
  final int port;
  if (hostPort.startsWith('[')) {
    // IPv6 в скобках: `[2001:db8::1]:8388`.
    final close = hostPort.indexOf(']');
    if (close < 0) return null;
    server = hostPort.substring(1, close);
    final tail = hostPort.substring(close + 1);
    port =
        int.tryParse(tail.startsWith(':') ? tail.substring(1) : tail) ??
            _kDefaultPort;
  } else {
    final colonIdx = hostPort.lastIndexOf(':');
    if (colonIdx <= 0) return null;
    server = hostPort.substring(0, colonIdx);
    port = int.tryParse(hostPort.substring(colonIdx + 1)) ?? _kDefaultPort;
  }

  final body = <String, dynamic>{
    'type': 'shadowsocks',
    'server': server,
    'server_port': port,
    // Значение КАК ПРИШЛО: набор из восемнадцати методов и info-код для
    // девяти stream-шифров — правила реестра (`body.fields.method`).
    'method': method,
    'password': password,
  };

  // SIP003 — `plugin=name;k=v;k=v…`: имя до первого `;`, опции хвостом.
  // Разбор ОДНОЙ строки на два поля тела — перевод раскладки, не суждение;
  // закрытого enum у имени плагина ядро не держит
  // (`body.fields.plugin.impl`). Отдельный `plugin_opts` читается, когда
  // хвоста у `plugin` нет, — так было и у старого парсера.
  final pluginRaw = q['plugin'] ?? '';
  final semi = pluginRaw.indexOf(';');
  if (pluginRaw.isNotEmpty) {
    body['plugin'] = semi < 0 ? pluginRaw : pluginRaw.substring(0, semi);
  }
  // Опции берутся из хвоста `plugin`, а при его отсутствии — из отдельного
  // `plugin_opts`; так было и у старого парсера, включая случай «опции без
  // имени» (в тело ядра они тогда всё равно не уедут — `emitShadowsocks`
  // пишет их только при непустом `plugin`). Реестр знает `plugin_opts`
  // самостоятельным полем без `requires`, так что санитайзер их не снимет.
  final opts =
      semi < 0 ? (q['plugin_opts'] ?? '') : pluginRaw.substring(semi + 1);
  if (opts.isNotEmpty) body['plugin_opts'] = opts;

  return UriMapping(
    body: body,
    label: decodeFragment(fragment),
    // §453 — dial-поля keep-alive; §474 — судятся санитайзером (реестр их
    // описывает). См. `UriMapping.extensionFields`.
    // До переезда они лежали в теле, и санитайзер снимал их как `unknown_key`
    // (тот же дефект, что шаг 3 нашёл у trojan).
    extensionFields: tcpKeepAliveMapFromQuery(q),
  );
}
