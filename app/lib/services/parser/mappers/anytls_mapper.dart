/// §472 шаг 6 — маппер anytls.
///
/// Словарь ссылки — `registry/protocols/anytls.json` → `uri`. Форма
/// trojan-подобная (`anytls://password@host:port?…#label`), но TLS-часть
/// читается по конвенции VLESS: у anytls есть REALITY (`pbk`/`sid`), дефолт
/// отпечатка `random` и алиас `fingerprint` — то есть ровно тот набор
/// аргументов общих частей, что у vless.
///
/// Два отличия от vless выражены здесь же:
///
/// - **`security=none` не выключает TLS.** AnyTLS живёт только поверх TLS
///   (`body.fields.tls` → `required`, ядро отвечает `C.ErrTLSRequired`), и
///   `security=none` для него бессмысленен: ключ снимается ДО чтения, иначе
///   правило `security_none_no_tls` унесло бы весь блок вместе с `sni`,
///   `alpn` и `insecure`, которые автор написал. Так делал и прежний парсер —
///   кейс корпуса `security_none_params_kept` нормирует именно это.
/// - **Эвристика SNI включена** (`sni_heuristic_falls_back_to_server`,
///   `applies_to` включает anytls): имя без точки и двоеточия либо `🔒`
///   уступает адресу сервера. У vless её нет; здесь она была и в прежнем
///   парсере, и сохранена байт в байт (§472 шаг 5, заметка 11.13).
library;

import '../../../models/node_warning.dart';
import '../uri_utils.dart';
import 'common_parts.dart';
import 'uri_mapper.dart';

/// Порт по умолчанию (`protocols/anytls.json` → `uri`).
const _kDefaultPort = 443;

/// `anytls://password@host:port?…#label` → сырая карта sing-box.
///
/// `null` — ссылки нет: без хоста или без пароля запись не построить.
UriMapping? mapAnyTlsUri(String uri) {
  final p = Uri.tryParse(uri);
  if (p == null || p.host.isEmpty) return null;

  // userinfo = пароль целиком (`uri.userinfo.impl`): `user:pass` схлопывается
  // обратно, потому что двоеточие — законная часть пароля. Расхождение с Go
  // (он берёт только `Username()`) зафиксировано реестром и сохранено как
  // было: кейс корпуса `percent_encoded_password` нормирует `p@ss:word`.
  final password = Uri.decodeComponent(p.userInfo.split(':').join(':'));
  if (password.isEmpty) return null;

  final server = p.host;
  final port = p.hasPort ? p.port : _kDefaultPort;
  final q = Map<String, String>.from(p.queryParameters);
  final warnings = <NodeWarning>[];

  final body = <String, dynamic>{
    'type': 'anytls',
    'server': server,
    'server_port': port,
    'password': password,
  };

  // Duration-поля: голое число это секунды (`idle_session_*.impl` — та же
  // конвенция, что `heartbeat_bare_number` у tuic). Форма записи — работа
  // маппера; годность значения судит реестр (`type: duration`).
  final check = normalizeSingboxDuration(q['idle_session_check_interval'] ?? '');
  if (check.isNotEmpty) body['idle_session_check_interval'] = check;
  final timeout = normalizeSingboxDuration(q['idle_session_timeout'] ?? '');
  if (timeout.isNotEmpty) body['idle_session_timeout'] = timeout;

  // `min_idle_session` идёт в карту КАК ПРИШЁЛ, числом если число: годность
  // («неотрицательное целое») судит реестр — `min: 0` + `on_invalid: drop` с
  // кодом `anytls_min_idle_invalid`. Рукописный `AnyTlsMinIdleInvalidWarning`
  // на этом пути снят.
  //
  // Нечисловое значение кладётся строкой: `type: int` реестра отвергнет его
  // тем же кодом, а привести его к числу здесь значило бы судить.
  final minIdleRaw = (q['min_idle_session'] ?? '').trim();
  if (minIdleRaw.isNotEmpty) {
    body['min_idle_session'] = int.tryParse(minIdleRaw) ?? minIdleRaw;
  }

  // `security=none` снимается ДО чтения TLS — см. doc библиотеки.
  final tlsQuery = Map<String, String>.from(q)..remove('security');
  final tls = tlsMapFromQuery(
    tlsQuery,
    server,
    port,
    // Цепочка SNI у anytls — `sni` → `peer` → сервер (`uri.query.sni.aliases`).
    // Ключа `host` в ней нет: транспорта у схемы не бывает, и прежний путь
    // (`parseVlessTls`) читал ровно эти два имени. Дефолт общей части
    // (`sni`/`peer`/`host`) добавил бы источник, которого у anytls не было.
    sniAliases: const ['sni', 'peer'],
    fpAliases: const ['fp', 'fingerprint'],
    defaultFingerprint: 'random',
    reality: true,
    sniHeuristic: true,
    warnings: warnings,
  );
  if (tls != null) body['tls'] = tls;

  return UriMapping(
    body: body,
    label: decodeFragment(p.fragment),
    warnings: warnings,
    extensionFields: tcpKeepAliveMapFromQuery(q),
  );
}
