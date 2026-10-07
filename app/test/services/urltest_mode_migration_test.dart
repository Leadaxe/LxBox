import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:lxbox/services/settings_storage.dart';

/// §612 — миграция от `passive_check` (§611) к режиму `failover`: один раз,
/// по сырому ключу `urltest_passive_check` (true/отсутствует → failover,
/// false → без изменений), `round_robin` и ручной род не трогаются.
void main() {
  late Directory tmp;
  const channel = MethodChannel('plugins.flutter.io/path_provider');

  setUp(() async {
    TestWidgetsFlutterBinding.ensureInitialized();
    tmp = await Directory.systemTemp.createTemp('lxbox_urltest_mode_');
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

  Map<String, dynamic> doc({Object? passive = _absent}) => {
        'storage_version': 1,
        'urltest_passive_check': ?(passive == _absent ? null : passive),
        'directions': [
          {
            'tag': 'vpn-1',
            'auto': {'mode': 'least_test', 'tolerance': 50},
          },
          {
            'tag': 'vpn-2',
            'auto': {'tolerance': 50}, // без mode — least_test
          },
          {
            'tag': 'vpn-3',
            'auto': {'mode': 'round_robin'},
          },
          {'tag': 'vpn-4'}, // без автовыбора
        ],
        'sources': [
          {
            'kind': 'folder',
            'id': 'f',
            'replace': {
              'mode': 'both',
              'tag': 'F',
              'auto': {'mode': 'least_test'},
            },
            'nodes': [
              {
                'kind': 'auto',
                'tag': 'A',
                'group': {
                  'group_type': 'urltest',
                  'strategy': {'mode': 'least_test'},
                },
              },
              {
                'kind': 'auto',
                'tag': 'M',
                'group': {
                  'group_type': 'selector',
                  'strategy': {'mode': 'least_test'},
                },
              },
              {
                'kind': 'auto',
                'tag': 'R',
                'group': {
                  'group_type': 'urltest',
                  'strategy': {'mode': 'round_robin'},
                },
              },
            ],
          },
        ],
      };

  Future<Map<String, dynamic>> run(Map<String, dynamic> d) async {
    File('${tmp.path}/lxbox_settings.json').writeAsStringSync(jsonEncode(d));
    SettingsStorage.resetCacheForTesting();
    await SettingsStorage.migrateUrltestModeIfNeeded();
    SettingsStorage.resetCacheForTesting();
    return SettingsStorage.exportRaw();
  }

  List<Object?> modes(Map<String, dynamic> d) => [
        for (final c in d['directions'] as List) (c as Map)['auto']?['mode'],
        ((d['sources'] as List).single as Map)['replace']['auto']['mode'],
        for (final n in ((d['sources'] as List).single as Map)['nodes'] as List)
          (n as Map)['group']['strategy']['mode'],
      ];

  for (final passive in [true, _absent]) {
    test('passive_check=$passive → least_test становится failover', () async {
      final out = await run(doc(passive: passive));
      expect(modes(out), [
        'failover', 'failover', 'round_robin', null, // Направления
        'failover', // свёртка
        'failover', 'least_test', 'round_robin', // узлы: auto, selector, rr
      ]);
      expect(out.containsKey('urltest_passive_check'), isFalse);
      expect(out['urltest_mode_migrated'], isTrue);
    });
  }

  test('passive_check=false → режимы не меняются, ключ снят', () async {
    final out = await run(doc(passive: false));
    expect(modes(out), modes(doc()));
    expect(out.containsKey('urltest_passive_check'), isFalse);
    expect(out['urltest_mode_migrated'], isTrue);
  });

  test('повторно не идёт: маркер стоит, least_test остаётся', () async {
    final d = doc()..['urltest_mode_migrated'] = true;
    final out = await run(d);
    expect(modes(out), modes(doc()));
  });
}

const Object _absent = _Absent();

final class _Absent {
  const _Absent();
  @override
  String toString() => 'absent';
}
