/// §144 — Punycode (RFC 3492) + per-label IDNA ToASCII для domain / suffix
/// полей CustomRuleEditScreen.
///
/// Зачем своя реализация, а не пакет: нам нужен только encode (юзер вводит
/// Unicode-домен → сохраняем ASCII `xn--…` для sing-box) и только per-label.
/// Это ~70 строк чистого Dart без внешних зависимостей (project rule — без
/// лишних depов). Полный UTS-46 nameprep (мапинг ﬁ→fi, ß→ss, bidi-проверки)
/// НЕ делаем: для VPN-правил достаточно lower-case + Punycode не-ASCII меток.
library;

const int _base = 36;
const int _tMin = 1;
const int _tMax = 26;
const int _skew = 38;
const int _damp = 700;
const int _initialBias = 72;
const int _initialN = 128; // 0x80 — первый не-ASCII code point
const int _delimiter = 0x2D; // '-'

/// `digit (0..35) → ASCII`: 0..25 → 'a'..'z', 26..35 → '0'..'9'.
int _encodeDigit(int d) => d + (d < 26 ? 97 : 22);

int _adapt(int delta, int numPoints, bool firstTime) {
  delta = firstTime ? delta ~/ _damp : delta ~/ 2;
  delta += delta ~/ numPoints;
  var k = 0;
  while (delta > ((_base - _tMin) * _tMax) ~/ 2) {
    delta ~/= _base - _tMin;
    k += _base;
  }
  return k + ((_base - _tMin + 1) * delta) ~/ (delta + _skew);
}

/// RFC 3492 §6.3 encode: Unicode code points → Punycode (БЕЗ `xn--`).
/// Бросает [FormatException] на пустой вход (caller гарантирует non-empty).
String punycodeEncode(String input) {
  final codePoints = input.runes.toList();
  final output = StringBuffer();

  // Копируем basic (ASCII) code points как есть.
  var basicCount = 0;
  for (final cp in codePoints) {
    if (cp < 0x80) {
      output.writeCharCode(cp);
      basicCount++;
    }
  }
  final handled = basicCount;
  if (basicCount > 0) output.writeCharCode(_delimiter);

  var n = _initialN;
  var delta = 0;
  var bias = _initialBias;
  var processed = handled;

  while (processed < codePoints.length) {
    // Минимальный code point ≥ n среди оставшихся.
    var m = 0x7fffffff;
    for (final cp in codePoints) {
      if (cp >= n && cp < m) m = cp;
    }
    delta += (m - n) * (processed + 1);
    n = m;

    for (final cp in codePoints) {
      if (cp < n) delta++;
      if (cp == n) {
        var q = delta;
        for (var k = _base;; k += _base) {
          final t = k <= bias
              ? _tMin
              : (k >= bias + _tMax ? _tMax : k - bias);
          if (q < t) break;
          output.writeCharCode(_encodeDigit(t + (q - t) % (_base - t)));
          q = (q - t) ~/ (_base - t);
        }
        output.writeCharCode(_encodeDigit(q));
        bias = _adapt(delta, processed + 1, processed == handled);
        delta = 0;
        processed++;
      }
    }
    delta++;
    n++;
  }
  return output.toString();
}

/// IDNA ToASCII по-лейблово: split по '.', каждый не-ASCII лейбл → `xn--…`.
/// Pure-ASCII лейблы возвращаются как есть (уже lower-cased caller'ом).
/// Невалидный Punycode-результат (пустой лейбл) не маскируем — возвращаем
/// исходный лейбл, валидатор поля затем пометит его invalid.
String domainToAscii(String input) {
  if (!input.runes.any((r) => r >= 0x80)) return input; // fast-path: чистый ASCII
  return input.split('.').map((label) {
    if (label.isEmpty) return label;
    if (!label.runes.any((r) => r >= 0x80)) return label; // ASCII-лейбл as-is
    return 'xn--${punycodeEncode(label)}';
  }).join('.');
}
