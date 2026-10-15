/// Фича 478 / PARSING_PRINCIPLES §9.1–§9.2 — разбор строки отказа ядра.
///
/// Ядро `sing-box-lx` ≥ `1.14.1-lx.7` (SPEC 092) при отказе инициализации
/// пишет
///
/// ```
/// initialize <outbound|endpoint>[<i>] <type>[<tag>]: <text>
/// ```
///
/// Индекс `<i>` диагностический — он нумерует ПОЗИЦИЮ в собранном конфиге,
/// а не узел состояния; сопоставлять по нему запрещено (PARSING_PRINCIPLES §9.1).
///
/// Тег и текст разделяет `]: `, и обе стороны вправе эту последовательность
/// содержать — однозначного разреза по строке НЕ существует. Правило §9.2:
/// слева снимается фиксированный префикс, в остатке берутся ВСЕ вхождения
/// `]: ` СПРАВА НАЛЕВО, каждое даёт кандидата, побеждает первый, чей тег
/// есть среди тегов собранного конфига. Ни один не совпал — узел не назван,
/// автоматики нет.
///
/// Ядра старше lx.7 пишут ту же строку БЕЗ ` <type>[<tag>]`
/// (`initialize outbound[26]: unknown uTLS fingerprint`) — форма «без тега»,
/// её разбор обязан распознать и вернуть `null`.
///
/// ## Обёртки (Д-1)
///
/// До Dart строка доходит не голой. Go оборачивает её своей цепочкой
/// (`start or reload service: initialize outbound[33] …`), а Kotlin сверху
/// кладёт ЛОКАЛИЗОВАННЫЙ шаблон `stop_alert_start_failed` — в ru префикс
/// другой. Поэтому грамматика §9 ищется не с начала строки, а по вхождению
/// `initialize ` где угодно после любых префиксов: разбор не знает ни одного
/// текста обёртки и не ломается от перевода. Сырой `t.message` при этом всё
/// равно приходит отдельным полем (`core_error` события статуса) — префиксы
/// Kotlin он не несёт вовсе.
///
/// ## Вторая форма: отказ на декодировании (§653)
///
/// Ключ, которого ядро не знает (`network` у старых masque-тел на lx.18),
/// ловится раньше инициализации — на декодировании JSON. Структуры узла ещё
/// нет, тега в строке нет, есть только путь (форма `contextjson` из
/// `sing/common/json`, обёртка libbox `decode config: `):
///
/// ```
/// <outbounds|endpoints>[<i>](.<path>)?: <text>
/// ```
///
/// Здесь индекс — единственная координата узла и НЕСЁТ нагрузку: массив,
/// который декодировало ядро, — ровно тот, что приложение записало на диск,
/// поэтому `<i>` разрешается в тег по отправленному конфигу
/// ([CoreConfigTags.outbounds] / [CoreConfigTags.endpoints]). Это не перебор
/// (§9.3 запрещает перебор и догадку): сопоставление однозначно. Индекс вне
/// массива или пустой тег по индексу — узел не назван.
///
/// Вхождения `outbounds[` / `endpoints[` ищутся по всей строке слева
/// направо (обёртки Go и Kotlin те же, что у первой формы); побеждает первое,
/// за которым грамматика сходится и индекс попадает в массив. Вхождение
/// внутри чужого пути (`….outbounds[`, перед ним буква, цифра, `_` или `.`)
/// не считается. Форма `initialize` проверяется первой: строка, где
/// `outbounds[` стоит внутри тега первой формы, разбирается первой формой.
///
/// `reason` (§9.4) — `<path>: <text>` без префикса `outbounds[i].`, без пути —
/// просто `<text>`: `network: json: unknown field "network"`.
library;

import 'dart:convert';

/// Результат разбора: ошибка назвала узел и тег сопоставился с конфигом.
final class CoreRejection {
  const CoreRejection({
    required this.kind,
    required this.index,
    required this.type,
    required this.tag,
    required this.reason,
  });

  /// Вид записи конфига — `outbound` либо `endpoint` (PARSING_PRINCIPLES §9.1).
  final String kind;

  /// Индекс в массиве. В форме `initialize` диагностический: по нему НЕ
  /// сопоставляют. В форме декодирования (§653) — по нему найден тег.
  final int index;

  /// Тип sing-box (`vless`, `wireguard`, …).
  final String type;

  /// Финальный тег записи в собранном конфиге.
  final String tag;

  /// Дословный текст ядра, без префикса с тегом. Он же `params.reason`
  /// записи `core_rejected` (PARSING_PRINCIPLES §9.4). В форме декодирования —
  /// `<path>: <text>` без `outbounds[i].`.
  final String reason;

  @override
  String toString() => 'CoreRejection($kind[$index] $type[$tag]: $reason)';
}

/// Запись массива отправленного конфига: финальный тег и тип sing-box.
/// Запись без строкового `tag`/`type` — пустая строка (индексы не сдвигаются).
final class CoreConfigEntry {
  const CoreConfigEntry(this.tag, this.type);

  final String tag;
  final String type;
}

/// Теги отправленного конфига для разбора строки отказа.
///
/// [all] — финальные теги (обратная карта сборки, PARSING_PRINCIPLES §9.3):
/// против них проверяются кандидаты формы `initialize`. [outbounds] и
/// [endpoints] — записи в ПОРЯДКЕ массивов отправленного конфига: по ним
/// индекс формы декодирования (§653) разрешается в тег и тип.
final class CoreConfigTags {
  const CoreConfigTags({
    required this.all,
    this.outbounds = const [],
    this.endpoints = const [],
  });

  /// Записи `outbounds[]`/`endpoints[]` из текста конфига — один проход
  /// `jsonDecode`. Конфиг не разобрался — массивы пустые, форма
  /// декодирования узла не назовёт.
  factory CoreConfigTags.fromConfigJson(
    String configJson, {
    required Set<String> all,
  }) {
    Object? root;
    try {
      root = jsonDecode(configJson);
    } on FormatException {
      root = null;
    }
    List<CoreConfigEntry> entries(String key) {
      final arr = root is Map ? root[key] : null;
      if (arr is! List) return const [];
      return [
        for (final e in arr)
          CoreConfigEntry(
            e is Map && e['tag'] is String ? e['tag'] as String : '',
            e is Map && e['type'] is String ? e['type'] as String : '',
          ),
      ];
    }

    return CoreConfigTags(
      all: all,
      outbounds: entries('outbounds'),
      endpoints: entries('endpoints'),
    );
  }

  final Set<String> all;
  final List<CoreConfigEntry> outbounds;
  final List<CoreConfigEntry> endpoints;
}

const _prefix = 'initialize ';
const _sep = ']: ';

/// PARSING_PRINCIPLES §9.2. [line] — строка ошибки ядра, [config] — теги СОБРАННОГО
/// конфига (именно финальные, после префикса подписки и дедупа).
///
/// Сначала форма `initialize`; не сошлась — форма декодирования (§653).
///
/// `null` — узел не назван: префикс не совпал (ошибка не про узел), формы
/// «без тега», ни один кандидат не сопоставился с тегами конфига, либо
/// индекс формы декодирования вне массива.
/// Перебором виновника не ищем (PARSING_PRINCIPLES §9.3).
///
/// Строка приходит обёрнутой (Д-1): слева — цепочка префиксов Go и
/// локализованный шаблон Kotlin. Поэтому `initialize ` ищется по ВСЕМ
/// вхождениям слева направо, и первое, за которым грамматика §9 сходится
/// целиком (включая сопоставление тега), побеждает. Слева направо — потому
/// что настоящая запись ядра ровно одна и стоит после всех обёрток, а
/// `initialize ` внутри ТЕГА обёрткой быть не может: тег читается уже
/// внутри разбора, за своим `[`.
CoreRejection? parseCoreRejection(String line, CoreConfigTags config) {
  final raw = line.trim();
  var at = raw.indexOf(_prefix);
  while (at >= 0) {
    final hit = _parseAt(raw.substring(at + _prefix.length), config.all);
    if (hit != null) return hit;
    at = raw.indexOf(_prefix, at + 1);
  }
  return _parseDecode(raw, config);
}

const _decodeKinds = {'outbounds[': 'outbound', 'endpoints[': 'endpoint'};

/// Форма декодирования (§653): первое слева вхождение `outbounds[` /
/// `endpoints[`, за которым грамматика сходится и индекс попадает в массив.
CoreRejection? _parseDecode(String raw, CoreConfigTags config) {
  for (var at = 0; at < raw.length; at++) {
    for (final MapEntry(key: head, value: kind) in _decodeKinds.entries) {
      if (!raw.startsWith(head, at)) continue;
      if (at > 0 && _isPathChar(raw.codeUnitAt(at - 1))) continue;
      final hit = _parseDecodeAt(
        raw.substring(at + head.length),
        kind,
        kind == 'outbound' ? config.outbounds : config.endpoints,
      );
      if (hit != null) return hit;
    }
  }
  return null;
}

/// Остаток ПОСЛЕ `outbounds[`: `<i>](.<path>)?: <text>`.
CoreRejection? _parseDecodeAt(
  String rest,
  String kind,
  List<CoreConfigEntry> entries,
) {
  final close = rest.indexOf(']');
  if (close <= 0) return null;
  final digits = rest.substring(0, close);
  // Только десятичные цифры, без ведущих нулей: Go пишет индекс через
  // strconv, `012` ядро не напишет — такая строка не наша.
  if (!_isDigits(digits) || (digits.length > 1 && digits[0] == '0')) {
    return null;
  }
  final index = int.tryParse(digits);
  if (index == null || index >= entries.length) return null;

  final tail = rest.substring(close + 1);
  final String reason;
  if (tail.startsWith('.')) {
    // `<path>: <text>` — путь до первого `: `, сам путь его не содержит.
    reason = tail.substring(1);
    final sep = reason.indexOf(': ');
    if (sep <= 0) return null;
  } else if (tail.startsWith(': ')) {
    reason = tail.substring(2);
  } else {
    return null;
  }

  final entry = entries[index];
  if (entry.tag.isEmpty) return null;
  return CoreRejection(
    kind: kind,
    index: index,
    type: entry.type,
    tag: entry.tag,
    reason: reason,
  );
}

bool _isPathChar(int c) =>
    c == 0x2E || // .
    c == 0x5F || // _
    (c >= 0x30 && c <= 0x39) ||
    (c >= 0x41 && c <= 0x5A) ||
    (c >= 0x61 && c <= 0x7A);

/// Грамматика §9.1–§9.2 на остатке ПОСЛЕ префикса `initialize `.
CoreRejection? _parseAt(String after, Set<String> configTags) {
  var rest = after;

  // <outbound|endpoint>
  final String kind;
  if (rest.startsWith('outbound[')) {
    kind = 'outbound';
  } else if (rest.startsWith('endpoint[')) {
    kind = 'endpoint';
  } else {
    // inbound, dns, route и прочее — ошибка не про узел.
    return null;
  }
  rest = rest.substring(kind.length + 1); // снят вид и '['

  // <i>] — только десятичные цифры.
  final close = rest.indexOf(']');
  if (close <= 0) return null;
  final digits = rest.substring(0, close);
  final index = int.tryParse(digits);
  if (index == null || !_isDigits(digits)) return null;
  rest = rest.substring(close + 1);

  // Форма без тега (ядро < lx.7): сразу `: <text>`. Узел не назван.
  if (!rest.startsWith(' ')) return null;
  rest = rest.substring(1);

  // <type>[ — имя типа до первой '['. Тип не содержит скобок.
  final open = rest.indexOf('[');
  if (open <= 0) return null;
  final type = rest.substring(0, open);
  if (type.contains(']') || type.contains(' ')) return null;
  rest = rest.substring(open + 1);

  // Все вхождения `]: ` СПРАВА НАЛЕВО: тег максимально длинный, `]: `
  // внутри ТЕКСТА отрезается раньше, чем `]: ` внутри ТЕГА.
  var cut = rest.lastIndexOf(_sep);
  while (cut >= 0) {
    final tag = rest.substring(0, cut);
    if (configTags.contains(tag)) {
      return CoreRejection(
        kind: kind,
        index: index,
        type: type,
        tag: tag,
        reason: rest.substring(cut + _sep.length),
      );
    }
    cut = cut == 0 ? -1 : rest.lastIndexOf(_sep, cut - 1);
  }
  return null;
}

bool _isDigits(String s) {
  if (s.isEmpty) return false;
  for (final c in s.codeUnits) {
    if (c < 0x30 || c > 0x39) return false;
  }
  return true;
}
