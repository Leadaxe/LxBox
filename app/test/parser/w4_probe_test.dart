import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:lxbox/models/template_vars.dart';
import 'package:lxbox/services/contract/registry.dart';
import 'package:lxbox/services/parser/engine/interpreter.dart';
import 'package:lxbox/services/parser/engine/section_loader.dart';
import 'package:lxbox/services/parser/mappers/draft_sections.dart';
import 'package:lxbox/services/parser/uri_parsers.dart';

/// Временный зонд волны W4.
void main() {
  const registryRoot = 'assets/contract';
  final mirrored = Directory('$registryRoot/registry').existsSync();

  setUpAll(() async {
    if (!mirrored) return;
    await ContractRegistry.I.loadFromDirectory(registryRoot);
    await MapperSections.I
        .loadDrafts(dir: 'assets/contract_draft', files: kDraftFiles);
  });

  test('probe', () {
    const base = 'wireguard://aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaA=@h'
        ':51820?publickey=bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbA='
        '&address=10.0.0.2/32';
    final spec = parseUri('$base&h1=10-&h2=a-b&h3=-5&h4=1-2-3&jc=4#n');
    // ignore: avoid_print
    print('warnings: ${spec?.warnings.map((w) => w.runtimeType).toList()}');
    // ignore: avoid_print
    print('rendered: ${spec?.warnings.map((w) => w.renderEn()).toList()}');
    // ignore: avoid_print
    print('body: ${spec?.emit(TemplateVars.empty).map}');

    const canonUri =
        'wireguard://ccccccccccccccccccccccccccccccccccccccccccC=@h.example'
        ':51820?publickey=ddddddddddddddddddddddddddddddddddddddddddD='
        '&address=10.0.0.3/32#n';
    final res = parseUri(canonUri);
    // ignore: avoid_print
    print('canon: ${res?.emit(TemplateVars.empty).map}');
    final section = MapperSections.I.sectionFor('uri', 'wireguard')!;
    // ignore: avoid_print
    print('canon raw: ${runSection(section, canonUri)?.body}');

    final r2 = parseUri('$base&reserved=1,2,3#n');
    // ignore: avoid_print
    print('reserved dec: ${r2?.emit(TemplateVars.empty).map}');
    final r3 = parseUri('$base&client_id=AQID#n');
    // ignore: avoid_print
    print('reserved b64: ${r3?.emit(TemplateVars.empty).map}');
  }, skip: mirrored ? null : 'нет зеркала');
}
