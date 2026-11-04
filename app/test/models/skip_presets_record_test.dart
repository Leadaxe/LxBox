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

  const raw =
      'vless://11111111-1111-1111-1111-111111111111@1.2.3.4:443'
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
    expect(
      (sourceFromRecord(rec).value as UserServer).skipTailscalePresets,
      isFalse,
    );
  });

  test('член папки: true пишется и читается, false не пишется', () {
    final on = sourceToRecord(folder(skip: true));
    final member = (on['nodes'] as List).single as Map<String, dynamic>;
    expect(member['skip_tailscale_presets'], true);
    final back = sourceFromRecord(on).value as FolderServers;
    expect(back.members.single.skipTailscalePresets, isTrue);

    final off = sourceToRecord(folder());
    expect(
      ((off['nodes'] as List).single as Map).containsKey(
        'skip_tailscale_presets',
      ),
      isFalse,
    );
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
      stripUndeclaredBackupFields(
        BackupRecord.server,
        rec,
      )['skip_tailscale_presets'],
      true,
    );

    final f = sourceToRecord(folder(skip: true));
    final fs = sliceBackupRecord(BackupRecord.folder, f);
    final member = (fs.record?['nodes'] as List).single as Map;
    expect(member['skip_tailscale_presets'], true);
    final m = (f['nodes'] as List).single as Map<String, dynamic>;
    expect(
      stripUndeclaredBackupFields(
        BackupRecord.folderNode,
        m,
      )['skip_tailscale_presets'],
      true,
    );
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
      expect(
        (sourceFromRecord(rec).value as UserServer).skipTailscalePresets,
        isTrue,
      );
      final rec2 = sourceToRecord(server())
        ..['skip_presets'] = true
        ..['skip_tailscale_presets'] = false;
      expect(
        (sourceFromRecord(rec2).value as UserServer).skipTailscalePresets,
        isTrue,
      );
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
    expect(
      (sourceFromRecord(frec).value as FolderServers).members.single,
      f.members.single,
    );
  });

  // §707 итер. 9 (контракт 1.1.159) — поля Taildrop узла, знак «выключено»:
  // те же правила, что у allow_*.
  group('disable_taildrop_commands / disable_taildrop_autosave', () {
    test('сервер: true пишется и читается, false не пишется', () {
      final u = server().copyWith(
        disableTaildropCommands: true,
        disableTaildropAutosave: true,
      );
      final rec = sourceToRecord(u);
      expect(rec['disable_taildrop_commands'], true);
      expect(rec['disable_taildrop_autosave'], true);
      expect(sourceFromRecord(rec).value, u);

      final off = sourceToRecord(server());
      expect(off.containsKey('disable_taildrop_commands'), isFalse);
      expect(off.containsKey('disable_taildrop_autosave'), isFalse);
      final back = sourceFromRecord(off).value as UserServer;
      expect(back.disableTaildropCommands, isFalse);
      expect(back.disableTaildropAutosave, isFalse);
    });

    test('член папки: true пишется и читается, без предупреждений', () {
      final f = FolderServers(
        id: 'f1',
        name: 'F',
        enabled: true,
        tagPrefix: '',
        detourPolicy: DetourPolicy.defaults,
        members: [FolderMember(raw: raw, disableTaildropAutosave: true)],
      );
      final frec = sourceToRecord(f);
      final m = (frec['nodes'] as List).single as Map;
      expect(m['disable_taildrop_autosave'], true);
      expect(m.containsKey('disable_taildrop_commands'), isFalse);
      final notes = <String>[];
      final back = sourceFromRecord(frec, notes: notes).value as FolderServers;
      expect(back.members.single, f.members.single);
      expect(notes, isEmpty);
    });

    test('терпимое чтение: не bool — как отсутствие', () {
      final rec = sourceToRecord(server())
        ..['disable_taildrop_commands'] = 'yes'
        ..['disable_taildrop_autosave'] = 1;
      final back = sourceFromRecord(rec).value as UserServer;
      expect(back.disableTaildropCommands, isFalse);
      expect(back.disableTaildropAutosave, isFalse);
    });

    test('имена 1.1.157 не читаются: неизвестные ключи, поля по умолчанию', () {
      final rec = sourceToRecord(server())
        ..['taildrop_commands'] = true
        ..['taildrop_autosave'] = true;
      final read = sourceFromRecord(rec);
      final back = read.value as UserServer;
      expect(back.disableTaildropCommands, isFalse);
      expect(back.disableTaildropAutosave, isFalse);
      expect(
        read.unknownKeys,
        containsAll(['taildrop_autosave', 'taildrop_commands']),
      );
    });

    test('резервная копия: поля едут и не снимаются на импорте', () {
      final rec = sourceToRecord(
        server().copyWith(
          disableTaildropCommands: true,
          disableTaildropAutosave: true,
        ),
      );
      final sliced = sliceBackupRecord(BackupRecord.server, rec);
      expect(sliced.record?['disable_taildrop_commands'], true);
      expect(sliced.record?['disable_taildrop_autosave'], true);
      final kept = stripUndeclaredBackupFields(BackupRecord.server, rec);
      expect(kept['disable_taildrop_commands'], true);
      expect(kept['disable_taildrop_autosave'], true);
    });

    test('поля в конфиг не идут: inConfig = false', () {
      expect(NodeRecordFlag.disableTaildropCommands.inConfig, isFalse);
      expect(NodeRecordFlag.disableTaildropAutosave.inConfig, isFalse);
      expect(NodeRecordFlag.allowLan.inConfig, isTrue);
    });
  });

  // §707 (контракт 1.1.160) — `state_dir_id` только переносится,
  // `taildrop_double_copy` известен и молча пропускается.
  group('state_dir_id / taildrop_double_copy', () {
    test('сервер: state_dir_id пишется и читается как есть', () {
      final u = server().copyWith(stateDirId: 'ts-ab12cd');
      final rec = sourceToRecord(u);
      expect(rec['state_dir_id'], 'ts-ab12cd');
      expect(sourceFromRecord(rec).value, u);
    });

    test('пустое и не строка не пишутся и читаются как отсутствие', () {
      expect(sourceToRecord(server()).containsKey('state_dir_id'), isFalse);
      for (final v in <Object>['', 5, true]) {
        final rec = sourceToRecord(server())..['state_dir_id'] = v;
        final back = sourceFromRecord(rec).value as UserServer;
        expect(back.stateDirId, '');
        expect(sourceToRecord(back).containsKey('state_dir_id'), isFalse);
      }
    });

    test('член папки: state_dir_id пишется и читается', () {
      final f = FolderServers(
        id: 'f1',
        name: 'F',
        enabled: true,
        tagPrefix: '',
        detourPolicy: DetourPolicy.defaults,
        members: [FolderMember(raw: raw, stateDirId: 'home')],
      );
      final frec = sourceToRecord(f);
      final m = (frec['nodes'] as List).single as Map;
      expect(m['state_dir_id'], 'home');
      final back = sourceFromRecord(frec).value as FolderServers;
      expect(back.members.single, f.members.single);
    });

    test('taildrop_double_copy: известен, не провозится', () {
      final rec = sourceToRecord(server())
        ..['taildrop_double_copy'] = {'peer_id': 'n1', 'peer_name': 'pc'};
      final read = sourceFromRecord(rec);
      expect(read.unknownKeys, isNot(contains('taildrop_double_copy')));
      expect(
        sourceToRecord(read.value!).containsKey('taildrop_double_copy'),
        isFalse,
      );

      final f = FolderServers(
        id: 'f1',
        name: 'F',
        enabled: true,
        tagPrefix: '',
        detourPolicy: DetourPolicy.defaults,
        members: [FolderMember(raw: raw)],
      );
      final frec = sourceToRecord(f);
      ((frec['nodes'] as List).single as Map)['taildrop_double_copy'] = {
        'peer_id': 'n1',
      };
      final fread = sourceFromRecord(frec);
      expect(fread.unknownKeys, isNot(contains('taildrop_double_copy')));
      final m = (sourceToRecord(fread.value!)['nodes'] as List).single as Map;
      expect(m.containsKey('taildrop_double_copy'), isFalse);
    });

    test('резервная копия: state_dir_id едет', () {
      final rec = sourceToRecord(server().copyWith(stateDirId: 'ts-000001'));
      final sliced = sliceBackupRecord(BackupRecord.server, rec);
      expect(sliced.record?['state_dir_id'], 'ts-000001');
    });
  });
}
