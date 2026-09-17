// §460 W1 — инвариант 24.1.7 над корпусом контракта.
//
// Норма: «значение с вердиктом B (фатал на ВЕСЬ конфиг) после санитайзера в
// entry остаться не может». Проверяем это практически: санитайзер
// идемпотентен — повторный прогон по уже очищенному телу не находит НИ
// ОДНОГО нарушения. Если бы после первого прохода осталось значение, которое
// реестр считает негодным, второй проход его бы нашёл.
//
// Корпус — общий с лаунчером (`contract/corpus/body/**`), берём `entry`
// узлов из `expected.json`: это уже нормированные тела, на которых обе
// стороны сошлись.

import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:lxbox/services/contract/body_sanitizer.dart';
import 'package:lxbox/services/contract/registry.dart';

const _contractRoot = 'contract';

/// Пин ядра реестра: под ним `min_core`-поля корпуса законны.
const _core = '1.14.1-lx.4';

void main() {
  final root = Directory('$_contractRoot/corpus/body');
  final synced = root.existsSync() &&
      Directory('$_contractRoot/registry').existsSync();

  group('Инвариант 24.1.7 — санитайзер идемпотентен на корпусе', () {
    setUpAll(() async {
      if (!synced) return;
      await ContractRegistry.I.loadFromDirectory(_contractRoot);
    });

    if (!synced) {
      test('корпус контракта не синхронизирован', () {},
          skip: 'нет $_contractRoot/corpus/body — синхронизируйте контракт');
      return;
    }

    final files = root
        .listSync(recursive: true)
        .whereType<File>()
        .where((f) => f.path.endsWith('.expected.json'))
        .toList()
      ..sort((a, b) => a.path.compareTo(b.path));

    for (final file in files) {
      final rel = file.path.substring(root.path.length + 1);
      test(rel, () {
        final data =
            jsonDecode(file.readAsStringSync()) as Map<String, dynamic>;
        final nodes = (data['nodes'] as List?) ?? const [];
        var checked = 0;

        for (final raw in nodes) {
          if (raw is! Map) continue;
          final entry = raw['entry'];
          if (entry is! Map) continue;
          final body = entry.cast<String, dynamic>();
          final type = body['type'];
          if (type is! String) continue;
          // Схемы нет (расширение чужой стороны) — санитайзер такую запись и
          // не трогает, проверять нечего.
          if (ContractRegistry.I.schemaFor(type) == null) continue;

          final first = RegistrySanitizer.sanitize(
            Map<String, dynamic>.from(body),
            scheme: type,
            coreVersion: _core,
          );
          // Запись, снятая целиком, инвариант не нарушает: в конфиг она не
          // попадёт.
          if (first.body == null) continue;

          final second = RegistrySanitizer.sanitize(
            Map<String, dynamic>.from(first.body!),
            scheme: type,
            coreVersion: _core,
          );
          expect(
            second.warnings.map((w) => '${w.code}@${w.path}').toList(),
            isEmpty,
            reason: '$rel: после санитайзера в теле ${raw['label']} '
                '($type) остались значения, которые реестр считает негодными',
          );
          // Второй проход ничего не меняет — тело устойчиво.
          expect(second.body, first.body,
              reason: '$rel: санитайзер не идемпотентен на ${raw['label']}');
          checked++;
        }

        // Кейс без единой записи под схемой реестра — не молчаливый пропуск,
        // а факт: помечаем skipped, чтобы он не выглядел зелёной проверкой.
        if (checked == 0) {
          markTestSkipped('$rel: записей со схемой реестра нет');
        }
      });
    }
  });
}
