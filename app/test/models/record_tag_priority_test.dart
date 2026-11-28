import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:lxbox/models/codec/source_record.dart';
import 'package:lxbox/models/server_list.dart';
import 'package:lxbox/models/source_dialect.dart';
import 'package:lxbox/screens/node_settings/node_document.dart';
import 'package:lxbox/services/builder/verbatim_body.dart';
import 'package:lxbox/services/contract/registry.dart';
import 'package:lxbox/services/parser/engine/section_loader.dart';
import 'package:lxbox/services/parser/mappers/draft_sections.dart';
import 'package:lxbox/services/parser/source_name.dart';

// §456 — `tag` записи главнее имени из `origin` у любого вида;
// переименование `origin` не меняет.

final _key = base64.encode(List<int>.filled(32, 7));
final _ini = '[Interface]\nPrivateKey = $_key\nAddress = 10.8.1.4/32\n\n'
    '[Peer]\n# FromComment\nPublicKey = $_key\nAllowedIPs = 0.0.0.0/0\n'
    'Endpoint = example.com:666\n';
final _vpn =
    'vpn://${base64Url.encode(utf8.encode(_ini)).replaceAll('=', '')}';
const _link = 'trojan://pw@h.example:443#FromLink';
const _json = '{"type":"trojan","tag":"FromJson","server":"h.example",'
    '"server_port":443,"password":"p"}';

final _sources = <String, (String, SourceDialect)>{
  'vpn://': (_vpn, SourceDialect.uri),
  'ссылка': (_link, SourceDialect.uri),
  'sing-box JSON': (_json, SourceDialect.singbox),
  '.conf': (_ini, SourceDialect.wgIni),
};

void main() {
  setUpAll(() async {
    await ContractRegistry.I.loadFromDirectory('assets/contract');
    await MapperSections.I
        .loadDrafts(dir: 'assets/contract_draft', files: kDraftFiles);
  });

  for (final MapEntry(key: label, value: (raw, dialect)) in _sources.entries) {
    group(label, () {
      Map<String, dynamic> record(String? tag) => {
            'kind': 'server',
            'id': 'id-1',
            'tag': ?tag,
            'enabled': true,
            'origin': {'kind': dialect.code, 'raw': raw},
          };

      test('чтение записи: имя — tag, origin не меняется', () {
        final server =
            sourceFromRecord(record('Мой узел')).value! as UserServer;
        expect(server.nodes.single.tag, 'Мой узел');
        expect(server.rawBody, raw);
        final back = sourceToRecord(server);
        expect(back['tag'], 'Мой узел');
        expect((back['origin'] as Map)['raw'], raw);
      });

      test('Save без изменений и с переименованием не меняет текст', () {
        for (final touched in [false, true]) {
          final prep = prepareNodeDocumentForSave(raw, 'New', 
              tagTouched: touched) as NodeDocumentReady;
          expect(prep.text, raw.trim());
          expect(prep.nameHint, touched ? 'New' : null);
        }
        expect(nameWrittenByEdit(raw, raw), isNull);
        final member =
            FolderMember(raw: raw.trim(), dialect: dialect, nameHint: 'New');
        expect(member.node!.tag, 'New');
        expect(member.node!.label, 'New');
      });
    });
  }

  test('имя, изменённое в тексте, переходит в запись', () {
    expect(nameWrittenByEdit(_link, 'trojan://pw@h.example:443#Другое'),
        'Другое');
    expect(
        nameWrittenByEdit(_json, _json.replaceFirst('FromJson', 'Y')), 'Y');
    expect(nameWrittenByEdit(_link, 'trojan://pw@h.example:443'), isNull);
  });

  test('дословное тело sing-box получает имя узла', () {
    final member = FolderMember(
        raw: _json, dialect: SourceDialect.singbox, nameHint: 'Мой узел');
    expect(verbatimBodyOf(SourceDialect.singbox, member.node!)!['tag'],
        'Мой узел');
  });
}
