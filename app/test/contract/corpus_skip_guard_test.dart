import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import '../contract_paths.dart';

/// Сторож corpus-гейта: на CI без `app/contract` перечисляет пропущенные сьюты.
///
/// Не падает — только делает пропуск видимым в логе CI. Реестровые тесты на
/// зеркале `assets/contract` обязаны идти зелёными; этот файл — про корпус.
void main() {
  test('corpus skip guard — сводка пропусков', () {
    if (hasContractCorpus) return;

    printCorpusSkipSummary();

    final fromRun = readCorpusSkippedSuites();
    final suites = (fromRun.isNotEmpty ? fromRun : kKnownCorpusGatedSuites)
        .toList()
      ..sort();
    if (Platform.environment['CI'] == 'true' && suites.isNotEmpty) {
      // На CI не валим прогон, но перечисляем сьюты в логе.
      // ignore: avoid_print
      print('corpus skipped suites (${suites.length}):');
      for (final s in suites) {
        // ignore: avoid_print
        print('  - $s');
      }
    }

    // Сторож сам по себе зелёный: его задача — видимость, не блокировка CI.
    expect(hasRegistryMirror, isTrue,
        reason: 'зеркало реестра assets/contract обязано быть в git');
  });
}
