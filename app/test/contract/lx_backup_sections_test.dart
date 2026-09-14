import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:lxbox/models/node_sections.dart';
import 'package:lxbox/models/server_list.dart';
import 'package:lxbox/services/lx_backup.dart';

/// §435 / контракт ## 13 — `servers[].sections` в бэкапе 0.12: объявлено
/// схемой (сторона launcher) → игнорируется МОЛЧА; до контракта 1.0 LxBox
/// секции не экспортирует и называет потерю `backup_local_only_dropped`.
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

  group('§435 экспорт до 1.0', () {
    UserServer user({NodeSections? sections}) => UserServer(
          id: 'u1',
          name: 'home-ts',
          enabled: true,
          tagPrefix: '',
          detourPolicy: DetourPolicy.defaults,
          origin: UserSource.manual,
          createdAt: DateTime.utc(2026, 9, 14),
          rawBody: '{"type":"tailscale","tag":"home-ts","auth_key":"k"}',
          sections: sections,
        );

    final sections = NodeSections.fromJson({
      'rules': [
        {'kind': 'inline', 'name': '@{self} network', 'body': {'ip_cidr': ['100.64.0.0/10'], 'outbound': '@self'}},
      ],
    });

    test('узел с секциями: поле не пишется, потеря названа', () async {
      final out = await buildLxBackup(lists: [user(sections: sections)], rules: const [], vars: const {});
      final servers = ((jsonDecode(out.json) as Map)['servers'] as List).cast<Map<String, dynamic>>();
      expect(servers.single.containsKey('sections'), isFalse);
      expect(servers.single['node_tag'], 'home-ts');
      final local = out.warnings.where((w) => w.code == kWarnLocalOnlyDropped).toList();
      expect(local, hasLength(1));
      expect(local.single.detail, contains('sections'));
    });

    test('узел без секций — тишина', () async {
      final out = await buildLxBackup(lists: [user()], rules: const [], vars: const {});
      expect(out.warnings.where((w) => w.code == kWarnLocalOnlyDropped), isEmpty);
    });

    test('член папки с секциями — одно предупреждение на папку', () async {
      final folder = FolderServers(
        id: 'f',
        name: 'F',
        enabled: true,
        tagPrefix: '',
        detourPolicy: DetourPolicy.defaults,
        members: [
          FolderMember(raw: '{"type":"tailscale","tag":"a","auth_key":"k"}', sections: sections),
          FolderMember(raw: '{"type":"tailscale","tag":"b","auth_key":"k"}', sections: sections),
        ],
      );
      final out = await buildLxBackup(lists: [folder], rules: const [], vars: const {});
      final servers = ((jsonDecode(out.json) as Map)['servers'] as List).cast<Map<String, dynamic>>();
      expect(servers, hasLength(2));
      expect(servers.every((s) => !s.containsKey('sections')), isTrue);
      expect(out.warnings.where((w) => w.code == kWarnLocalOnlyDropped && w.detail.contains('sections')),
          hasLength(1));
    });
  });
}
