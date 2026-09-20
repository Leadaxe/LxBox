/// §480 W1 — ДЕКОДЕРЫ движка по норме SPEC 133 §0.4/§0.6 (FROZEN).
///
/// Правило одно и записано в грамматике, а не в коде:
///
/// - **percent — один раз и до всего остального.** Второй проход портит `+` в
///   PEM и паролях; у лаунчера это соблюдено сознательно и двумя
///   узаконенными исключениями.
/// - **`+` в query = пробел** (form-encoding, норма не отменяется).
///   Исключение выводится ИЗ РЕЕСТРА, а не из списка имён: у поля с
///   `format: base64*` движок читает `+` буквально (`decode_extra.plus_literal`,
///   по умолчанию выводимый из формата). Одно правило вместо четырёх заплат,
///   которые сегодня стоят у обеих сторон на ключах-секретах.
/// - **`+` в fragment и userinfo литерален** — там form-encoding не действует
///   вовсе.
/// - `decode_extra` — ПОВЕРХ первого прохода:
///   `alpn` = `{mode: query, passes: until_stable, max: 16}`;
///   `path` = `{mode: path, passes: 2}` — path-семантика на ОБОИХ проходах,
///   то есть `+` в пути литерален с самого начала. Query-семантика на первом
///   проходе превратила бы `/ws+v2` в `/ws v2` — сервер отвечает 404, узел
///   «жив» и молча не работает.
library;

import 'dart:convert' show Utf8Decoder;

/// Семантика percent-декода.
enum DecodeMode {
  /// `application/x-www-form-urlencoded`: `+` становится пробелом.
  query,

  /// Path-семантика: `+` литерален, декодируются только `%XX`.
  path,
}

/// Один проход percent-декода с заданной семантикой.
///
/// Битый `%`-хвост (`%zz`, одинокий `%`) НЕ роняет разбор и НЕ снимает
/// значение: он остаётся как есть. Так требует фикстура
/// `ws_path_broken_percent_kept` у обеих сторон — значение доезжает до
/// санитайзера, и код о негодности ставит он, с путём и значением.
String percentDecodeOnce(String raw, {DecodeMode mode = DecodeMode.query}) {
  if (raw.isEmpty) return raw;
  final hasPlus = mode == DecodeMode.query && raw.contains('+');
  if (!raw.contains('%') && !hasPlus) return raw;

  final out = StringBuffer();
  final bytes = <int>[];

  void flush() {
    if (bytes.isEmpty) return;
    out.write(_utf8OrRaw(bytes));
    bytes.clear();
  }

  for (var i = 0; i < raw.length; i++) {
    final ch = raw.codeUnitAt(i);
    if (ch == 0x25 /* % */ && i + 2 < raw.length) {
      final hi = _hex(raw.codeUnitAt(i + 1));
      final lo = _hex(raw.codeUnitAt(i + 2));
      if (hi >= 0 && lo >= 0) {
        bytes.add(hi * 16 + lo);
        i += 2;
        continue;
      }
    }
    flush();
    if (ch == 0x2B /* + */ && mode == DecodeMode.query) {
      out.write(' ');
    } else {
      out.writeCharCode(ch);
    }
  }
  flush();
  return out.toString();
}

/// Повторный percent-декод по правилам `decode_extra`.
///
/// [passes] — число проходов; `null` означает `until_stable` с потолком
/// [max]. Потолок обязателен: он страховка от патологического ввода, а не
/// оптимизация (легитимный multiply-encoding стабилизируется за 3–5).
///
/// Первый проход декодера формы сюда НЕ входит — это надстройка над ним.
String decodeExtra(
  String value, {
  DecodeMode mode = DecodeMode.query,
  int? passes,
  int max = 16,
}) {
  var v = value;
  final limit = passes ?? max;
  for (var i = 0; i < limit; i++) {
    if (!v.contains('%')) break;
    final next = percentDecodeOnce(v, mode: mode);
    // Стабилизация: декодировать больше нечего (или `%`-хвост битый).
    if (next == v) break;
    v = next;
    if (passes == null) continue;
  }
  return v;
}

/// Байты percent-последовательности в текст.
///
/// Не-UTF-8 байты не роняют разбор: агрегаторы шлют percent-кодированный
/// cp1251 в метках, и такой узел обязан доехать.
String _utf8OrRaw(List<int> bytes) {
  try {
    return const Utf8Decoder(allowMalformed: true).convert(bytes);
  } catch (_) {
    return String.fromCharCodes(bytes);
  }
}

int _hex(int c) {
  if (c >= 0x30 && c <= 0x39) return c - 0x30;
  if (c >= 0x41 && c <= 0x46) return c - 0x41 + 10;
  if (c >= 0x61 && c <= 0x66) return c - 0x61 + 10;
  return -1;
}
