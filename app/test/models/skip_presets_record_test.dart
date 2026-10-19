import 'package:flutter_test/flutter_test.dart';
import 'package:lxbox/models/codec/source_record.dart';
import 'package:lxbox/models/server_list.dart';
import 'package:lxbox/services/lx_backup_slice.dart';

import '../parser/engine_test_setup.dart';

/// §578/§656 — поле записи `skip_tailscale_presets` (бывший `skip_presets`)
/// и поля `allow_*`: своё значение у сервера и члена папки, хранится только
/// `true`, едет в резервной копии; старый ключ читается терпимо.
void main() {
  setUpAll(loadEngineSections);

  const raw = 'vless://11111111-1111-1111-1111-111111111111@1.2.3.4:443'
      '?security=none#v1';

  UserServer server({bool skip = false}) => UserServer(
        id: 's1',
        name: '',
        enabled: true,
        tagPrefix: '',
        detourPolicy: DetourPolicy.defaults,
        rawBody: raw,
        skipTailscalePresets: skip,
      );

  FolderServers folder({bool skip = false}) => FolderServers(
        id: 'f1',
        name: 'F',
        enabled: true,
        tagPrefix: '',
        detourPolicy: DetourPolicy.defaults,
        members: [FolderMember(raw: raw, skipTailscalePresets: skip)],
      );

  test('сервер: true пишется и читается', () {
    final rec = sourceToRecord(server(skip: true));
    expect(rec['skip_tailscale_presets'], true);
    final back = sourceFromRecord(rec).value as UserServer;
    expect(back.skipTailscalePresets, isTrue);
    expect(back, server(skip: true));
  });

  test('сервер: false не пишется, отсутствие читается как false', () {
    final rec = sourceToRecord(server());
    expect(rec.containsKey('skip_tailscale_presets'), isFalse);
    expect((sourceFromRecord(rec).value as UserServer).skipTailscalePresets, isFalse);
  });

  test('член папки: true пишется и читается, false не пишется', () {
    final on = sourceToRecord(folder(skip: true));
    final member = (on['nodes'] as List).single as Map<String, dynamic>;
    expect(member['skip_tailscale_presets'], true);
    final back = sourceFromRecord(on).value as FolderServers;
    expect(back.members.single.skipTailscalePresets, isTrue);

    final off = sourceToRecord(folder());
    expect(((off['nodes'] as List).single as Map).containsKey('skip_tailscale_presets'),
        isFalse);
  });

  test('поле не даёт предупреждения о неизвестном ключе', () {
    final notes = <String>[];
    sourceFromRecord(sourceToRecord(server(skip: true)), notes: notes);
    expect(notes.where((n) => n.contains('skip_tailscale_presets')), isEmpty);
  });

  test('резервная копия: поле едет в файл и не снимается на импорте', () {
    final rec = sourceToRecord(server(skip: true));
    final sliced = sliceBackupRecord(BackupRecord.server, rec);
    expect(sliced.record?['skip_tailscale_presets'], true);
    expect(sliced.dropped, isNot(contains('skip_tailscale_presets')));
    expect(
        stripUndeclaredBackupFields(BackupRecord.server, rec)['skip_tailscale_presets'],
        true);

    final f = sourceToRecord(folder(skip: true));
    final fs = sliceBackupRecord(BackupRecord.folder, f);
    final member = (fs.record?['nodes'] as List).single as Map;
    expect(member['skip_tailscale_presets'], true);
    final m = (f['nodes'] as List).single as Map<String, dynamic>;
    expect(stripUndeclaredBackupFields(BackupRecord.folderNode, m)['skip_tailscale_presets'],
        true);
  });

  // §656 (контракт 1.1.126) — терпимое чтение старого ключа: `skip_presets`
  // читается как новый; оба ключа — true, если хоть один true; пишется только
  // новый.
  group('терпимое чтение skip_presets', () {
    test('сервер: старый ключ читается, пишется новый', () {
      final rec = sourceToRecord(server())..['skip_presets'] = true;
      final back = sourceFromRecord(rec).value as UserServer;
      expect(back.skipTailscalePresets, isTrue);
      final again = sourceToRecord(back);
      expect(again['skip_tailscale_presets'], true);
      expect(again.containsKey('skip_presets'), isFalse);
    });

    test('оба ключа: true, если хоть один true', () {
      final rec = sourceToRecord(server())
        ..['skip_presets'] = false
        ..['skip_tailscale_presets'] = true;
      expect((sourceFromRecord(rec).value as UserServer).skipTailscalePresets,
          isTrue);
      final rec2 = sourceToRecord(server())
        ..['skip_presets'] = true
        ..['skip_tailscale_presets'] = false;
      expect((sourceFromRecord(rec2).value as UserServer).skipTailscalePresets,
          isTrue);
    });

    test('член папки: старый ключ читается без предупреждения', () {
      final rec = sourceToRecord(folder());
      ((rec['nodes'] as List).single as Map)['skip_presets'] = true;
      final notes = <String>[];
      final back = sourceFromRecord(rec, notes: notes).value as FolderServers;
      expect(back.members.single.skipTailscalePresets, isTrue);
      expect(notes, isEmpty);
    });
  });

  test('allow_*: только true пишется и читается', () {
    final u = server().copyWith(allowLocal: true, allowGateway: true);
    final rec = sourceToRecord(u);
    expect(rec['allow_local'], true);
    expect(rec.containsKey('allow_lan'), isFalse);
    expect(rec['allow_gateway'], true);
    expect(sourceFromRecord(rec).value, u);

    final f = FolderServers(
      id: 'f1',
      name: 'F',
      enabled: true,
      tagPrefix: '',
      detourPolicy: DetourPolicy.defaults,
      members: [FolderMember(raw: raw, allowLan: true)],
    );
    final frec = sourceToRecord(f);
    final m = (frec['nodes'] as List).single as Map;
    expect(m['allow_lan'], true);
    expect(m.containsKey('allow_local'), isFalse);
    expect((sourceFromRecord(frec).value as FolderServers).members.single,
        f.members.single);
  });
}
