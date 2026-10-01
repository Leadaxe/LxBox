import 'package:flutter_test/flutter_test.dart';
import 'package:lxbox/models/codec/source_record.dart';
import 'package:lxbox/models/server_list.dart';
import 'package:lxbox/services/lx_backup_slice.dart';

import '../parser/engine_test_setup.dart';

/// §578 — поле записи `skip_presets`: своё значение у сервера и члена папки,
/// хранится только `true`, едет в резервной копии.
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
        skipPresets: skip,
      );

  FolderServers folder({bool skip = false}) => FolderServers(
        id: 'f1',
        name: 'F',
        enabled: true,
        tagPrefix: '',
        detourPolicy: DetourPolicy.defaults,
        members: [FolderMember(raw: raw, skipPresets: skip)],
      );

  test('сервер: true пишется и читается', () {
    final rec = sourceToRecord(server(skip: true));
    expect(rec['skip_presets'], true);
    final back = sourceFromRecord(rec).value as UserServer;
    expect(back.skipPresets, isTrue);
    expect(back, server(skip: true));
  });

  test('сервер: false не пишется, отсутствие читается как false', () {
    final rec = sourceToRecord(server());
    expect(rec.containsKey('skip_presets'), isFalse);
    expect((sourceFromRecord(rec).value as UserServer).skipPresets, isFalse);
  });

  test('член папки: true пишется и читается, false не пишется', () {
    final on = sourceToRecord(folder(skip: true));
    final member = (on['nodes'] as List).single as Map<String, dynamic>;
    expect(member['skip_presets'], true);
    final back = sourceFromRecord(on).value as FolderServers;
    expect(back.members.single.skipPresets, isTrue);

    final off = sourceToRecord(folder());
    expect(((off['nodes'] as List).single as Map).containsKey('skip_presets'),
        isFalse);
  });

  test('поле не даёт предупреждения о неизвестном ключе', () {
    final notes = <String>[];
    sourceFromRecord(sourceToRecord(server(skip: true)), notes: notes);
    expect(notes.where((n) => n.contains('skip_presets')), isEmpty);
  });

  test('резервная копия: поле едет в файл и не снимается на импорте', () {
    final rec = sourceToRecord(server(skip: true));
    final sliced = sliceBackupRecord(BackupRecord.server, rec);
    expect(sliced.record?['skip_presets'], true);
    expect(sliced.dropped, isNot(contains('skip_presets')));
    expect(
        stripUndeclaredBackupFields(BackupRecord.server, rec)['skip_presets'],
        true);

    final f = sourceToRecord(folder(skip: true));
    final fs = sliceBackupRecord(BackupRecord.folder, f);
    final member = (fs.record?['nodes'] as List).single as Map;
    expect(member['skip_presets'], true);
    final m = (f['nodes'] as List).single as Map<String, dynamic>;
    expect(stripUndeclaredBackupFields(BackupRecord.folderNode, m)['skip_presets'],
        true);
  });
}
