/// §480 W1 — ПРОСТРАНСТВО ИСТОЧНИКОВ: единственное, через что запись секции
/// получает значение.
///
/// Норма — SPEC 133 лаунчера, `PRIMITIVES.md` §1.1 и `SCHEMES.md` §0.1. Смысл
/// устройства в том, что у движка НЕТ доступа ни к чему, что запись не
/// объявила именем источника: «читаем мимо реестра» становится невозможным
/// конструктивно, а не по договорённости.
///
/// Имена источников (адресуются строкой в `source`):
///
/// ```
/// scheme        host            query.<name>      json.<path>
/// userinfo      port            fragment          ini.<Section>.<Key>
/// userinfo.user port_raw        path              ini.$comment.<Section>
/// userinfo.pass authority
/// ```
///
/// `json.*` и `ini.*` заведены СРАЗУ, хотя W1 исполняет только вид источника
/// `uri`: секции-мапперы по видам источника (`mappers.<kind>`, P14) — это
/// решение владельца, и пространство обязано их принимать без правки движка
/// (волны W5 — INI, Xray-JSON, sing-box-JSON).
library;

/// Упорядоченная пара «имя параметра → значение» с регистронезависимым
/// доступом.
///
/// Порядок — не косметика. Норма (`PRIMITIVES.md` §15.5): при ДВУХ написаниях
/// одного имени в одной ссылке (`?sni=a&SNI=b`) побеждает точное совпадение с
/// каноном, а при его отсутствии — ПЕРВОЕ по порядку появления. У лаунчера
/// сегодня здесь дефект: `queryGetFold` обходит Go-map, и победитель
/// недетерминирован между запусками. Список пар — то, чем этот дефект
/// исключается у нас.
final class QueryPairs {
  QueryPairs(this.pairs);

  /// Пары в порядке появления в ссылке. Имя — КАК НАПИСАНО.
  final List<(String, String)> pairs;

  static final QueryPairs empty = QueryPairs(const []);

  /// Значение по имени: точное совпадение в приоритете, иначе первое
  /// совпадение без учёта регистра.
  ///
  /// Дубли одного написания (`?fp=a&fp=b`) — берётся первый: сегодняшнее
  /// поведение обеих сторон, зафиксировано нормой явно.
  String? get(String name) {
    for (final p in pairs) {
      if (p.$1 == name) return p.$2;
    }
    final lower = name.toLowerCase();
    for (final p in pairs) {
      if (p.$1.toLowerCase() == lower) return p.$2;
    }
    return null;
  }

  /// Есть ли имя (в любом регистре). Отличается от `get() != null` только
  /// читаемостью места вызова: пустое значение — это «ключ есть».
  bool has(String name) => get(name) != null;

  /// Имена как написаны, в порядке появления.
  Iterable<String> get names => pairs.map((p) => p.$1);
}

/// Результат работы лексера: плоское пространство имён одной записи.
///
/// Форма (P1) решает, чем пространство заполнено: `space: url` даёт
/// scheme/authority/query/fragment, `space: json` — [json], `space: ini` —
/// [ini]. Поля не взаимоисключающие: у формы с `reparse` заполнены оба.
final class SourceSpace {
  const SourceSpace({
    this.formId = '',
    this.scheme = '',
    this.authority = '',
    this.userinfo = '',
    this.userinfoUser,
    this.userinfoPass,
    this.host = '',
    this.port,
    this.portRaw = '',
    this.path = '',
    this.fragment = '',
    QueryPairs? query,
    this.json,
    this.jsonBase,
    this.ini,
  }) : _query = query;

  final QueryPairs? _query;

  /// `id` формы, которая построила пространство (для `when.$form` и карты
  /// `source` по формам).
  final String formId;

  /// Схема КАК НАПИСАНА в ссылке: алиас не разворачивается в канон, регистр
  /// не трогается.
  final String scheme;

  /// Сырая authority до разбора — `user@host:443,20000-30000` целиком.
  final String authority;

  /// Userinfo СЫРОЙ: без percent-декода и без резки по `:`. И то, и другое —
  /// работа секции (`uri.userinfo`, P2), а не лексера.
  final String userinfo;

  /// Части userinfo после резки секцией; `null` — секция не резала.
  final String? userinfoUser;
  final String? userinfoPass;

  /// Хост без скобок IPv6: `[::1]` даёт `::1`. Скобки — синтаксис authority,
  /// а не часть адреса, и в тело они не едут ни у одной схемы.
  final String host;

  /// Порт числом; `null` — порта нет или он не число (multi-port authority).
  final int? port;

  /// СЫРАЯ строка порта: `443,20000-30000` целиком. Из неё читается
  /// multi-port, который в [port] не помещается.
  final String portRaw;

  /// Путь ссылки (после authority, до `?`), сырой.
  final String path;

  /// Фрагмент сырой (percent не снят): `+` во фрагменте литерален, и
  /// декодирует его метка (`label.source`), а не лексер.
  final String fragment;

  /// Query упорядоченным списком пар, значения СЫРЫЕ.
  QueryPairs get query => _query ?? QueryPairs.empty;

  /// Пространство `json` (формы `space: json`): Xray/sing-box/v2rayN.
  final Map<String, dynamic>? json;

  /// Якорь пути формы: значение `base` подставляется в `source` вместо
  /// `$base`. Одна таблица обслуживает разные раскладки одного диалекта
  /// (`settings.vnext.0`, `settings.servers.0`, плоская форма) — без якоря
  /// пришлось бы держать три копии записей (§4 НОРМЫ).
  final String? jsonBase;

  /// Пространство `ini` (формы `space: ini`): `Section.Key` в нижнем
  /// регистре, плюс `$comment.<Section>`.
  final Map<String, String>? ini;

  SourceSpace copyWith({
    String? formId,
    String? userinfoUser,
    String? userinfoPass,
  }) =>
      SourceSpace(
        formId: formId ?? this.formId,
        scheme: scheme,
        authority: authority,
        userinfo: userinfo,
        userinfoUser: userinfoUser ?? this.userinfoUser,
        userinfoPass: userinfoPass ?? this.userinfoPass,
        host: host,
        port: port,
        portRaw: portRaw,
        path: path,
        fragment: fragment,
        query: _query,
        json: json,
        jsonBase: jsonBase,
        ini: ini,
      );
}
