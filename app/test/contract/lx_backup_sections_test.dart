import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:lxbox/models/node_sections.dart';
import 'package:lxbox/models/server_list.dart';
import 'package:lxbox/services/lx_backup.dart';

/// §435 — `servers[].sections` в бэкапе 0.12 игнорируется МОЛЧА. §575
/// (контракт 1.1.85) — секции узла упразднены: экспорт 1.0 их не пишет ни у
/// одной записи, импорт снимает с `backup_section_record_dropped`.
void main() {
  group('§435 импорт 0.12 с sections', () {
    test('sections у servers[] не даёт backup_unknown_field, узел читается', () {
      final raw = jsonEncode({
        'lx_backup': 1,
        'exported_by': {'app': 'launcher', 'version': '0'},
        'servers': [
          {
            'node_tag': 'home-ts',
            'config_json': {'type': 'tailscale', 'auth_key': 'k'},
            'sections': {
              'rules': [
                {'kind': 'inline', 'name': 'x', 'enabled': true, 'num': 945, 'outbound': '@self',
                 'match': {'ip_cidr': ['100.64.0.0/10']}},
              ],
              'dns': {'servers': [], 'rules': []},
            },
          },
        ],
      });
      final file = parseLxBackup(raw);
      expect(file.warnings.map((w) => w.code), isNot(contains(kWarnUnknownField)));
      expect(file.servers, hasLength(1));
      expect(file.servers.single.name, 'home-ts');
    });
  });

  group('§575 экспорт 1.0: секции не пишутся', () {
    UserServer user({NodeSections? sections}) => UserServer(
          id: 'u1',
          name: 'home-ts',
          enabled: true,
          tagPrefix: '',
          detourPolicy: DetourPolicy.defaults,
          origin: UserSource.manual,
          rawBody: '{"type":"tailscale","tag":"home-ts","auth_key":"k"}',
          sections: sections,
        );

    final sections = NodeSections.fromJson({
      'rules': [
        {'kind': 'inline', 'name': '@{self} network', 'body': {'ip_cidr': ['100.64.0.0/10'], 'outbound': '@self'}},
      ],
    });

    List<Map<String, dynamic>> sourcesOf(String raw) =>
        ((jsonDecode(raw) as Map)['sources'] as List).cast<Map<String, dynamic>>();

    test('узел с секциями: поля нет, потерей не названо', () async {
      expect(sections, isNotNull);
      final out = await buildLxBackup(lists: [user(sections: sections)], rules: const [], vars: const {});
      final server = sourcesOf(out.json).single;
      expect(server['tag'], 'home-ts');
      expect(server.containsKey('sections'), isFalse);
      expect(out.warnings, isEmpty);
    });

    test('узел без секций — поля нет', () async {
      final out = await buildLxBackup(lists: [user()], rules: const [], vars: const {});
      expect(sourcesOf(out.json).single.containsKey('sections'), isFalse);
      expect(out.warnings, isEmpty);
    });

    test('член папки с секциями: поля нет', () async {
      final folder = FolderServers(
        id: 'f',
        name: 'F',
        enabled: true,
        tagPrefix: '',
        detourPolicy: DetourPolicy.defaults,
        members: [
          FolderMember(raw: '{"type":"tailscale","tag":"a","auth_key":"k"}', sections: sections),
          FolderMember(raw: '{"type":"tailscale","tag":"b","auth_key":"k"}'),
        ],
      );
      final out = await buildLxBackup(lists: [folder], rules: const [], vars: const {});
      final nodes = (sourcesOf(out.json).single['nodes'] as List).cast<Map<String, dynamic>>();
      expect(nodes.map((n) => n['tag']), ['a', 'b']);
      expect(nodes[0].containsKey('sections'), isFalse);
      expect(nodes[1].containsKey('sections'), isFalse);
      expect(out.warnings, isEmpty);
    });
  });
  group('§575 импорт 1.0: секции сняты', () {
    test('свой сервер с секциями: узел на месте, предупреждение not_allowed',
        () {
      final raw = jsonEncode({
        'lx_backup': 2,
        'exported_by': {'app': 'launcher', 'version': '0'},
        'sources': [
          {
            'kind': 'server',
            'tag': 'home-ts',
            'enabled': true,
            'origin': {
              'kind': 'json',
              'raw': '{"type":"tailscale","tag":"home-ts","auth_key":"k"}',
            },
            'sections': {
              'rules': [
                {'kind': 'inline', 'name': 'n', 'enabled': true,
                 'body': {'ip_cidr': ['100.64.0.0/10']}},
              ],
            },
          },
        ],
      });
      final file = parseLxBackup(raw);
      final w = file.warnings.single;
      expect(w.code, kWarnSectionRecordDropped);
      expect(w.reason, kSectionDropReasonNotAllowed);
      expect(w.kind, 'server');
      expect(file.servers.single.name, 'home-ts');
      final merged = mergeBackupServers(const [], file.servers).lists;
      final server = merged.single as UserServer;
      expect(server.rawBody, contains('"auth_key":"k"'));
      expect(server.sections, isNull);
    });
  });
}
