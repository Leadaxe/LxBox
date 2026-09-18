/// §472 шаг 6 — маппер ssh.
///
/// Словарь ссылки — `registry/protocols/ssh.json` → `uri`. Схема без TLS и
/// без транспорта: весь перевод это userinfo, списки через запятую и ключи.
///
/// Что маппер переводит (и не судит):
///
/// - **userinfo `user` | `user:password`**, причём `user` обязателен: без
///   него запись не строится. Go на пустом userinfo валит узел (валидация
///   hostname+userinfo), Dart отвечает `null` — поведение сохранено;
/// - **§466 — `private_key` едет в QUERY ссылки.** Это ФОРМА ХРАНЕНИЯ узла
///   (хранение узла — его текст), и менять её этот шаг не уполномочен.
///   Многострочный PEM приходит percent-кодированным, и `Uri.queryParameters`
///   раскодирует его ровно один раз — этого достаточно: `+` в base64 внутри
///   значения при этом не портится, потому что декодируется значение
///   параметра, а не `application/x-www-form-urlencoded`-форма. Раскрутки до
///   стабильной точки здесь НЕТ и не было: она сломала бы ключ, в котором
///   законно встречается `%`;
/// - **`host_key` и `host_key_algorithms` — списки через запятую.** Пустые
///   элементы отбрасываются (`uri.query.host_key.impl`): это форма записи, а
///   не суждение о значении.
///
/// Судить в схеме нечего: все поля тела у ssh это `string` или
/// `listable_string` без enum'ов и форматов, и рукописных правил значения у
/// прежнего парсера не было ни одного.
library;

import '../uri_utils.dart';
import 'common_parts.dart';
import 'uri_mapper.dart';

/// Порт по умолчанию — канонический ssh.
const _kDefaultPort = 22;

/// `ssh://user:password@host:port?…#label` → сырая карта sing-box.
///
/// `null` — ссылки нет: без хоста или без имени пользователя запись не
/// построить.
UriMapping? mapSshUri(String uri) {
  final p = Uri.tryParse(uri);
  if (p == null || p.host.isEmpty || p.userInfo.isEmpty) return null;

  final userParts = p.userInfo.split(':');
  final user = Uri.decodeComponent(userParts.first);
  // Пароль — всё после ПЕРВОГО двоеточия: внутри него двоеточие законно.
  final password = userParts.length > 1
      ? Uri.decodeComponent(userParts.sublist(1).join(':'))
      : '';
  if (user.isEmpty) return null;

  final server = p.host;
  final port = p.hasPort ? p.port : _kDefaultPort;
  final q = Map<String, String>.from(p.queryParameters);

  final body = <String, dynamic>{
    'type': 'ssh',
    'server': server,
    'server_port': port,
    'user': user,
    if (password.isNotEmpty) 'password': password,
  };

  final privateKey = q['private_key'] ?? '';
  if (privateKey.isNotEmpty) body['private_key'] = privateKey;
  final passphrase = q['private_key_passphrase'] ?? '';
  if (passphrase.isNotEmpty) body['private_key_passphrase'] = passphrase;

  final hostKey = _commaList(q['host_key']);
  if (hostKey.isNotEmpty) body['host_key'] = hostKey;
  final algorithms = _commaList(q['host_key_algorithms']);
  if (algorithms.isNotEmpty) body['host_key_algorithms'] = algorithms;

  return UriMapping(
    body: body,
    label: decodeFragment(p.fragment),
    extensionFields: tcpKeepAliveMapFromQuery(q),
  );
}

/// Список через запятую → список тела; пустые элементы отбрасываются.
///
/// Форма записи (`uri.query.host_key.impl`), а не суждение: у ядра это
/// `listable_string`, и годность элементов реестр не проверяет.
List<String> _commaList(String? raw) {
  final s = (raw ?? '').trim();
  if (s.isEmpty) return const <String>[];
  return [
    for (final e in s.split(','))
      if (e.trim().isNotEmpty) e.trim(),
  ];
}
