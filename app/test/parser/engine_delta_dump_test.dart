import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:lxbox/models/template_vars.dart';
import 'package:lxbox/services/contract/registry.dart';
import 'package:lxbox/services/node_hash.dart';
import 'package:lxbox/services/parser/engine/section_loader.dart';
import 'package:lxbox/services/parser/mappers/draft_sections.dart';
import 'package:lxbox/services/parser/uri_parsers.dart';

/// §480 W1 — СНЯТЬ значения дельт прогоном движка.
///
/// Не проверка, а инструмент: снимок обязан описывать поведение, а не
/// намерение, поэтому новые ожидания берутся прогоном, а не вписываются
/// руками. Запускается вручную с `LX_DUMP=<файл>`; без переменной не делает
/// ничего и в обычном прогоне молчит.
void main() {
  final out = Platform.environment['LX_DUMP'];

  test('дамп тел кейсов-дельт', () async {
    if (out == null) return;
    await ContractRegistry.I.loadFromDirectory('assets/contract');
    await MapperSections.I.loadDrafts(dir: 'assets/contract_draft', files: kDraftFiles);

    final raw = jsonDecode(
      File('test/fixtures/trojan/pipeline_identity_before.json')
          .readAsStringSync(),
    ) as Map;
    final cases = (raw['cases'] as Map).cast<String, dynamic>();

    final dump = <String, dynamic>{};
    for (final name in const [
      'upper_type_ws',
      'upper_alpn',
      'upper_fp',
      'path_raw_plus',
      'path_encoded_slash_raw_plus',
    ]) {
      final uri = (cases[name] as Map)['uri'] as String;
      final spec = parseUri(uri)!;
      dump[name] = {
        'identity': legacyNodeIdentityHash(spec),
        'tag': spec.tag,
        'body': jsonDecode(jsonEncode(spec.emit(TemplateVars.empty).map)),
      };
    }
    File(out).writeAsStringSync(jsonEncode(dump));
  });
}
