import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:lxbox/models/node_spec.dart';
import 'package:lxbox/models/node_warning.dart';
import 'package:lxbox/models/template_vars.dart';
import 'package:lxbox/services/contract/registry.dart';
import 'package:lxbox/services/node_hash.dart';
import 'package:lxbox/services/parser/body_decoder.dart';
import 'package:lxbox/services/parser/engine/section_loader.dart';
import 'package:lxbox/services/parser/mappers/draft_sections.dart';
import 'package:lxbox/services/parser/parse_all.dart';

/// §480 W5 — ВХОД-ДОКУМЕНТ Xray-JSON на движке секций.
///
/// Снимок `pipeline_identity_before.json` (45 входов) снят СТАРЫМ путём —
/// рукописным `xray_mapper.dart`, которого после этой волны нет. Сверка идёт
/// ПОСЛЕ САНИТАЙЗЕРА: снимок снят с готовых узлов, и движок без судьи их не
/// воспроизводит по построению (значения судит реестр, а не маппер).
///
/// Гейт — ЗЕРКАЛО реестра `assets/contract`, а не вендоренная копия
/// `app/contract`: последней на CI нет вовсе, и тест под её гейтом молча
/// пропускался бы именно там, где нужен.
const _registryRoot = 'assets/contract';
const _draftRoot = 'assets/contract_draft';
const _identityFixture = 'test/fixtures/xray/pipeline_identity_before.json';

/// Два расхождения со снимком, объявленные ШАГОМ 8 фичи 472 (не этой волной):
/// снимок снят ДО того, как Xray-вход получил судью, и оба кейса — работа
/// санитайзера, которой на этом входе прежде не было вовсе.
const Map<String, String> _expectedChanges = {
  'vless_ws_path_junk': 'битый путь снят с тела (format url_path), узел жив',
  'vless_encryption_junk': 'узел отбракован при разборе (drop_node §477)',
};

Map<String, dynamic> _fixture() =>
    (jsonDecode(File(_identityFixture).readAsStringSync()) as Map)
        .cast<String, dynamic>();

List<NodeSpec> _parseText(String body, List<NodeWarning> dropped) =>
    parseAll(decode(body), dropped: dropped);

void main() {
  final mirrored = Directory('$_registryRoot/registry').existsSync();
  final skip = mirrored ? null : 'зеркало реестра не найдено';

  setUpAll(() async {
    if (!mirrored) return;
    await ContractRegistry.I.loadFromDirectory(_registryRoot);
    await MapperSections.I.loadDrafts(dir: _draftRoot, files: kDraftFiles);
  });

  test('секции вида источника xray исполняемы и загружены', () {
    // Без секции движок не работает вовсе: запасного рукописного пути у
    // переехавшего входа не осталось.
    expect(MapperSections.I.typesFor('xray'), isNotEmpty);
    for (final type in MapperSections.I.typesFor('xray')) {
      expect(MapperSections.I.has('xray', type), isTrue,
          reason: 'секция xray/$type не исполняема');
    }
  }, skip: skip);

  test('опознание элемента: ровно одна секция на кейс корпуса', () {
    final before = _fixture();
    final ambiguous = <String>[];
    for (final e in before.entries) {
      final want = (e.value as Map).cast<String, dynamic>();
      final doc = jsonDecode(want['input_json'] as String);
      for (final el in (doc as List)) {
        final outbounds = (el as Map)['outbounds'];
        if (outbounds is! List) continue;
        for (final o in outbounds) {
          if (o is! Map) continue;
          final obj = o.cast<String, dynamic>();
          final protocol = obj['protocol']?.toString() ?? '';
          // Служебный outbound узлом не становится — опознавать его секции
          // протокола не обязаны (это знание сборки документа).
          if (const {'freedom', 'blackhole', 'dns', 'loopback'}
              .contains(protocol)) {
            continue;
          }
          final hits = MapperSections.I.matchJsonAll('xray', obj);
          if (hits.length > 1) {
            ambiguous.add('${e.key}: $protocol → '
                '${hits.map((s) => s.singboxType).join(", ")}');
          }
        }
      }
    }
    expect(ambiguous, isEmpty,
        reason: 'элемент обязан опознаваться РОВНО одной секцией');
  }, skip: skip);

  test('45 входов снимка: identity, тег, имя, rawSource и тело байт в байт',
      () {
    final before = _fixture();
    expect(before, hasLength(45));

    final diffs = <String>[];
    for (final e in before.entries) {
      final name = e.key;
      if (_expectedChanges.containsKey(name)) continue;
      final want = (e.value as Map).cast<String, dynamic>();
      final wantNodes = (want['nodes'] as List).cast<Map>();
      final dropped = <NodeWarning>[];
      final got = _parseText(want['input_json'] as String, dropped);

      if (got.length != wantNodes.length) {
        diffs.add('$name: узлов ${got.length}, ожидалось ${wantNodes.length}');
        continue;
      }
      for (var i = 0; i < wantNodes.length; i++) {
        final w = wantNodes[i].cast<String, dynamic>();
        final n = got[i];
        final gotBody = jsonEncode(n.emit(TemplateVars.empty).map);
        if (gotBody != w['body_json']) {
          diffs.add('$name[$i] тело:\n  было  ${w['body_json']}\n'
              '  стало $gotBody');
        }
        if (n.tag != w['tag']) {
          diffs.add('$name[$i] тег: было ${w['tag']}, стало ${n.tag}');
        }
        if (n.label != w['label']) {
          diffs.add('$name[$i] имя: было ${w['label']}, стало ${n.label}');
        }
        if (n.rawSource != w['rawSource']) {
          diffs.add('$name[$i] rawSource разошёлся');
        }
        if (legacyNodeIdentityHash(n) != w['identity']) {
          diffs.add('$name[$i] identity сдвинулась');
        }
        final wantChain = w['chained'];
        if (wantChain == null) {
          if (n.chained != null) diffs.add('$name[$i] звено появилось');
        } else if (n.chained == null) {
          diffs.add('$name[$i] звено пропало');
        } else if (legacyNodeIdentityHash(n.chained!) !=
            (wantChain as Map)['identity']) {
          diffs.add('$name[$i] identity звена сдвинулась');
        }
      }
      if (dropped.length != want['dropped']) {
        diffs.add('$name: отбраковок ${dropped.length}, '
            'ожидалось ${want['dropped']}');
      }
    }
    expect(diffs, isEmpty, reason: diffs.join('\n'));
  }, skip: skip);
}
