import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:lxbox/models/auto_select.dart';
import 'package:lxbox/models/node_link.dart';
import 'package:lxbox/models/node_spec.dart';
import 'package:lxbox/models/server_list.dart';
import 'package:lxbox/services/lx_backup.dart';

// §439 N2 — член папки `autogroup://…` в LX Backup 0.x (`lx_backup: 1`).
// Разбор текста снят, и до правки такой член ложился `kind: unsupported`
// рядом с группой того же тега (проверка на AVD: папка «E439 Folder», член
// «EF Auto»). Импорт переводит его тем же путём, что миграция хранения:
// ключи состава → члены той же папки файла, группа ключуется тегом.

const _alpha = 'vless://c3c3c3c3-0000-4000-8000-000000000070@198.51.100.70:443'
    '?encryption=none&security=tls&sni=alpha.e439.example&type=grpc'
    '&serviceName=g#Alpha';
const _jump = 'trojan://e439-jump-pass-71@198.51.100.71:443'
    '?security=tls&sni=jump.e439.example#Jump';
const _broken = 'foo://e439-unreadable@192.0.2.99:1?x=1#Broken';
const _auto = 'autogroup://?members='
    'vless%7C198.51.100.70%7C443%7Cc3c3c3c3-0000-4000-8000-000000000070'
    '%2Ctrojan%7C198.51.100.71%7C443%7Ce439-jump-pass-71'
    '&interval=3m&tolerance=80#EF%20Auto';

String _file(List<Map<String, dynamic>> servers) => jsonEncode({
      'lx_backup': 1,
      'exported_by': {'app': 'lxbox', 'version': '2.23.2'},
      'exported_at': '2026-09-15T00:00:00Z',
      'servers': servers,
    });

Map<String, dynamic> _member(String uri, String tag, {bool enabled = true}) => {
      'uri': uri,
      'node_tag': tag,
      if (!enabled) 'enabled': false,
      'folder': 'E439 Folder',
    };

final _stand = [
  _member(_alpha, 'Alpha'),
  _member(_jump, 'Jump'),
  {'uri': _broken, 'folder': 'E439 Folder'},
  _member(_auto, 'EF Auto'),
];

({LxBackupFile file, List<ServerList> lists}) _import(
  String raw, {
  List<ServerList> lists = const [],
}) {
  final file = parseLxBackup(raw);
  final subs = mergeBackupSubscriptions(lists, file.subscriptions);
  final servers = mergeBackupServers(
    subs.lists,
    file.servers,
    folders: file.folders,
    sourceIds: subs.ids,
    addedSources: subs.added,
    sourceDetours: subs.detours,
  );
  return (file: file, lists: servers.lists);
}

void main() {
  test('autogroup:// папки 0.x ввозится группой, ключи — пары на члены папки',
      () {
    final got = _import(_file(_stand));
    expect(got.file.warnings, isEmpty);
    final folder = got.lists.whereType<FolderServers>().single;
    expect(folder.name, 'E439 Folder');
    expect([for (final m in folder.members) m.node?.tag],
        ['Alpha', 'Jump', null, 'EF Auto']);
    expect(folder.members[2].raw, _broken, reason: 'нечитаемый член — как был');
    final group = folder.members[3].node as AutoSelectSpec;
    expect((group.membership as ExplicitMembers).members, [
      NodeLink(folderId: folder.id, tag: 'Alpha'),
      NodeLink(folderId: folder.id, tag: 'Jump'),
    ]);
    expect(group.params.interval, '3m');
    expect(group.params.tolerance, 80);
    expect(folder.members.where((m) => m.node == null && m.raw.startsWith('autogroup')),
        isEmpty, reason: 'группа не ложится нечитаемым членом');
  });

  test('повторный импорт того же файла не заводит вторую группу', () {
    final first = _import(_file(_stand)).lists;
    final second = _import(_file(_stand), lists: first).lists;
    final folder = second.whereType<FolderServers>().single;
    expect(folder.members, hasLength(4));
    expect(folder.members.where((m) => m.node is AutoSelectSpec), hasLength(1));
    expect(
        ((folder.members[3].node as AutoSelectSpec).membership as ExplicitMembers)
            .members,
        [
          NodeLink(folderId: folder.id, tag: 'Alpha'),
          NodeLink(folderId: folder.id, tag: 'Jump'),
        ]);
  });

  test('ключ без члена и неоднозначный ключ — член снят с backup_group_degraded',
      () {
    final got = _import(_file([
      _member(_alpha, 'Alpha'),
      _member('${_alpha.substring(0, _alpha.indexOf('#'))}#Alpha copy', 'Alpha copy'),
      _member(_auto, 'EF Auto'),
    ]));
    final folder = got.lists.whereType<FolderServers>().single;
    final group = folder.members.last.node as AutoSelectSpec;
    expect((group.membership as ExplicitMembers).members, isEmpty);
    expect([for (final w in got.file.warnings) '${w.code} ${w.detail}'], [
      '$kWarnGroupDegraded EF Auto',
      '$kWarnGroupDegraded EF Auto',
    ]);
    expect(got.file.warnings.map((w) => w.reason), [
      contains('matches 2 nodes'),
      contains('matches no node'),
    ]);
  });

  test('выключенный тёзка по ключу не мешает: решает включённый', () {
    final got = _import(_file([
      _member(_alpha, 'Alpha'),
      _member('${_alpha.substring(0, _alpha.indexOf('#'))}#Old', 'Old',
          enabled: false),
      _member(_jump, 'Jump'),
      _member(_auto, 'EF Auto'),
    ]));
    expect(got.file.warnings, isEmpty);
    final folder = got.lists.whereType<FolderServers>().single;
    final group = folder.members.last.node as AutoSelectSpec;
    expect((group.membership as ExplicitMembers).members, [
      NodeLink(folderId: folder.id, tag: 'Alpha'),
      NodeLink(folderId: folder.id, tag: 'Jump'),
    ]);
  });
}
