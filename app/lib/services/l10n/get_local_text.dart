// §285 — движок natural-key локализации. Английский текст на call-site И ЕСТЬ
// ключ; перевод берётся из assets/l10n/ui/<tag>.json, иначе fallback = сам ключ
// с подставленными аргументами. Ничего не бросает: любой промах (нет словаря,
// нет ключа, нет формы) деградирует в английский ключ.
//
// Словарь: Map<englishKey, entry>, где entry =
//   { "value": <String|pluralObj>, "special": { "1": { "value": ... }, ... } }
// Форма 0 = корневой value; форма N≥1 = special["N"].value. pluralObj —
// Map<formName, String> (набор форм диктует PluralResolver).

import 'plural_resolver.dart';

class GetLocalText {
  // _dict == null → fallback-локаль (en или отсутствующий файл): всё печатается
  // из ключа. По построению словарь плоский (englishKey → entry-map).
  GetLocalText(this._dict, this._plural);

  /// §285 — пиненный английский рендерер для machine-поверхностей (renderEn):
  /// dict=null → любой ключ печатается как есть (английский текст call-site'а)
  /// с подставленными аргументами, НЕЗАВИСИМО от активной локали. Заменяет
  /// прежний `L10n.en`-путь Phase 4.
  static const en = GetLocalText.raw();
  const GetLocalText.raw()
      : _dict = null,
        _plural = const EnPluralResolver();

  final Map<String, dynamic>? _dict;
  final PluralResolver _plural;

  /// Простая строка. Первый int-аргумент (если есть) — индекс особой формы;
  /// иначе форма 0 и первый аргумент — ключ.
  ///
  ///   s("Connected to %s", host)   → форма 0
  ///   s(1, "New")                   → особая форма №1 (special["1"])
  String s(Object a0,
      [Object? a1,
      Object? a2,
      Object? a3,
      Object? a4,
      Object? a5,
      Object? a6]) {
    final int formIndex;
    final String key;
    final List<Object?> args;
    // Дизамбигуация по рантайм-типу первого аргумента (Dart без overload'ов).
    // int-первым = индекс формы; ключ всегда String — если a0 не int, это ключ.
    if (a0 is int) {
      formIndex = a0;
      key = a1 is String ? a1 : a1.toString();
      args = _prefixNonNull([a2, a3, a4, a5, a6]);
    } else {
      formIndex = 0;
      key = a0 is String ? a0 : a0.toString();
      args = _prefixNonNull([a1, a2, a3, a4, a5, a6]);
    }

    final raw = _lookupValue(key, formIndex);
    // raw String → перевод-форма; null → нет записи (fallback = ключ);
    // Map → это plural-объект, но звали .s (не .plural) → error-tolerant fallback
    // на ключ, чтобы не печатать сырой JSON.
    final template = raw is String ? raw : key;
    return _format(template, args);
  }

  /// Множественное число. Последний позиционный аргумент — число (num), идёт в
  /// %d. Первый int-аргумент (если стоит ПЕРЕД ключом) — индекс особой формы.
  ///
  ///   plural("%d servers", n)       → форма 0
  ///   plural(1, "%d items", n)      → особая форма №1 + плюрал
  String plural(Object a0,
      [Object? a1, Object? a2, Object? a3, Object? a4]) {
    final int formIndex;
    final String key;
    final num n;
    // §285 — доп. аргументы после счётчика: plural-строки с ВТОРЫМ placeholder'ом
    // (напр. "%1$d servers · %2$d off") — счётчик всегда первым в args (%1$…/%d),
    // остальные позиционные следом.
    final List<Object?> rest;
    if (a0 is int && a1 != null) {
      // (formIndex, key, n, ...extra): a0 стоит перед ключом-строкой a1.
      formIndex = a0;
      key = a1 is String ? a1 : a1.toString();
      n = a2 is num ? a2 : 0;
      rest = [a3, a4];
    } else {
      // (key, n, ...extra): a0 — ключ, a1 — число. (a0 не может быть int-индексом
      // здесь: одиночный int без ключа-строки следом трактуем как ключ → fallback.)
      formIndex = 0;
      key = a0 is String ? a0 : a0.toString();
      n = a1 is num ? a1 : 0;
      rest = [a2, a3, a4];
    }
    // Счётчик — первый арг подстановки, доп. значения (не-null префикс) — следом.
    final args = <Object?>[n, ...rest.takeWhile((e) => e != null)];

    final raw = _lookupValue(key, formIndex);
    // Ждём plural-объект (Map<String,String>). Если словарь дал строку/ничего —
    // fallback на английский ключ: он уже читается как plural (напр. "%d servers"),
    // подставляем %d=n. У английского ключа отдельных форм нет — это приемлемо.
    if (raw is Map) {
      final forms = <String, String>{
        for (final e in raw.entries)
          e.key.toString(): e.value is String ? e.value as String : '',
      };
      final picked = _plural.select(forms, n);
      return _format(picked, args);
    }
    return _format(key, args);
  }

  /// Достаёт value формы [formIndex] для [key]: возвращает String (простой
  /// перевод), Map (plural-объект) или null (нет записи/формы/словаря).
  Object? _lookupValue(String key, int formIndex) {
    final dict = _dict;
    if (dict == null) return null;
    final entry = dict[key];
    if (entry is! Map) return null;
    if (formIndex <= 0) return entry['value'];
    // Форма N≥1: special["N"].value. special["0"] не существует by design.
    final special = entry['special'];
    if (special is! Map) return null;
    final form = special[formIndex.toString()];
    if (form is! Map) return null;
    return form['value'];
  }

  static List<Object?> _prefixNonNull(List<Object?> a) {
    // Непустой префикс: обрезаем по первому null (позиционные аргументы плотные).
    final out = <Object?>[];
    for (final x in a) {
      if (x == null) break;
      out.add(x);
    }
    return out;
  }

  /// printf-подстановка. Поддержка:
  ///   %s          — args[i].toString() (последовательный)
  ///   %d          — целое (num→int, иначе toString)
  ///   %1$s / %2$s — явная позиция (1-based), тип-буква после $ (s/d)
  ///   %%          — литеральный процент
  /// Пропущенный аргумент (нет по индексу) → пустая строка (плейсхолдер съедаем,
  /// не печатаем сырой %s — иначе в UI утекал бы формат-код).
  static String _format(String template, List<Object?> args) {
    final out = StringBuffer();
    var seq = 0; // счётчик последовательных (неявных) %s/%d
    var i = 0;
    while (i < template.length) {
      final c = template[i];
      if (c != '%') {
        out.write(c);
        i++;
        continue;
      }
      // c == '%'; смотрим следующий символ.
      if (i + 1 >= template.length) {
        out.write('%'); // висячий % в конце — печатаем как есть
        break;
      }
      final next = template[i + 1];
      if (next == '%') {
        out.write('%');
        i += 2;
        continue;
      }
      // Явная позиция: %<digits>$<conv>
      if (_isDigit(next)) {
        var j = i + 1;
        while (j < template.length && _isDigit(template[j])) {
          j++;
        }
        if (j + 1 < template.length && template[j] == r'$') {
          final pos = int.parse(template.substring(i + 1, j));
          final conv = template[j + 1];
          out.write(_render(args, pos - 1, conv));
          i = j + 2;
          continue;
        }
        // Не форма %N$ — печатаем '%' буквально, дальше идём с next.
        out.write('%');
        i++;
        continue;
      }
      if (next == 's' || next == 'd') {
        out.write(_render(args, seq, next));
        seq++;
        i += 2;
        continue;
      }
      // Неизвестный конверсионный символ — печатаем '%' буквально.
      out.write('%');
      i++;
    }
    return out.toString();
  }

  static bool _isDigit(String c) {
    final u = c.codeUnitAt(0);
    return u >= 0x30 && u <= 0x39;
  }

  static String _render(List<Object?> args, int index, String conv) {
    if (index < 0 || index >= args.length) return ''; // пропущенный аргумент
    final v = args[index];
    if (v == null) return '';
    if (conv == 'd') {
      if (v is int) return v.toString();
      if (v is num) return v.truncate().toString();
      return v.toString();
    }
    return v.toString(); // %s
  }
}
