import 'dart:io';

import '../l10n/src/check_common.dart';

// §360 — парность двуязычной документации.
//
// Документация ведётся парами RU/EN (README.md ↔ README_RU.md,
// docs/USER_GUIDE.md ↔ docs/USER_GUIDE_RU.md). Реальный режим работы —
// «правим русский, потом переводим», поэтому расхождение выглядит так: раздел
// дописали в один язык и забыли во второй. Молча это не видно: оба файла
// валидны сами по себе, а читатель второго языка просто не знает, что раздел
// существует.
//
// Что проверяется (по разделам, а не по словам — перевод НЕ обязан совпадать
// дословно):
//
// 1. Число заголовков каждого уровня совпадает в паре. Расходится → FAIL с
//    указанием, в каком файле разделов больше и на сколько.
// 2. Порядок разделов совпадает структурно: последовательность уровней
//    (##, ###) читается как «скелет» документа. Разошёлся → FAIL: значит
//    раздел вставлен не туда или потерян.
// 3. Кодовые блоки (```) сбалансированы и их поровну — примеры кода/шаблонов
//    в переводе не теряются.
//
// Заголовки НЕ сравниваются по тексту: «## Recipes» и «## Рецепты» — норма.
//
// Ссылки НЕ сверяются намеренно. Перевод законно ведёт на другие адреса:
// внешние — на локализованную версию (MDN `/ru/` против `/en-US/`),
// внутренние — на документ своего языка, если у него появится пара. Такая
// проверка падала бы на КОРРЕКТНОЙ документации и требовала бы дописывать
// исключения при каждой новой паре. На реальном дереве она к тому же не
// находила ничего: расхождение состава ссылок ловится числом разделов.
//
// Запуск: dart run tool/docs/parity_check.dart [--strict]  (из app/)

/// Пары «переведённый файл» ↔ «оригинал». Пути относительно корня репозитория.
const _pairs = <({String en, String ru})>[
  (en: 'README.md', ru: 'README_RU.md'),
  (en: 'docs/USER_GUIDE.md', ru: 'docs/USER_GUIDE_RU.md'),
  (en: 'docs/DONATE.md', ru: 'docs/DONATE_RU.md'),
];

void main(List<String> args) {
  ensureAppCwd();
  final strict = parseStrict(args);
  final r = CheckReporter('docs_parity', strict: strict);

  // Чекеры бегут из app/, документация лежит в корне репозитория.
  final root = Directory.current.parent.path;
  var pairsChecked = 0;

  for (final pair in _pairs) {
    final enFile = File('$root/${pair.en}');
    final ruFile = File('$root/${pair.ru}');

    if (!enFile.existsSync() || !ruFile.existsSync()) {
      final missing = !enFile.existsSync() ? pair.en : pair.ru;
      r.fail('$missing: файл не найден (пара ${pair.en} ↔ ${pair.ru})');
      continue;
    }

    pairsChecked++;
    final en = _Doc.parse(enFile.readAsStringSync(), pair.en);
    final ru = _Doc.parse(ruFile.readAsStringSync(), pair.ru);

    _compareHeadings(r, en, ru);
    _compareFences(r, en, ru);
  }

  exit(r.finish(extraRows: [MapEntry('pairs', '$pairsChecked')]));
}

/// Разобранный markdown-документ: скелет заголовков и число кодовых блоков.
class _Doc {
  _Doc(this.path, this.headings, this.fenceCount);

  final String path;

  /// Уровни заголовков по порядку появления (2 для `##`, 3 для `###`).
  /// H1 пропускается — это заголовок документа, он один.
  final List<int> headings;

  final int fenceCount;

  static final _headingRe = RegExp(r'^(#{2,6})\s+\S');

  static _Doc parse(String content, String path) {
    final headings = <int>[];
    var fences = 0;
    var inFence = false;

    for (final line in content.split('\n')) {
      // Заборы ```: внутри них markdown не действует — заголовки в примерах
      // кода не считаем.
      if (line.trimLeft().startsWith('```')) {
        fences++;
        inFence = !inFence;
        continue;
      }
      if (inFence) continue;

      final h = _headingRe.firstMatch(line);
      if (h != null) headings.add(h.group(1)!.length);
    }

    if (inFence) {
      // Незакрытый ``` — сам по себе дефект разметки: остаток файла
      // отрендерится как код.
      stdout.writeln('warn: $path: незакрытый блок ``` (нечётное число заборов)');
    }
    return _Doc(path, headings, fences ~/ 2);
  }
}

void _compareHeadings(CheckReporter r, _Doc en, _Doc ru) {
  if (en.headings.length != ru.headings.length) {
    final more = en.headings.length > ru.headings.length ? en.path : ru.path;
    final diff = (en.headings.length - ru.headings.length).abs();
    r.fail('${en.path} ↔ ${ru.path}: разное число разделов '
        '(${en.path}: ${en.headings.length}, ${ru.path}: ${ru.headings.length}) — '
        'в $more на $diff больше. Раздел добавлен в один язык и не перенесён '
        'во второй.');
    return;
  }

  // Число совпало — проверяем скелет: уровни в том же порядке.
  for (var i = 0; i < en.headings.length; i++) {
    if (en.headings[i] != ru.headings[i]) {
      r.fail('${en.path} ↔ ${ru.path}: структура разделов разошлась на '
          'позиции ${i + 1} (${en.path}: H${en.headings[i]}, '
          '${ru.path}: H${ru.headings[i]}) — раздел вставлен на другом уровне '
          'вложенности.');
      return; // первое расхождение сдвигает все последующие — репортим одно
    }
  }
}

void _compareFences(CheckReporter r, _Doc en, _Doc ru) {
  if (en.fenceCount != ru.fenceCount) {
    r.fail('${en.path} ↔ ${ru.path}: разное число блоков кода '
        '(${en.path}: ${en.fenceCount}, ${ru.path}: ${ru.fenceCount}) — '
        'пример/схема потеряна при переводе.');
  }
}
