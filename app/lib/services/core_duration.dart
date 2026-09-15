/// §442 — разбор длительности по правилам ЯДРА sing-box.
///
/// Порт `sing/common/json/badoption/internal/my_time.ParseDuration`: этим
/// парсером ядро читает каждое поле `badoption.Duration` конфига (`interval`,
/// `idle_timeout`, …). От `time.ParseDuration` stdlib он отличается ровно
/// суффиксом `d` (24h): `1d` для ядра валиден, и принять его за мусор значило
/// бы не распознать рабочее значение из подписки.
///
/// Грамматика ядра: `[-+]?([0-9]*(\.[0-9]*)?[a-z]+)+`, единицы `ns`, `us`
/// (`µs`/`μs`), `ms`, `s`, `m`, `h`, `d`; голое `0` — ноль; пустая строка,
/// число без единицы, неизвестная единица и переполнение — ошибка. Пробелы
/// ядро НЕ срезает, и здесь их не срезает: ` 1h` для ядра невалиден.
///
/// Возвращает НАНОСЕКУНДЫ (разрешение ядра; `Duration` Dart хранит
/// микросекунды и на `ns` терял бы точность) или `null`, если ядро строку
/// отвергло бы. Единственное расхождение с Go — значение ровно `-2^63ns`:
/// у Go счётчик беззнаковый, у Dart int знаковый; на практике недостижимо.
int? parseCoreDurationNanos(String s) {
  const maxNs = 0x7FFFFFFFFFFFFFFF;
  var rest = s;
  var neg = false;
  if (rest.isNotEmpty && (rest[0] == '-' || rest[0] == '+')) {
    neg = rest[0] == '-';
    rest = rest.substring(1);
  }
  if (rest == '0') return 0;
  if (rest.isEmpty) return null;

  bool isDigit(int i) {
    final c = rest.codeUnitAt(i);
    return c >= 0x30 && c <= 0x39;
  }

  bool isDigitOrDot(int i) => rest[i] == '.' || isDigit(i);

  var total = 0;
  var i = 0;
  while (i < rest.length) {
    // Следующий символ обязан быть [0-9.].
    if (!isDigitOrDot(i)) return null;

    // Целая часть.
    var v = 0;
    final intStart = i;
    while (i < rest.length && isDigit(i)) {
      if (v > maxNs ~/ 10) return null;
      v = v * 10 + (rest.codeUnitAt(i) - 0x30);
      if (v < 0) return null;
      i++;
    }
    final pre = i != intStart;

    // Дробная часть: переполнение не ошибка, точность просто перестаёт копиться.
    var f = 0;
    var scale = 1.0;
    var post = false;
    if (i < rest.length && rest[i] == '.') {
      i++;
      final fracStart = i;
      var overflow = false;
      while (i < rest.length && isDigit(i)) {
        if (!overflow) {
          if (f > maxNs ~/ 10) {
            overflow = true;
          } else {
            final y = f * 10 + (rest.codeUnitAt(i) - 0x30);
            if (y < 0) {
              overflow = true;
            } else {
              f = y;
              scale *= 10;
            }
          }
        }
        i++;
      }
      post = i != fracStart;
    }
    if (!pre && !post) return null; // ".s", "-.s"

    // Единица — всё до следующей цифры или точки.
    final unitStart = i;
    while (i < rest.length && !isDigitOrDot(i)) {
      i++;
    }
    if (i == unitStart) return null; // число без единицы
    final unit = _kCoreDurationUnits[rest.substring(unitStart, i)];
    if (unit == null) return null;

    if (v > maxNs ~/ unit) return null;
    v *= unit;
    if (f > 0) {
      final add = (f.toDouble() * (unit / scale)).toInt();
      if (add > maxNs - v) return null;
      v += add;
    }
    if (v > maxNs - total) return null;
    total += v;
  }
  return neg ? -total : total;
}

/// Единицы `my_time.unitMap` ядра, в наносекундах.
const _kCoreDurationUnits = <String, int>{
  'ns': 1,
  'us': 1000,
  'µs': 1000, // U+00B5 micro sign
  'μs': 1000, // U+03BC greek mu
  'ms': 1000000,
  's': 1000000000,
  'm': 60 * 1000000000,
  'h': 3600 * 1000000000,
  'd': 24 * 3600 * 1000000000,
};
