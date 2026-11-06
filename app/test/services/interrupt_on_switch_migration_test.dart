import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:lxbox/services/settings_storage.dart';

/// §143 §9 — снятый тумблер `interrupt_connections_on_switch` переносится в
/// галки Направлений: `true` включает `interrupt_exist_connections` там, где
/// она снята; ключ удаляется при любом значении; без ключа — no-op.
void main() {
  late Directory tmp;
  const channel = MethodChannel('plugins.flutter.io/path_provider');

  setUp(() async {
    TestWidgetsFlutterBinding.ensureInitialized();
    tmp = await Directory.systemTemp.createTemp('lxbox_interrupt_migr_');
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
      if (call.method == 'getApplicationDocumentsDirectory' ||
          call.method == 'getApplicationDocumentsPath') {
        return tmp.path;
      }
      return null;
    });
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

  Map<String, dynamic> doc({Object? toggle = _absent}) => {
        'storage_version': 1,
        'interrupt_connections_on_switch': ?(toggle == _absent ? null : toggle),
        'directions': [
          {'tag': 'vpn-1', 'interrupt_exist_connections': false},
          {'tag': 'vpn-2', 'interrupt_exist_connections': true},
          {'tag': 'vpn-3'}, // без ключа — дефолт true
        ],
      };

  Future<Map<String, dynamic>> run(Map<String, dynamic> d) async {
    File('${tmp.path}/lxbox_settings.json').writeAsStringSync(jsonEncode(d));
    SettingsStorage.resetCacheForTesting();
    await SettingsStorage.migrateInterruptOnSwitchIfNeeded();
    SettingsStorage.resetCacheForTesting();
    return SettingsStorage.exportRaw();
  }

  List<Object?> flags(Map<String, dynamic> d) => [
        for (final c in d['directions'] as List)
          (c as Map)['interrupt_exist_connections'],
      ];

  test('тумблер true → снятые галки Направлений включены, ключ снят',
      () async {
    final out = await run(doc(toggle: true));
    expect(flags(out), [true, true, null]);
    expect(out.containsKey('interrupt_connections_on_switch'), isFalse);
  });

  test('тумблер false → галки не меняются, ключ снят', () async {
    final out = await run(doc(toggle: false));
    expect(flags(out), [false, true, null]);
    expect(out.containsKey('interrupt_connections_on_switch'), isFalse);
  });

  test('ключа нет → no-op', () async {
    final out = await run(doc());
    expect(flags(out), [false, true, null]);
  });
}

const Object _absent = _Absent();

class _Absent {
  const _Absent();
}
