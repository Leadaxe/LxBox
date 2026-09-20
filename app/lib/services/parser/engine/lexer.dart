/// §480 W1 — ЛЕКСЕР ВХОДА: текст → пространство источников, без `Uri.parse`.
///
/// Норма — SPEC 133 `PRIMITIVES.md` §15.2, §0.6 (FROZEN): «authority разбирает
/// лексер движка, не платформенный парсер URL». Причина не в чистоте: у Dart
/// `Uri.tryParse` отвергает ЦЕЛИКОМ ссылку с multi-port authority
/// (`host:443,20000-30000`, multi-port), а `Uri` вдобавок приводит authority
/// к нижнему регистру — после этого base64-полезная нагрузка, которую часть
/// схем везёт на месте authority, не декодируется вовсе.
///
/// Лексер НЕ декодирует и НЕ судит. Он только режет текст по синтаксису и
/// отдаёт куски сырыми: percent, `+`, base64 и резка userinfo — работа секции
/// (`decode`, `userinfo`, `decode_extra`), потому что правила у них разные у
/// разных полей и обязаны жить в данных.
///
/// Три места, на которых спотыкается платформенный парсер и которые лексер
/// обязан пережить (норма, закреплена тестом `engine_lexer_test.dart`):
///
/// - `host:443,20000-30000` — порт не число; [SourceSpace.portRaw] несёт
///   строку целиком, [SourceSpace.port] остаётся `null`;
/// - `[::1]:443` — IPv6 в скобках; двоеточия внутри скобок портом не
///   являются, скобки в хост не едут;
/// - пробел и прочий сырой мусор в userinfo — `net/url` у лаунчера отбивает
///   такой узел целиком и лечится заплатой `percentEncodeUserinfoSpaces`;
///   здесь чинить нечего, userinfo берётся куском текста.
library;

import 'source_space.dart';

/// Разобрать текст ссылки в пространство источников.
///
/// [text] — ИСХОДНЫЙ текст, как его написал автор. `null` — текст ссылкой не
/// является вовсе (нет `://` и нет `:`-схемы): формы с `space: url` такому
/// входу не отвечают, и решает это вызывающий.
SourceSpace? lexUri(String text, {String formId = 'url'}) {
  final src = text.trim();
  if (src.isEmpty) return null;

  // 1. Схема — до первого `:`. Берётся КАК НАПИСАНА: `hy2` не превращается в
  // канон, регистр не трогается. Перевод написания — работа секции
  // (`aliases`, `scheme_sets`), и лексеру о нём знать нечего.
  final colon = src.indexOf(':');
  if (colon <= 0) return null;
  final scheme = src.substring(0, colon);
  // Схема по RFC 3986: буква, дальше буквы/цифры/`+`/`-`/`.`. Плюс-алиасы
  // со знаком `+` законны именно здесь.
  if (!_kScheme.hasMatch(scheme)) return null;

  var rest = src.substring(colon + 1);
  if (rest.startsWith('//')) rest = rest.substring(2);

  // 2. Фрагмент — от ПЕРВОГО `#` до конца. Режется раньше query, потому что
  // `#` в query законным быть не может, а в метке `?` встречается сплошь.
  var fragment = '';
  final hash = rest.indexOf('#');
  if (hash >= 0) {
    fragment = rest.substring(hash + 1);
    rest = rest.substring(0, hash);
  }

  // 3. Query — от первого `?`.
  var queryRaw = '';
  final qm = rest.indexOf('?');
  if (qm >= 0) {
    queryRaw = rest.substring(qm + 1);
    rest = rest.substring(0, qm);
  }

  // 4. Путь — от первого `/` ПОСЛЕ authority.
  //
  // «После authority» тут не украшение: сырой `/` бывает ВНУТРИ userinfo —
  // base64 его содержит (ключи схем с туннельными ключами, §106), и резать по
  // первому `/` во всей строке значило бы обрубить ключ на первом же `/`.
  // Платформенный парсер ровно поэтому и не годится: у лаунчера то же место
  // обходится percent-энкодом ДО разбора, у нас его нет — лексер режет
  // правильно с первого раза.
  //
  // Граница authority — последний `@`; `/` ищется от него. Если `@` нет,
  // ищем с начала, как и раньше.
  var path = '';
  final atInRest = rest.lastIndexOf('@');
  final slash = rest.indexOf('/', atInRest + 1);
  if (slash >= 0) {
    path = rest.substring(slash);
    rest = rest.substring(0, slash);
  }

  final authority = rest;

  // 5. Userinfo — до ПОСЛЕДНЕГО `@`. Именно последнего: `@` законен внутри
  // пароля (`ss://`-userinfo, пароли с почтой), а в хосте — нет.
  var userinfo = '';
  var hostPort = authority;
  final at = authority.lastIndexOf('@');
  if (at >= 0) {
    userinfo = authority.substring(0, at);
    hostPort = authority.substring(at + 1);
  }

  // 6. Хост и порт. IPv6 в скобках разбирается ПЕРВЫМ: двоеточия внутри
  // скобок портом не являются.
  String host;
  var portRaw = '';
  if (hostPort.startsWith('[')) {
    final close = hostPort.indexOf(']');
    if (close < 0) {
      // Скобка не закрыта — синтаксис битый; хостом считается всё, что есть.
      host = hostPort.substring(1);
    } else {
      host = hostPort.substring(1, close);
      final tail = hostPort.substring(close + 1);
      if (tail.startsWith(':')) portRaw = tail.substring(1);
    }
  } else {
    // Голый IPv6 без скобок (`2001:db8::1`) от `host:port` отличается числом
    // двоеточий: у адреса их два и больше, и порта у него нет.
    final firstColon = hostPort.indexOf(':');
    if (firstColon < 0) {
      host = hostPort;
    } else if (hostPort.indexOf(':', firstColon + 1) >= 0) {
      host = hostPort;
    } else {
      host = hostPort.substring(0, firstColon);
      portRaw = hostPort.substring(firstColon + 1);
    }
  }

  return SourceSpace(
    formId: formId,
    scheme: scheme,
    authority: authority,
    userinfo: userinfo,
    host: host,
    // Порт числом — только когда СТРОКА ЦЕЛИКОМ число: `443,20000-30000` в
    // int не помещается, и молча взять из него `443` значило бы потерять
    // диапазоны. Такие записи читают `port_raw` через `extract`.
    port: int.tryParse(portRaw),
    portRaw: portRaw,
    path: path,
    fragment: fragment,
    query: lexQuery(queryRaw),
  );
}

/// Разобрать сырую строку query в упорядоченный список пар.
///
/// Значения остаются СЫРЫМИ: ни percent, ни `+` здесь не трогаются. Норма
/// §0.6 — percent-декод один раз и поверх него `decode_extra`; кто именно
/// декодирует и с какой семантикой, говорит запись секции. Лексер, снявший
/// percent сам, отнял бы у неё этот выбор.
///
/// Порядок сохраняется: при двух написаниях одного имени (`?sni=a&SNI=b`)
/// норма требует «первое по порядку», и без списка пар ответ был бы
/// недетерминирован (ровно этот дефект вскрыт у лаунчера, §15.5).
QueryPairs lexQuery(String raw) {
  if (raw.isEmpty) return QueryPairs.empty;
  final out = <(String, String)>[];
  for (final part in raw.split('&')) {
    if (part.isEmpty) continue;
    final eq = part.indexOf('=');
    if (eq < 0) {
      // Ключ без `=` — это ключ с пустым значением, а не мусор: `empty:
      // significant` у некоторых полей на этом и стоит.
      out.add((part, ''));
    } else {
      out.add((part.substring(0, eq), part.substring(eq + 1)));
    }
  }
  return QueryPairs(out);
}

final RegExp _kScheme = RegExp(r'^[A-Za-z][A-Za-z0-9+\-.]*$');
