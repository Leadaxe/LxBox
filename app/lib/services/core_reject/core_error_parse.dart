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
library;

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

  /// Индекс в массиве. Диагностический: по нему НЕ сопоставляют.
  final int index;

  /// Тип sing-box (`vless`, `wireguard`, …).
  final String type;

  /// Финальный тег записи в собранном конфиге.
  final String tag;

  /// Дословный текст ядра, без префикса с тегом. Он же `params.reason`
  /// записи `core_rejected` (PARSING_PRINCIPLES §9.4).
  final String reason;

  @override
  String toString() => 'CoreRejection($kind[$index] $type[$tag]: $reason)';
}

const _prefix = 'initialize ';
const _sep = ']: ';

/// PARSING_PRINCIPLES §9.2. [line] — строка ошибки ядра, [configTags] — теги СОБРАННОГО
/// конфига (именно финальные, после префикса подписки и дедупа).
///
/// `null` — узел не назван: префикс не совпал (ошибка не про узел), формы
/// «без тега», либо ни один кандидат не сопоставился с тегами конфига.
/// Перебором виновника не ищем (PARSING_PRINCIPLES §9.3).
///
/// Строка приходит обёрнутой (Д-1): слева — цепочка префиксов Go и
/// локализованный шаблон Kotlin. Поэтому `initialize ` ищется по ВСЕМ
/// вхождениям слева направо, и первое, за которым грамматика §9 сходится
/// целиком (включая сопоставление тега), побеждает. Слева направо — потому
/// что настоящая запись ядра ровно одна и стоит после всех обёрток, а
/// `initialize ` внутри ТЕГА обёрткой быть не может: тег читается уже
/// внутри разбора, за своим `[`.
CoreRejection? parseCoreRejection(String line, Set<String> configTags) {
  final raw = line.trim();
  var at = raw.indexOf(_prefix);
  while (at >= 0) {
    final hit = _parseAt(raw.substring(at + _prefix.length), configTags);
    if (hit != null) return hit;
    at = raw.indexOf(_prefix, at + 1);
  }
  return null;
}

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
