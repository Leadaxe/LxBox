import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:lxbox/models/server_list.dart';
import 'package:lxbox/services/lx_backup.dart';

import '../parser/engine_test_setup.dart';

// §656 (контракт 1.1.126, BACKUP.md) — поля записи узла в LX Backup:
// `skip_tailscale_presets` (старый `skip_presets` читается терпимо),
// `allow_local`, `allow_lan`, `allow_gateway`. Экспорт — только новые ключи и
// только `true`; импорт нового узла — значения файла; совпавший по телу узел —
// слияние «только `true`».

String _file(List<Map<String, dynamic>> sources) => jsonEncode({
  'lx_backup': 2,
  'exported_by': {'app': 'launcher', 'version': 'test'},
  'exported_at': '2026-10-16T00:00:00Z',
  'sources': sources,
});

const _wgBody = {
  'type': 'wireguard',
  'address': ['10.8.0.2/32'],
  'private_key': 'k',
  'peers': [
    {
      'address': '203.0.113.1',
      'port': 51820,
      'public_key': 'p',
      'allowed_ips': ['0.0.0.0/0'],
    },
  ],
};

Map<String, dynamic> _node(String tag, Map<String, Object> flags) => {
  'kind': 'server',
  'tag': tag,
  'enabled': true,
  'body': {..._wgBody, 'private_key': 'k-$tag'},
  ...flags,
};

List<ServerList> _apply(List<ServerList> lists, LxBackupFile file) =>
    mergeBackupServers(lists, file.servers, folders: file.folders).lists;

void main() {
  setUpAll(loadEngineSections);

  group('импорт: чтение полей', () {
    test('свой сервер: skip_presets читается как skip_tailscale_presets', () {
      final file = parseLxBackup(
        _file([
          _node('a', {'skip_presets': true}),
          _node('b', {'skip_presets': false, 'skip_tailscale_presets': true}),
          _node('c', {
            'allow_local': true,
            'allow_lan': true,
            'allow_gateway': true,
          }),
        ]),
      );
      final byTag = {for (final s in file.servers) s.name: s};
      expect(byTag['a']!.skipTailscalePresets, isTrue);
      expect(byTag['b']!.skipTailscalePresets, isTrue);
      final c = byTag['c']!;
      expect(
        [c.skipTailscalePresets, c.allowLocal, c.allowLan, c.allowGateway],
        [false, true, true, true],
      );
      expect(
        file.warnings.where(
          (w) =>
              w.detail.contains('skip_presets') || w.detail.contains('allow_'),
        ),
        isEmpty,
        reason: 'ключи объявлены — без backup_unknown_field',
      );
    });

    test('новый узел получает все четыре поля из файла', () {
      final lists = _apply(
        const [],
        parseLxBackup(
          _file([
            _node('a', {'skip_presets': true, 'allow_gateway': true}),
          ]),
        ),
      );
      final u = lists.single as UserServer;
      expect(u.skipTailscalePresets, isTrue);
      expect(u.allowGateway, isTrue);
      expect(u.allowLocal, isFalse);
      expect(u.allowLan, isFalse);
    });

    test('член папки: поля из файла, старый ключ терпимо', () {
      final lists = _apply(
        const [],
        parseLxBackup(
          _file([
            {
              'kind': 'folder',
              'id': 'f1',
              'name': 'F',
              'nodes': [
                _node('m', {'skip_presets': true, 'allow_lan': true}),
              ],
            },
          ]),
        ),
      );
      final m = (lists.single as FolderServers).members.single;
      expect(m.skipTailscalePresets, isTrue);
      expect(m.allowLan, isTrue);
      expect(m.allowLocal, isFalse);
      expect(m.allowGateway, isFalse);
    });
  });

  group('импорт: совпавший по телу узел — только true', () {
    test('свой сервер: true из файла ставится, своё true не сбрасывается', () {
      final first = _apply(
        const [],
        parseLxBackup(
          _file([
            _node('a', {'allow_local': true, 'skip_tailscale_presets': true}),
          ]),
        ),
      );
      final second = _apply(
        first,
        parseLxBackup(
          _file([
            _node('a', {'allow_lan': true, 'allow_gateway': true}),
          ]),
        ),
      );
      expect(second, hasLength(1), reason: 'совпал по телу — не дублируется');
      final u = second.single as UserServer;
      expect(
        [u.skipTailscalePresets, u.allowLocal, u.allowLan, u.allowGateway],
        [true, true, true, true],
      );

      final third = _apply(second, parseLxBackup(_file([_node('a', {})])));
      final v = third.single as UserServer;
      expect(
        [v.skipTailscalePresets, v.allowLocal, v.allowLan, v.allowGateway],
        [true, true, true, true],
        reason: 'отсутствие полей в файле своё true не сбрасывает',
      );
    });

    test('член папки: слияние в пределах папки', () {
      Map<String, dynamic> folder(Map<String, Object> flags) => {
        'kind': 'folder',
        'id': 'f1',
        'name': 'F',
        'nodes': [_node('m', flags)],
      };
      final first = _apply(
        const [],
        parseLxBackup(
          _file([
            folder({'allow_gateway': true}),
          ]),
        ),
      );
      final second = _apply(
        first,
        parseLxBackup(
          _file([
            folder({'skip_presets': true}),
          ]),
        ),
      );
      final m = (second.single as FolderServers).members.single;
      expect(m.allowGateway, isTrue);
      expect(m.skipTailscalePresets, isTrue);
      final third = _apply(second, parseLxBackup(_file([folder({})])));
      final n = (third.single as FolderServers).members.single;
      expect([n.skipTailscalePresets, n.allowGateway], [true, true]);
    });
  });

  test('экспорт: только новые ключи и только true', () async {
    const raw =
        '[Interface]\nPrivateKey = '
        'yAnz5TF+lXXJte14tji3zlMNq+hd2rYUIgJBgB3fBmk=\n'
        'Address = 10.8.0.2/32\n\n[Peer]\n'
        'PublicKey = xTIBA5rboUvnH4htodjb6e697QjLERt1NAB4mZqp8Dg=\n'
        'Endpoint = 203.0.113.1:51820\nAllowedIPs = 0.0.0.0/0\n';
    final out = await buildLxBackup(
      lists: [
        UserServer(
          id: 's1',
          name: '',
          enabled: true,
          tagPrefix: '',
          detourPolicy: DetourPolicy.defaults,
          rawBody: raw,
          skipTailscalePresets: true,
          allowLan: true,
        ),
        FolderServers(
          id: 'f1',
          name: 'F',
          enabled: true,
          tagPrefix: '',
          detourPolicy: DetourPolicy.defaults,
          members: [FolderMember(raw: raw, allowGateway: true)],
        ),
      ],
      rules: const [],
      vars: const {},
    );
    final sources = ((jsonDecode(out.json) as Map)['sources'] as List)
        .cast<Map>();
    final server = sources.firstWhere((s) => s['kind'] == 'server');
    expect(server['skip_tailscale_presets'], true);
    expect(server['allow_lan'], true);
    expect(server.containsKey('skip_presets'), isFalse);
    expect(server.containsKey('allow_local'), isFalse);
    expect(server.containsKey('allow_gateway'), isFalse);
    final member =
        ((sources.firstWhere((s) => s['kind'] == 'folder')['nodes']) as List)
                .single
            as Map;
    expect(member['allow_gateway'], true);
    for (final k in [
      'skip_presets',
      'skip_tailscale_presets',
      'allow_local',
      'allow_lan',
    ]) {
      expect(member.containsKey(k), isFalse, reason: k);
    }
  });
}
