// §532 — КОРПУСНЫЕ ФОРМЫ 1.1.53 на локальных фикстурах.
//
// Кейсы корпуса под эти формы приедут синком 1.1.53 (задача 533); до него те же
// формы проверяются ЗДЕСЬ, с ожидаемым результатом по семантике Go-эталона.
// Смысл файла — не дублировать корпус, а не дать дефектам вернуться молча в
// промежутке между фиксом движка и синком.
//
// Гейт — ЗЕРКАЛО реестра `assets/contract` (оно в git и в APK), а не
// вендоренная копия `app/contract`: последней на CI нет, и тест под её гейтом
// пропускался бы именно там, где нужен.

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:lxbox/models/node_spec.dart';
import 'package:lxbox/models/node_warning.dart';
import 'package:lxbox/services/contract/registry.dart';
import 'package:lxbox/services/parser/body_decoder.dart';
import 'package:lxbox/services/parser/engine/section_loader.dart';
import 'package:lxbox/services/parser/mappers/draft_sections.dart';
import 'package:lxbox/services/parser/parse_all.dart';

const _registryRoot = 'assets/contract';
const _draftRoot = 'assets/contract_draft';

List<NodeSpec> _parse(String body, List<NodeWarning> dropped) =>
    parseAll(decode(body), dropped: dropped);

void main() {
  final mirrored = Directory('$_registryRoot/registry').existsSync();
  final skip = mirrored ? null : 'зеркало реестра не найдено';

  setUpAll(() async {
    if (!mirrored) return;
    await ContractRegistry.I.loadFromDirectory(_registryRoot);
    await MapperSections.I.loadDrafts(dir: _draftRoot, files: kDraftFiles);
  });

  group('§532 дефект 4 · булев на выходе без emit_as', () {
    test('необъявленный булев уезжает СЛОВОМ, как у эталона', () {
      // Go-движок на том же теле собирает `reduce_rtt=true`
      // (TestEngineEmitVsSnapshot, origin/develop лаунчера). Цифру пишет
      // только явный `emit_as: bool01`.
      final dropped = <NodeWarning>[];
      final nodes = _parse(
        'tuic://11111111-1111-1111-1111-111111111111:pass123@example-1.com:443'
        '?reduce_rtt=1&sni=example-1.com#w',
        dropped,
      );
      expect(nodes, hasLength(1));
      expect((nodes.single as TuicSpec).zeroRtt, isTrue);
      final uri = nodes.single.toUri();
      expect(uri, contains('reduce_rtt=true'));
      expect(uri, isNot(contains('reduce_rtt=1')));
    });

    test('ложь не пишется вовсе — «параметра нет» и есть её написание', () {
      final dropped = <NodeWarning>[];
      final nodes = _parse(
        'tuic://11111111-1111-1111-1111-111111111111:pass123@example-1.com:443'
        '?reduce_rtt=0&sni=example-1.com#w',
        dropped,
      );
      expect(nodes, hasLength(1));
      final uri = nodes.single.toUri();
      expect(uri, isNot(contains('reduce_rtt')));
    });
  }, skip: skip);
}
