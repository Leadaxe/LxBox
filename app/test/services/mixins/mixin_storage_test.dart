import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lxbox/models/mixin.dart';
import 'package:lxbox/services/backup_merge.dart';
import 'package:lxbox/services/settings_storage.dart';

/// §704 §1 — ключ `mixins` хранилища: roundtrip, config-dirty, allowlist,
/// слияние бэкапа (совпадение по id или телу).
void main() {
  late Directory tmp;
  const channel = MethodChannel('plugins.flutter.io/path_provider');

  setUp(() async {
    TestWidgetsFlutterBinding.ensureInitialized();
    tmp = await Directory.systemTemp.createTemp('lxbox_mixins_');
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async => tmp.path);
    SettingsStorage.resetCacheForTesting();
  });

  tearDown(() async {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null);
    try {
      if (tmp.existsSync()) await tmp.delete(recursive: true);
    } on FileSystemException {
      /* ignore */
    }
  });

  final a = Mixin(
    id: 'a',
    name: 'DNS listener',
    target: 'inbounds',
    op: 'append',
    value: {'type': 'direct', 'tag': 'dns-in'},
  );
  final b = Mixin(
    id: 'b',
    enabled: false,
    target: 'log.level',
    op: 'set',
    value: null,
  );

  test('roundtrip через диск, порядок и поля', () async {
    expect(await SettingsStorage.getMixins(), isEmpty);
    await SettingsStorage.setMixins([a, b]);
    SettingsStorage.resetCacheForTesting();
    final got = await SettingsStorage.getMixins();
    expect([for (final m in got) m.toJson()], [a.toJson(), b.toJson()]);
    expect(got[1].enabled, isFalse);
    expect(got[1].toJson().containsKey('value'), isTrue);
    expect(got[1].displayName, 'log.level → set');
  });

  test('запись поднимает configDirty', () async {
    SettingsStorage.configDirty = false;
    final gen = SettingsStorage.configDirtyGeneration;
    await SettingsStorage.setMixins([a]);
    expect(SettingsStorage.configDirty, isTrue);
    expect(SettingsStorage.configDirtyGeneration, greaterThan(gen));
    await SettingsStorage.setMixins(const []);
    expect((await SettingsStorage.exportRaw()).containsKey('mixins'), isFalse);
  });

  test('replaceRaw пропускает ключ mixins (allowlist)', () async {
    final dropped = await SettingsStorage.replaceRaw({
      'mixins': [a.toJson()],
    });
    expect(dropped, isNot(contains('mixins')));
    expect((await SettingsStorage.getMixins()).single.id, 'a');
  });

  test('fromJson терпимый: без id — новый, битые поля — дефолты', () {
    final m = Mixin.fromJson({'target': 1, 'op': 'merge', 'enabled': 'x'});
    expect(m.id, isNotEmpty);
    expect(m.target, '');
    expect(m.enabled, isTrue);
    expect(m.opKind, MixinOp.merge);
    expect(Mixin.fromJson({'op': 'patch'}).opKind, isNull);
    expect(a.toBackupJson().containsKey('id'), isFalse);
  });

  test('слияние бэкапа: тот же id или то же тело — пропуск', () {
    final mine = <String, dynamic>{
      'mixins': [a.toJson()],
    };
    final stats = mergeStorageDoc(mine, {
      'mixins': [
        a.toJson(),
        a.copyWith(id: 'other', name: 'renamed', enabled: false).toJson(),
        b.toJson(),
      ],
    });
    expect([for (final m in mine['mixins'] as List) m['id']], ['a', 'b']);
    expect(stats.mixins.added, 1);
    expect(stats.mixins.kept, 2);
    final empty = <String, dynamic>{};
    final s2 = mergeStorageDoc(empty, {
      'mixins': [a.toJson()],
    });
    expect(s2.mixins.added, 1);
  });
}
