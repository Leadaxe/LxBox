/// §480 — ПРОСТРАНСТВО ИСТОЧНИКОВ `ini`: текст `.conf` в плоскую карту.
///
/// Третий вход движка рядом с лексером ссылки (`lexer.dart`) и объектным
/// входом (`runSectionOnJson`). Общего у всех трёх ровно одно: наружу они
/// отдают [SourceSpace], и дальше запись секции получает значение одним и тем
/// же `source`. Разбор входа — единственное, чем они различаются.
///
/// Имена источников, которые заполняет этот адаптер:
///
/// ```
/// ini.<Section>.<Key>        значение ключа секции
/// ini.$comment.<Section>     ИМЯ из комментария секции (G7)
/// ```
///
/// Оба адресуются в нижнем регистре: читатель источников
/// (`interpreter._readSourceBare`) опускает регистр перед поиском, потому что
/// имена секций и ключей INI регистронезависимы у обеих сторон
/// (`PrivateKey` = `privatekey`), а запись секции пишет их в каноне диалекта.
///
/// **Правила разбора не зашиты здесь.** Их называет `ini_dialect` секции
/// ([IniDialect], §0.11 DRAFT): регистр ключей и значений, префиксы
/// строчных комментариев, судьба повторного ключа, судьба повторной секции.
/// Движок исполняет объявленное — «как принято в wg-quick» свойством кода не
/// остаётся, иначе второй диалект (а он придёт: `.ovpn`, `.ini` панелей)
/// потребовал бы ветки здесь.
library;

import 'section.dart';
import 'source_space.dart';

/// Итог разбора INI: пространство плюс коды, которые поставил САМ РАЗБОР.
///
/// Коды отделены от пространства потому, что ставит их диалект, а не запись:
/// «вторая `[Peer]` отброшена» — свойство входа, и ни одна запись таблицы о
/// ней не узнает (её ключи до пространства не доехали вовсе).
typedef IniParse = ({Map<String, String> space, List<String> codes});

/// Разобрать текст INI по объявленному диалекту.
///
/// Ключ карты — `<section>.<key>` в нижнем регистре, плюс `$comment.<section>`
/// для источника-комментария. Значение — как велел `value_case` диалекта.
IniParse parseIniSpace(String text, IniDialect d) {
  final out = <String, String>{};
  final codes = <String>[];

  /// Сколько раз встретилась секция с таким именем (для `repeat`).
  final seen = <String, int>{};

  /// Имя текущей секции в нижнем регистре; пустое — строки до первой секции.
  var section = '';

  /// Пишем ли мы ключи текущей секции. Ложь у повторной секции с
  /// `repeat: first_only`: её строки читаются (чтобы не спутать конец файла с
  /// концом секции), но в пространство не едут.
  var collecting = true;

  for (final line in text.split(RegExp(r'\r?\n'))) {
    final t = line.trim();
    if (t.isEmpty) continue;

    // Комментарий целой строкой. Он не просто пропускается: у секции с
    // объявленным источником-комментарием ПЕРВЫЙ комментарий несёт имя узла
    // (G7 — Proton пишет под `[Peer]` строку `# CH-FREE#11`).
    final commentPrefix =
        d.lineCommentPrefixes.where(t.startsWith).firstOrNull;
    if (commentPrefix != null) {
      if (!collecting) continue;
      final body = t.substring(commentPrefix.length).trim();
      // Строка с `=` — это ЗАКОММЕНТИРОВАННАЯ ОПЦИЯ (`# Bouncing = 0`), а не
      // имя: отличить их больше нечем, и правило одинаково у обеих сторон.
      if (body.isEmpty || body.contains('=')) continue;
      // Ключ пространства — БЕЗ префикса `ini.`: его снимает читатель
      // источников перед поиском, ровно как у обычного `ini.<Section>.<Key>`.
      final key =
          '${DraftNames.iniCommentPrefix.substring('ini.'.length)}$section'
              .toLowerCase();
      // Первый комментарий секции выигрывает: имя пишут сразу под заголовком.
      out.putIfAbsent(key, () => body);
      continue;
    }

    if (t.startsWith('[')) {
      final close = t.indexOf(']');
      final name = (close > 0 ? t.substring(1, close) : t.substring(1)).trim();
      section = name.toLowerCase();
      final n = (seen[section] ?? 0) + 1;
      seen[section] = n;
      final rule = d.sectionRule(name);
      collecting = true;
      if (n > 1 && rule?.repeat == 'first_only') {
        collecting = false;
        final code = rule?.onExtraCode;
        if (code != null && !codes.contains(code)) codes.add(code);
      }
      continue;
    }

    if (!collecting) continue;

    final idx = t.indexOf('=');
    if (idx < 0) continue;
    var key = t.substring(0, idx).trim();
    var value = t.substring(idx + 1).trim();
    if (d.keyCase == 'lower') key = key.toLowerCase();
    if (d.valueCase == 'lower') value = value.toLowerCase();
    // Пустое значение — это «ключа нет»: сегодняшний разбор такую строку
    // пропускает (`DNS =` у кейса `ini:b480_empty_dns_value` кода не даёт).
    // Диалект объявит иное, когда появится вход, где пустота значима.
    if (value.isEmpty) continue;

    final path = '$section.$key';
    if (d.repeatedKey == 'first_wins' && out.containsKey(path)) continue;
    out[path] = value;
  }

  return (space: out, codes: codes);
}

/// Построить [SourceSpace] для формы с пространством `ini`.
SourceSpace iniSpace(String text, IniDialect d, {required String formId}) =>
    SourceSpace(formId: formId, ini: parseIniSpace(text, d).space);
