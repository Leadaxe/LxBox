// §525 — корпус публичных подписок: прогон конвейера разбора по снимкам.
//
// Это ЕДИНСТВЕННЫЙ энтрипоинт прогона: конвейер разбора тянет Flutter
// (`node_warning.dart` → l10n → `package:flutter/widgets.dart`), поэтому
// запустить его голым `dart run` нельзя ни из какого каталога.
//
// Сьют НЕ идёт в общем `flutter test`: он разбирает 68 тел суммарно на ~20 МБ
// и краснеет на РЕГРЕССИИ РЕЕСТРА, а не на изменениях приложения — в общем
// прогоне это дорогой шум, зависящий от правок контракта, а не кода. Гейт —
// переменная окружения, а не тег: исключить тег по умолчанию может только
// `exclude_tags` в `dart_test.yaml`, а обнулить его на запуске нечем —
// `flutter test` не пробрасывает ни `--exclude-tags`, ни пресеты (`-P`).
//
// Запуск ИЗ КАТАЛОГА `app/`:
//
//   # прогон + сверка с эталоном (это же делает CI)
//   LX_CORPUS_PUBLIC=1 flutter test test/public_subscriptions
//
//   # то же + перезапись report.json / report.md
//   LX_CORPUS_PUBLIC=1 LX_CORPUS_REPORT=1 flutter test test/public_subscriptions
//
//   # переписать ЭТАЛОН (отдельным коммитом, с объявленной причиной!)
//   LX_CORPUS_PUBLIC=1 LX_CORPUS_UPDATE_EXPECTED=1 \
//     flutter test test/public_subscriptions
//
// Что проверяется: числа прогона совпадают с закоммиченным эталоном
// (`expected.json`). Расхождение — это регрессия ИЛИ прогресс реестра, и
// разбираться с ним обязан человек.
//
// Чего сьют НЕ делает: не собирает конфиг, не запускает ядро, не ходит в
// сеть. См. `docs/testing/PUBLIC_SUBSCRIPTIONS_CORPUS.md`.

import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'corpus_report.dart';
import 'corpus_runner.dart';

bool _flag(String name) {
  final v = Platform.environment[name] ?? '';
  return v.isNotEmpty && v != '0';
}

void main() {
  if (!_flag('LX_CORPUS_PUBLIC')) {
    test('корпус публичных подписок', () {},
        skip: 'отдельный шаг: LX_CORPUS_PUBLIC=1 flutter test '
            'test/public_subscriptions');
    return;
  }
  // Корпуса нет (клон без фикстур) — сьют пропускается целиком, а не падает.
  if (!corpusAvailable) {
    test('корпус публичных подписок', () {},
        skip: 'нет $kCorpusRoot/index.json');
    return;
  }

  late List<SubscriptionResult> results;

  setUpAll(() async {
    results = await runCorpus(log: printOnFailure);
    if (_flag('LX_CORPUS_REPORT')) writeReports(results);
    if (_flag('LX_CORPUS_UPDATE_EXPECTED')) writeExpected(results);
  });

  test('каждый снимок с телом разобран без исключений', () {
    expect(results, isNotEmpty, reason: 'индекс корпуса пуст');
    // Исключение из `runCorpus` вылетело бы наружу; здесь — что прошли ВСЕ
    // тела, у которых оно есть.
    final withBody = readCorpusIndex()
        .where((e) => e.bodyFile != null)
        .where((e) => File('$kCorpusRoot/${e.bodyFile}').existsSync())
        .length;
    expect(results.length, withBody);
  });

  test('узлы нашлись более чем в половине подписок', () {
    // Сторож самого прогона: реестр, который перестал грузиться, дал бы ноль
    // узлов ВЕЗДЕ, и сверка с эталоном закричала бы про 68 подписок разом.
    // Этот тест называет причину короче.
    final withNodes = results.where((r) => r.nodesTotal > 0).length;
    expect(withNodes, greaterThan(results.length ~/ 2),
        reason: 'узлы нашлись только в $withNodes из ${results.length} — '
            'похоже, реестр или секции не загрузились');
  });

  test('числа совпадают с эталоном', () {
    if (_flag('LX_CORPUS_UPDATE_EXPECTED')) {
      // Эталон только что перезаписан — сверять его с собой нечего.
      return;
    }
    final f = File('$kCorpusRoot/expected.json');
    expect(f.existsSync(), isTrue,
        reason: 'эталона нет — создайте: LX_CORPUS_PUBLIC=1 '
            'LX_CORPUS_UPDATE_EXPECTED=1 flutter test test/public_subscriptions');
    final expected = (jsonDecode(f.readAsStringSync())
        as Map<String, dynamic>)['subscriptions'] as Map<String, dynamic>;

    final diffs = diffExpected(
        expected, {for (final r in results) r.id: r.toExpected()});
    expect(diffs, isEmpty,
        reason: 'расхождение с эталоном — регрессия ИЛИ прогресс реестра;\n'
            'разберитесь, затем обновите эталон отдельным коммитом:\n'
            '${diffs.join('\n')}');
  });
}
