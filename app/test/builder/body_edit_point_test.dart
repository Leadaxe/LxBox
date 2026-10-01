import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// §577 раздел 2 — правка тела узла по правилу реестра идёт через одну точку
/// (`lib/services/contract/body_edit.dart`). Шаги сборки из описи спеки 577,
/// которые меняют тело по реестру, не пишут в карту тела напрямую:
/// ни присваивания по ключу, ни `remove`/`clear`/`addAll`.
///
/// Тест по исходникам: новая прямая запись в этих файлах обходила бы решение
/// «авторское тело — только жёсткие правила».
void main() {
  const steps = [
    'lib/services/builder/registry_gate.dart',
    'lib/services/builder/detour_yields.dart',
    'lib/services/builder/post_steps/heal_unknown_utls_fingerprints.dart',
    'lib/services/builder/post_steps/heal_invalid_reality.dart',
  ];
  final forbidden = <String, RegExp>{
    'присваивание по ключу': RegExp(r'\]\s*=(?!=)'),
    'remove': RegExp(r'\.remove\('),
    'clear': RegExp(r'\.clear\('),
    'addAll': RegExp(r'\.addAll\('),
    'removeWhere': RegExp(r'\.removeWhere\('),
  };

  for (final path in steps) {
    test(path, () {
      final file = File(path);
      expect(file.existsSync(), isTrue, reason: 'шаг из описи переехал: $path');
      final lines = file.readAsLinesSync();
      final hits = <String>[];
      for (var i = 0; i < lines.length; i++) {
        final code = lines[i].split('//').first;
        for (final e in forbidden.entries) {
          if (e.value.hasMatch(code)) hits.add('${i + 1}: ${e.key}: ${lines[i].trim()}');
        }
      }
      expect(hits, isEmpty,
          reason: 'прямая запись в тело в обход точки правки (body_edit.dart)');
    });
  }
}
