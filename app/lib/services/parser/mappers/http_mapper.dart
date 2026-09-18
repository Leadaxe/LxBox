/// §472 шаг 6 — маппер http(s) CONNECT-прокси (§222).
///
/// Словарь ссылки — `registry/protocols/http.json` → `uri`. Схема кастомная
/// (`proxy-http://`, `proxy-https://` и плюс-формы §268): голые `http(s)://`
/// перехватывает `isSubscriptionUrl` раньше `isDirectLink`, и промо-ссылки в
/// телах подписок стали бы «узлами».
///
/// Что маппер переводит (и не судит):
///
/// - **суффикс схемы — TLS-дискриминатор.** `*-https`/`*+https` → блок TLS
///   есть (порт по умолчанию 443), `*-http`/`*+http` → блока нет вовсе
///   (порт 80). Это вопрос СТРУКТУРЫ, и отвечает на него маппер: явный
///   `tls:{enabled:false}` ронял ядра lx.5–lx.18 (SPEC 045), а санитайзеру
///   отсутствие ключа неотличимо от «не задано»;
/// - **`security=none` гасит TLS даже на https-схеме** — правило
///   `security_none_no_tls` (`applies_to` включает http), общая часть его и
///   исполняет;
/// - **userinfo `user` | `user:pass` | `:pass`** — оба компонента
///   опциональны (`uri.userinfo.impl`);
/// - **`headers`** — та же сериализация, что `extra-headers` у naive:
///   `H1: V1\r\nH2: V2` в карту тела.
///
/// TLS-часть читается по конвенции trojan: алиасы `sni`/`peer`/`host`, `fp`
/// без алиаса `fingerprint`, дефолта отпечатка нет, REALITY у схемы нет.
/// Ровно те же аргументы общих частей, что у trojan, — и это не совпадение:
/// прежний парсер звал `parseTrojanTls` буквально.
library;

import '../../../models/node_warning.dart';
import '../uri_parsers/naive_parser.dart' show parseNaiveExtraHeaders;
import '../uri_utils.dart';
import 'common_parts.dart';
import 'uri_mapper.dart';

/// `proxy-https://user:pass@host:port?…#label` → сырая карта sing-box.
///
/// `null` — ссылки нет: без хоста запись не построить.
UriMapping? mapHttpProxyUri(String uri) {
  final p = Uri.tryParse(uri);
  if (p == null || p.host.isEmpty) return null;

  // TLS-дискриминатор — суффикс `https` (покрывает и дефис-, и плюс-форму).
  final secure = p.scheme.toLowerCase().endsWith('https');

  // userinfo: `user` | `user:pass` | `:pass`. Пароль — всё после ПЕРВОГО
  // двоеточия, чтобы двоеточие внутри пароля не потерялось.
  final userParts = p.userInfo.split(':');
  final username = userParts.isEmpty || userParts.first.isEmpty
      ? ''
      : Uri.decodeComponent(userParts.first);
  final password = userParts.length > 1
      ? Uri.decodeComponent(userParts.sublist(1).join(':'))
      : '';

  final server = p.host;
  final port = p.hasPort ? p.port : (secure ? 443 : 80);
  final q = Map<String, String>.from(p.queryParameters);
  final warnings = <NodeWarning>[];

  final body = <String, dynamic>{
    'type': 'http',
    'server': server,
    'server_port': port,
    if (username.isNotEmpty) 'username': username,
    if (password.isNotEmpty) 'password': password,
  };

  final path = q['path'] ?? '';
  if (path.isNotEmpty) body['path'] = path;

  // Та же сериализация, что `extra-headers` у naive; ключи сортируются — так
  // эмитят оба проекта, и порядок ключей входит в тело, то есть в identity.
  //
  // `warnings: null` — молчаливый режим: код `naive_extra_headers_invalid`
  // объявлен у naive, и у http-прокси под код контракта эти заголовки не
  // попадают. Так было и на прежнем пути.
  final headers = parseNaiveExtraHeaders(q['headers'] ?? '');
  if (headers.isNotEmpty) {
    final keys = headers.keys.toList()..sort();
    body['headers'] = <String, dynamic>{
      for (final k in keys) k: headers[k]!,
    };
  }

  // Блок TLS — только у https-схемы; `security=none` гасит его и там.
  if (secure) {
    final tls = tlsMapFromQuery(q, server, port, warnings: warnings);
    if (tls != null) body['tls'] = tls;
  }

  return UriMapping(
    body: body,
    label: decodeFragment(p.fragment),
    warnings: warnings,
    extensionFields: tcpKeepAliveMapFromQuery(q),
  );
}
