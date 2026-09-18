/// §472 шаг 6 — маппер socks. §475 — версию протокола несёт СХЕМА.
///
/// Собственных query-параметров у схемы нет вовсе
/// (`registry/protocols/socks.json` → `uri.query` пуст), и переводить тут
/// почти нечего — userinfo, порт, имя из фрагмента и версия из схемы.
///
/// - **Версию несёт схема** (`socks_scheme_is_version`, `kind: structure`):
///   своего параметра под версию у socks-ссылки нет ни в одном диалекте,
///   поэтому дискриминатором работает схема — ровно как суффикс
///   `proxy-https://` работает TLS-дискриминатором у http. Таблица одна на
///   маппер и эмиттер ([kSocksVersionByScheme], `uri_utils.dart`): две копии
///   разъехались бы на первой же правке, и узел перестал бы переживать круг
///   своей же ссылки;
/// - **`version: "5"` пишется в тело ЯВНО.** Ядру хватило бы отсутствия ключа
///   (пусто = 5), но значение уже стоит в ожиданиях корпуса и в телах всех
///   живых socks-узлов ОБЕИХ сторон — снятие переписало бы их все ради нуля
///   разницы для ядра. Identity при этом не двигается: до §475 ключ в тело
///   клал `emitSocks` из модели (дефолт `'5'`), теперь его кладёт маппер, а
///   эмиттер пишет то же самое;
/// - **userinfo `user` | `user:pass` | `:pass`** — оба компонента
///   опциональны, порт по умолчанию 1080. У версии 4 пароля нет вовсе
///   (userinfo это userid, ядро шлёт `username` как userid), но написанный в
///   ссылке пароль переносится КАК ЕСТЬ: маппер значения не судит;
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

  // §475 — версия из схемы. `p.scheme` уже в нижнем регистре (`Uri` его
  // канонизирует), схемы вне таблицы сюда не приходят: маршрутизация идёт по
  // тому же набору (`kPipelineSchemes`).
  final version = kSocksVersionByScheme[p.scheme] ?? '5';

  final body = <String, dynamic>{
    'type': 'socks',
    'server': server,
    'server_port': port,
    'version': version,
    if (username.isNotEmpty) 'username': username,
    if (password.isNotEmpty) 'password': password,
  };

  return UriMapping(
    body: body,
    label: decodeFragment(p.fragment),
    extensionFields: tcpKeepAliveMapFromQuery(q),
  );
}
