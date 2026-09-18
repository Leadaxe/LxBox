/// §472 шаг 2 — маппер trojan: пилот конвейера «ссылка → карта → санитайзер».
///
/// Схема выбрана пилотом за состав: мало собственных полей (пароль), но есть
/// и транспорт, и TLS — то есть обе общие части, которые шагом 3 возьмёт
/// vless.
///
/// Словарь ссылки — `registry/protocols/trojan.json` → `uri`. Отличия от
/// vless, которые здесь выражены аргументами общих частей:
///
/// - дефолт TLS — ВКЛЮЧЁН (plaintext-портовой эвристики vless у trojan нет);
/// - `fp` читается только под своим именем (алиас `fingerprint` — vless);
/// - дефолта отпечатка нет (у vless `random`), пустой `fp` блока не даёт;
/// - REALITY из trojan-URI не разбирается ни одним проектом: `pbk` не читается.
library;

import '../../../models/node_warning.dart';
import '../uri_utils.dart';
import 'common_parts.dart';
import 'uri_mapper.dart';

/// Порт по умолчанию (`protocols/trojan.json` → `uri.userinfo.impl`).
const _kDefaultPort = 443;

/// `trojan://password@host:port?…#label` → сырая карта sing-box.
///
/// `null` — ссылки нет: без хоста или без пароля запись не построить
/// (`password` у схемы `required`, узел ушёл бы целиком).
UriMapping? mapTrojanUri(String uri) {
  // §472 шаг 4 — `Uri.tryParse` зовёт сам маппер: у vmess и shadowsocks
  // ссылка URI не является (см. [UriMapper]), и общего разбора у конвейера
  // больше нет.
  final p = Uri.tryParse(uri);
  if (p == null || p.host.isEmpty) return null;

  // РАСХОЖДЕНИЕ с Go зафиксировано реестром (`uri.userinfo.impl`): при `:` в
  // userinfo Go берёт паролем часть ДО `:`, Dart — весь userinfo. Поведение
  // сохранено как было: identity узлов с `:` в пароле от шага 2 не двигается.
  final password = Uri.decodeComponent(p.userInfo.split(':').join(':'));
  if (password.isEmpty) return null;

  final server = p.host;
  final port = p.hasPort ? p.port : _kDefaultPort;
  final q = Map<String, String>.from(p.queryParameters);
  final warnings = <NodeWarning>[];

  final body = <String, dynamic>{
    'type': 'trojan',
    'server': server,
    'server_port': port,
    'password': password,
  };

  final transport = transportMapFromQuery(q, warnings: warnings);
  if (transport.map != null) body['transport'] = transport.map;

  final tls = tlsMapFromQuery(q, server, port, warnings: warnings);
  if (tls != null) body['tls'] = tls;

  return UriMapping(
    body: body,
    label: decodeFragment(p.fragment),
    warnings: warnings,
    // §472 шаг 3 — dial-поля §453 уехали из `body` в [extensionFields]: там
    // они лежат до санитайзера, а не после. Реестр их не описывает (лаунчер
    // не пишет, `dialer.json` → `skipped`), и в теле санитайзер снимал их как
    // `unknown_key` — узел терял настройку человека МОЛЧА, а шаг 2 этого не
    // заметил: `tcp_keep_alive_test.dart` реестра не грузит, и санитайзер там
    // не работал вовсе.
    extensionFields: tcpKeepAliveMapFromQuery(q),
    wsEarlyDataHeaderImplicit: transport.wsEarlyDataHeaderImplicit,
  );
}
