import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:lxbox/models/template_vars.dart';
import 'package:lxbox/services/contract/registry.dart';
import 'package:lxbox/services/node_hash.dart';
import 'package:lxbox/services/parser/engine/section_loader.dart';
import 'package:lxbox/services/parser/mappers/draft_sections.dart';
import 'package:lxbox/services/parser/uri_parsers.dart';

/// §480 W4 — СНЯТИЕ новых ожиданий для кейсов-дельт.
///
/// Запускается руками (`--plain-name dump`) и печатает готовый JSON кейса с
/// новыми `identity`/`tag`/`body` и прежними значениями в `_before480`.
/// Ожидания дельты СНИМАЮТСЯ ПРОГОНОМ, а не вписываются руками: снимок
/// описывает поведение, а не намерение, и вписанное руками тело прикрыло бы
/// собой ошибку секции.
void main() {
  const registryRoot = 'assets/contract';
  final mirrored = Directory('$registryRoot/registry').existsSync();

  setUpAll(() async {
    if (!mirrored) return;
    await ContractRegistry.I.loadFromDirectory(registryRoot);
    await MapperSections.I
        .loadDrafts(dir: 'assets/contract_draft', files: kDraftFiles);
  });

  test('dump', () {
    // scheme → кейсы, чьи ожидания надо пересnять.
    const targets = <String, List<String>>{
      'hysteria2': ['b480:pinsha256_pair'],
      'masque': ['b480:publickey_raw_plus'],
      'wireguard': [
        'b480:publickey_raw_plus',
        'b480:privatekey_raw_plus_query',
        'b480:presharedkey_raw_plus',
      ],
    };
    for (final e in targets.entries) {
      final path = 'test/fixtures/${e.key}/pipeline_identity_before.json';
      final raw = jsonDecode(File(path).readAsStringSync()) as Map;
      final cases = (raw['cases'] as Map).cast<String, dynamic>();
      for (final name in e.value) {
        final c = (cases[name] as Map?)?.cast<String, dynamic>();
        if (c == null) {
          // ignore: avoid_print
          print('${e.key}/$name: кейса нет');
          continue;
        }
        final spec = parseUri(c['uri'] as String);
        // ignore: avoid_print
        print('=== ${e.key}/$name');
        if (spec == null) {
          // ignore: avoid_print
          print('  НЕ РАЗБИРАЕТСЯ');
          continue;
        }
        // ignore: avoid_print
        print(jsonEncode({
          'identity': legacyNodeIdentityHash(spec),
          'tag': spec.tag,
          'body': spec.emit(TemplateVars.empty).map,
        }));
      }
    }
  }, skip: mirrored ? null : 'зеркало реестра не найдено');
}
