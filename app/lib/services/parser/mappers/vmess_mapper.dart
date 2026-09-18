/// §472 шаг 4 — маппер vmess: перевод ОБОИХ диалектов ссылки в карту sing-box.
///
/// vmess — единственная схема, у которой ссылка не URI, а контейнер. За
/// `vmess://` лежит base64, и внутри него — одна из двух форм:
///
/// - **v2rayN JSON** (`{"v":"2","ps":…,"add":…,"port":…,"id":…,"net":…}`) —
///   основная. Поля контейнера названы по-своему (`add` вместо `server`,
///   `id` вместо `uuid`, `scy` вместо `security`), и всё, что в других схемах
///   приходит query-параметрами, здесь лежит ключами объекта;
/// - **legacy cleartext** (`method:uuid@host:port?type=ws&tls=1`) — правило
///   реестра `legacy_cleartext_fallback` (`protocols/vmess.json` → mapper):
///   старые панели выдают ссылку без JSON, и эта форма пробуется, прежде чем
///   узел отбросят. Транспорт и TLS у неё в query-хвосте, как у обычного
///   share-URI.
///
/// **Обе формы дают ОДНУ карту.** Различаются они только СЛОВАРЁМ — где взять
/// значение, — и различие выражено тем, что общие части ([tlsMapFromQuery],
/// [transportMapFromQuery]) принимают `Map<String, String>`, а не
/// `Uri.queryParameters`. Шаг 4 для этого их и обобщил: JSON-объект v2rayN
/// приводится к той же плоской карте «имя → строка», и дальше обе формы идут
/// общим кодом. Ветки по диалекту внутри общих частей нет ни одной.
///
/// Чего маппер НЕ судит: годность `scy` (enum ядра, `body.fields.security` с
/// `on_invalid: coerce auto`), написание `fp`, форму `alter_id`, значение
/// `packet_encoding`. Всё это — правила значений реестра.
library;

import 'dart:convert';

import '../../../models/node_warning.dart';
import '../uri_utils.dart';
import 'common_parts.dart';
import 'uri_mapper.dart';

/// Порт по умолчанию, когда `port` контейнера не разбирается
/// (`protocols/vmess.json` → `uri.query.port.impl`: «Go — drop ноды; Dart —
/// fallback 443, мелкое расхождение деградации»). Поведение сохранено как
/// было: identity живых узлов от шага 4 не двигается.
const _kDefaultPort = 443;

/// `vmess://base64(…)` → сырая карта sing-box.
///
/// `null` — ссылки нет: не base64, пустой payload, либо ни одна из двух форм
/// не прочиталась (нет `add`/`id` у JSON, нет `@` у cleartext).
UriMapping? mapVmessUri(String uri) {
  if (!uri.toLowerCase().startsWith('vmess://')) return null;
  var payload = uri.substring('vmess://'.length);
  var fragment = '';
  final hashIdx = payload.indexOf('#');
  if (hashIdx >= 0) {
    fragment = payload.substring(hashIdx + 1);
    payload = payload.substring(0, hashIdx);
  }

  final bytes = decodeBase64Safe(payload);
  if (bytes == null || bytes.isEmpty) return null;
  final decoded = utf8Lossy(bytes).trim();
  if (decoded.isEmpty) return null;

  // Порядок форм нормативен: JSON пробуется первым, cleartext — правило
  // `legacy_cleartext_fallback`, то есть именно откат.
  try {
    final j = jsonDecode(decoded);
    if (j is Map<String, dynamic>) return _fromJsonContainer(j);
  } catch (_) {}

  return _fromLegacyCleartext(decoded, fragment);
}

/// Форма v2rayN: JSON-объект внутри base64.
///
/// Фрагмент ссылки здесь НЕ читается — так у обеих сторон
/// (`protocols/vmess.json` → `uri.userinfo.impl`: Go не передаёт фрагмент в
/// `parseVMessJSON`, Dart не передавал в `_vmessFromJson`). Имя узла берётся
/// из ключа `ps`.
UriMapping? _fromJsonContainer(Map<String, dynamic> cfg) {
  final server = cfg['add']?.toString() ?? '';
  final id = cfg['id']?.toString() ?? '';
  // `add` и `id` у схемы обязательные: без них записи не построить
  // (`uri.query.add.impl`, `uri.query.id.impl` — «отсутствие → drop ноды»).
  if (server.isEmpty || id.isEmpty) return null;

  final portRaw = cfg['port'];
  final port = portRaw is num
      ? portRaw.toInt()
      : int.tryParse(portRaw?.toString() ?? '') ?? _kDefaultPort;

  final net = (cfg['net']?.toString() ?? 'tcp').toLowerCase().trim();
  final warnings = <NodeWarning>[];

  // Ключи контейнера → плоская карта «имя → строка», в которой общие части
  // читают ровно те же имена, что в query других схем. Это и есть весь
  // перевод диалекта: `host`, `path`, `sni`, `alpn`, `fp` названы одинаково,
  // `scy`/`add`/`id`/`aid` разобраны выше отдельно.
  //
  // `null` ключа и ключ-отсутствие тут неразличимы намеренно: корпусный
  // `json_security_key_null` требует, чтобы `"scy": null` читалось как
  // «не задано», а не как строка «null».
  final q = <String, String>{
    for (final key in _kContainerStringKeys)
      if (cfg[key] != null) key: cfg[key].toString(),
    // SPEC 071/103 `vmess/json_net_xhttp` — при `net=xhttp` ключ `mode` лежит
    // в самом объекте v2rayN, наравне с `path`/`host`.
    if (net == 'xhttp' && cfg['mode'] != null) 'mode': cfg['mode'].toString(),
  };

  final transport = transportMapFromQuery(
    q,
    networkOverride: net,
    // `net=h2` без `host` берёт адресом сам сервер (`transports.json`).
    defaultHost: server,
    warnings: warnings,
  );

  final body = <String, dynamic>{
    'type': 'vmess',
    'server': server,
    'server_port': port,
    'uuid': id,
    // `security` у схемы `required` и эмитится всегда, даже дефолтом
    // (`body.fields.security.impl` — json-тег без omitempty). Значение идёт
    // КАК ПРИШЛО: enum и коэрсинг в `auto` — правило реестра.
    'security': _securitySpelling(cfg),
    if (_alterId(cfg) != 0) 'alter_id': _alterId(cfg),
  };

  // `tls='tls'` включает TLS; `net=h2` включает его принудительно
  // (`uri.query.tls.impl`, оба проекта). Это вопрос СТРУКТУРЫ — есть ли блок,
  // — и отвечает на него маппер, как `security_none_no_tls` у прочих схем.
  final tlsOn = (cfg['tls']?.toString() ?? '') == 'tls' || net == 'h2';
  if (tlsOn) {
    final tls = tlsMapFromQuery(
      q,
      server,
      port,
      // SNI-цепочка vmess-контейнера — `sni` → `host` → сервер
      // (`uri.query.sni.impl`). У прочих схем средним звеном идёт `peer`;
      // разница — аргумент, а не ветка внутри.
      sniAliases: const ['sni', 'host'],
      warnings: warnings,
    );
    if (tls != null) body['tls'] = tls;
  }

  if (transport.map != null) body['transport'] = transport.map;

  return UriMapping(
    body: body,
    label: sanitizeForDisplay(cfg['ps']?.toString() ?? ''),
    warnings: warnings,
    // §453 — в base64-JSON dial-поля лежат ключами самого объекта v2rayN, под
    // именами sing-box. Мимо санитайзера — по той же причине, что у trojan и
    // vless (`UriMapping.extensionFields`).
    extensionFields: _keepAliveFromContainer(cfg),
    wsEarlyDataHeaderImplicit: transport.wsEarlyDataHeaderImplicit,
  );
}

/// Ключи контейнера, которые общие части читают под теми же именами.
///
/// `ech` в списке ровно затем, чтобы дойти до [tlsMapFromQuery] и БЫТЬ ТАМ
/// ОТБРОШЕННЫМ с кодом (`ech_param_dropped_with_code`): ссылочная форма ECH
/// адреса в теле sing-box не имеет, а чужой ключ рвёт рукопожатие (§320).
/// Без него потеря была бы молчаливой.
const _kContainerStringKeys = <String>[
  'path',
  'host',
  'sni',
  'serviceName',
  'alpn',
  'fp',
  'insecure',
  'ech',
];

/// Форма legacy cleartext: `method:uuid@host:port?query` внутри base64.
///
/// Правило `legacy_cleartext_fallback`. Транспорт и TLS — из query-хвоста,
/// как у обычного share-URI; имя узла — из фрагмента ССЫЛКИ (в отличие от
/// JSON-формы, где фрагмент не читается вовсе).
UriMapping? _fromLegacyCleartext(String s, String fragment) {
  final atIdx = s.indexOf('@');
  if (atIdx < 0) return null;
  final userinfo = s.substring(0, atIdx);
  final rest = s.substring(atIdx + 1);
  final qIdx = rest.indexOf('?');
  final hostPort = qIdx < 0 ? rest : rest.substring(0, qIdx);
  final rawQuery = qIdx < 0 ? '' : rest.substring(qIdx + 1);

  // `method:uuid` — двоеточие обязательно; uuid может содержать свои.
  final parts = userinfo.split(':');
  if (parts.length < 2) return null;
  final method = parts[0].trim();
  final uuid = parts.sublist(1).join(':').trim();
  if (method.isEmpty || uuid.isEmpty) return null;

  final lastColon = hostPort.lastIndexOf(':');
  if (lastColon <= 0) return null;
  final host = hostPort.substring(0, lastColon);
  final port = int.tryParse(hostPort.substring(lastColon + 1)) ?? _kDefaultPort;

  final q = rawQuery.isEmpty
      ? const <String, String>{}
      : Uri.splitQueryString(rawQuery);
  final warnings = <NodeWarning>[];

  // У cleartext-формы транспорт зовётся `type`, а не `net`
  // (`uri.query.net.aliases`: «type (fallback в legacy cleartext query»).
  final net = (q['type'] ?? '').toLowerCase().trim();
  final transport = transportMapFromQuery(
    q,
    networkOverride: net.isEmpty ? null : net,
    warnings: warnings,
  );

  final body = <String, dynamic>{
    'type': 'vmess',
    'server': host,
    'server_port': port,
    'uuid': uuid,
    // Тот же словарь, что у контейнера: у cleartext-формы шифр стоит первым
    // полем userinfo, а не ключом `scy`.
    'security': _securitySpelling(<String, dynamic>{'scy': method}),
  };

  // `tls=1|true|tls` — семейство истины этой формы (`uri.query.tls.impl`).
  final tlsRaw = (q['tls'] ?? '').toLowerCase().trim();
  if (tlsRaw == '1' || tlsRaw == 'true' || tlsRaw == 'tls') {
    final tls = tlsMapFromQuery(
      q,
      host,
      port,
      // Цепочка share-URI: `sni` → `peer` → сервер. Ключ `host` здесь
      // адресует транспорт, а не SNI, — этим форма и отличается от JSON.
      sniAliases: const ['sni', 'peer'],
      warnings: warnings,
    );
    if (tls != null) body['tls'] = tls;
  }

  if (transport.map != null) body['transport'] = transport.map;

  return UriMapping(
    body: body,
    label: sanitizeForDisplay(decodeFragment(fragment)),
    warnings: warnings,
    extensionFields: tcpKeepAliveMapFromQuery(q),
    wsEarlyDataHeaderImplicit: transport.wsEarlyDataHeaderImplicit,
  );
}

/// Шифр канала из контейнера: ключ `scy`, алиас `security`.
///
/// Перевод написания здесь бесспорен: `chacha20-ietf-poly1305` — имя того же
/// шифра в диалекте Xray, ядро знает его как `chacha20-poly1305`
/// (`uri.query.scy.impl`). Без перевода реальный шифр подписки схлопнулся бы
/// в `auto`, то есть канал шифровался бы не тем, о чём договорились. Пустое
/// значение и записи отсутствия (`'null'`, `'undefined'` строкой — их шлют
/// реальные панели, корпус `json_scy_null_to_auto`) дают дефолт схемы `auto`:
/// ключ `security` у тела обязателен.
///
/// **А вот сведение МУСОРА к `auto` осталось рукописным СУЖДЕНИЕМ — и это
/// третий пункт запроса к лаунчеру (отчёт шага 4).** Правило значения у
/// реестра есть (`body.fields.security`: enum + `on_invalid: coerce auto`,
/// код `type_invalid`), и отдать значение санитайзеру было бы правильнее
/// всего. Мешает корпус: `vmess/vmess_security_ctr` на `scy=aes-128-ctr` ждёт
/// `security: auto` и НИ ОДНОГО кода, то есть у лаунчера подмена молчит.
/// Отдай конвейер значение как есть — LxBox начал бы показывать человеку
/// `type_invalid` там, где вторая сторона молчит, и корпус бы покраснел.
/// Заводить на это per-app override нельзя (инвариант 1 спеки), а правила
/// «код только на входе body» реестр не знает: `except_sources` (§473,
/// контракт 1.1.5) объявлен ровно для `max_when`.
///
/// **Просьба:** решить, кто прав. Либо `on_invalid.code` у `security` снять
/// (подмена на рабочий дефолт — не потеря поля, а текст кода
/// `type_invalid` — «поле снято: неверный тип» — про этот случай врёт), либо
/// ожидание корпуса дополнить кодом, и тогда строка ниже уходит вся.
/// Сегодня набор ядра в Dart остаётся ([kVmessSecurityMethods]).
String _securitySpelling(Map<String, dynamic> cfg) {
  final raw = (cfg['scy'] ?? cfg['security'])?.toString().trim() ?? '';
  final s = raw.toLowerCase();
  if (s.isEmpty || s == 'null' || s == 'undefined') return 'auto';
  if (s == 'chacha20-ietf-poly1305') return 'chacha20-poly1305';
  // Рукописное суждение — см. doc выше.
  return kVmessSecurityMethods.contains(s) ? s : 'auto';
}

/// `aid` контейнера числом или строкой (оба вида читают обе стороны).
int _alterId(Map<String, dynamic> cfg) {
  final raw = cfg['aid'];
  if (raw is num) return raw.toInt();
  return int.tryParse(raw?.toString() ?? '') ?? 0;
}

/// §453 — dial-поля из ключей самого объекта v2rayN (имена sing-box).
Map<String, dynamic> _keepAliveFromContainer(Map<String, dynamic> cfg) {
  final out = <String, dynamic>{};
  if (cfg['disable_tcp_keep_alive'] == true) {
    out['disable_tcp_keep_alive'] = true;
  }
  final idle = cfg['tcp_keep_alive']?.toString().trim() ?? '';
  if (idle.isNotEmpty) out['tcp_keep_alive'] = idle;
  final interval = cfg['tcp_keep_alive_interval']?.toString().trim() ?? '';
  if (interval.isNotEmpty) out['tcp_keep_alive_interval'] = interval;
  return out;
}
