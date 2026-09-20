import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:lxbox/models/template_vars.dart';
import 'package:lxbox/services/contract/registry.dart';
import 'package:lxbox/services/node_hash.dart';
import 'package:lxbox/services/parser/engine/section_loader.dart';
import 'package:lxbox/services/parser/mappers/draft_sections.dart';
import 'package:lxbox/services/parser/uri_parsers.dart';

/// §480 W4 — СНЯТЬ новые значения кейсов-дельт прогоном движка.
///
/// Не проверка, а инструмент, как `engine_delta_dump_test.dart` у пилота:
/// снимок обязан описывать ПОВЕДЕНИЕ, а не намерение, поэтому ожидания
/// разрешённой дельты берутся прогоном, а не вписываются руками.
///
/// Запуск: `LX_SCHEME=<схема> LX_CASES=<кейс,кейс> LX_DUMP=<файл>`.
/// Без `LX_DUMP` не делает ничего.
void main() {
  final out = Platform.environment['LX_DUMP'];
  final scheme = Platform.environment['LX_SCHEME'] ?? '';
  final cases = Platform.environment['LX_CASES'] ?? '';

  test('дамп тел кейсов-дельт волны W4', () async {
    if (out == null || scheme.isEmpty || cases.isEmpty) return;
    await ContractRegistry.I.loadFromDirectory('assets/contract');
    await MapperSections.I
        .loadDrafts(dir: 'assets/contract_draft', files: kDraftFiles);

    final raw = jsonDecode(
      File('test/fixtures/$scheme/pipeline_identity_before.json')
          .readAsStringSync(),
    ) as Map;
    final all = (raw['cases'] as Map).cast<String, dynamic>();

    final dump = <String, dynamic>{};
    for (final name in cases.split(',')) {
      final uri = (all[name] as Map)['uri'] as String;
      final spec = parseUri(uri);
      dump[name] = spec == null
          ? <String, dynamic>{'identity': null, 'dropped': true}
          : <String, dynamic>{
              'identity': legacyNodeIdentityHash(spec),
              'tag': spec.tag,
              'body': jsonDecode(jsonEncode(spec.emit(TemplateVars.empty).map)),
            };
    }
    File(out).writeAsStringSync(const JsonEncoder.withIndent('  ').convert(dump));
  });
}
