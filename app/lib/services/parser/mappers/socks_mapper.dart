/// §472 шаг 6 — маппер socks.
///
/// Самая короткая схема набора: собственных query-параметров у неё нет вовсе
/// (`registry/protocols/socks.json` → `uri.query` пуст), и переводить тут
/// почти нечего — userinfo, порт и имя из фрагмента.
///
/// - **`socks://` и `socks5://` эквивалентны** (`aliases: ["socks5"]`), обе
///   дают тело `type: socks`. Версию маппер не пишет: поле `version` у ядра
///   имеет дефолт `5`, а эмиттер (`emitSocks`) ставит его из модели сам.
///   Клади маппер `version` в тело — оно поехало бы в тело и из ссылки, чего
///   прежний путь не делал, и тела живых узлов сдвинулись бы;
/// - **userinfo `user` | `user:pass` | `:pass`** — оба компонента
///   опциональны, порт по умолчанию 1080;
/// - **§453 — query читается только ради dial-полей.** Прочих параметров у
///   схемы нет; до §453 socks-URI не читал query вовсе.
library;

import '../uri_utils.dart';
import 'common_parts.dart';
import 'uri_mapper.dart';

/// Порт по умолчанию (`uri.userinfo.impl`).
const _kDefaultPort = 1080;

/// `socks5://user:pass@host:port?…#label` → сырая карта sing-box.
///
/// `null` — ссылки нет: без хоста запись не построить.
UriMapping? mapSocksUri(String uri) {
  final p = Uri.tryParse(uri);
  if (p == null || p.host.isEmpty) return null;

  final userParts = p.userInfo.split(':');
  final username = userParts.isEmpty || userParts.first.isEmpty
      ? ''
      : Uri.decodeComponent(userParts.first);
  final password = userParts.length > 1
      ? Uri.decodeComponent(userParts.sublist(1).join(':'))
      : '';

  final server = p.host;
  final port = p.hasPort ? p.port : _kDefaultPort;
  final q = Map<String, String>.from(p.queryParameters);

  final body = <String, dynamic>{
    'type': 'socks',
    'server': server,
    'server_port': port,
    if (username.isNotEmpty) 'username': username,
    if (password.isNotEmpty) 'password': password,
  };

  return UriMapping(
    body: body,
    label: decodeFragment(p.fragment),
    extensionFields: tcpKeepAliveMapFromQuery(q),
  );
}
