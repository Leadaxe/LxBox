import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:lxbox/models/dns_ref.dart';
import 'package:lxbox/models/record_codec.dart';
import 'package:lxbox/services/builder/post_steps.dart';
import 'package:lxbox/services/builder/preset_expand.dart';
import 'package:lxbox/services/dns/dns_backup.dart';
import 'package:lxbox/services/lx_backup.dart';
import 'package:lxbox/services/settings_storage.dart';
import 'package:lxbox/services/storage_migration/migrate_storage.dart';

/// §439 — preset-сервер DNS проходит миграцию 2.23.2, пересборку, слияние
/// бэкапа и экспорт одной формой: тег модели — тег конфига
/// (`ru-direct:dns_ru`), `ref` записи — та же строка.
///
/// Стенд волны E: первая пересборка после миграции переписала `ref` в
/// `ru-direct:ru-direct:dns_ru`, включила выключенный пользователем сервер и
/// сняла его `description`; слияние файла 0.x дописало четыре дубля.
void main() {
  late Directory tmp;
  const channel = MethodChannel('plugins.flutter.io/path_provider');

  File settings() => File('${tmp.path}/lxbox_settings.json');

  setUp(() async {
    TestWidgetsFlutterBinding.ensureInitialized();
    tmp = await Directory.systemTemp.createTemp('lxbox_preset_dns_ref_');
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
    SettingsStorage.resetCacheForTesting();
    if (tmp.existsSync()) await tmp.delete(recursive: true);
  });

  // Серверы пресета так, как их называет сборка (`expandPreset` →
  // `namespacePresetTags`).
  final presetServersByTag = {
    for (final s in namespacePresetTags(
      'ru-direct',
      const PresetFragments(dnsServers: [
        {'type': 'udp', 'tag': 'dns_ru', 'server': '77.88.8.8'},
        {'type': 'https', 'tag': 'yandex_doh', 'server': 'common.dot.dns.yandex.net'},
      ]),
    ).dnsServers)
      s['tag'] as String: s,
  };

  Future<List<DnsServerRef>> resolve() => resolveDnsServersList(
        templateServers: const [],
        presetServersByTag: presetServersByTag,
        presetIdByTag: {for (final t in presetServersByTag.keys) t: 'ru-direct'},
      );

  Future<void> seed(Map<String, dynamic> dns) => settings().writeAsString(
      jsonEncode({'storage_version': 1, 'dns': dns}));

  Future<List<dynamic>> fileServers() async =>
      ((jsonDecode(await settings().readAsString()) as Map)['dns']
          as Map)['servers'] as List<dynamic>;

  test('теги сборки — в пространстве пресета (форма, которую держит модель)',
      () {
    expect(presetServersByTag.keys, ['ru-direct:dns_ru', 'ru-direct:yandex_doh']);
  });

  test('2.23.2 → миграция → пересборка: выключатель, description и место '
      'preset-сервера целы, ref без повтора, файл не переписан', () async {
    final ids = await SettingsStorage.presetIdsForMigration();
    expect(ids['ru-direct:yandex_doh'], 'ru-direct',
        reason: 'ключ карты миграции — тег хранения 2.23.2');

    final migrated = migrateStorageDoc({
      'dns_options': {
        'servers': [
          {'enabled': true, 'kind': 'preset', 'tag': 'ru-direct:dns_ru'},
          {
            'enabled': false,
            'kind': 'preset',
            'tag': 'ru-direct:yandex_doh',
            'description': 'Off by me',
          },
          {
            'enabled': true,
            'kind': 'inline',
            'tag': 'mine',
            'body': {'type': 'udp', 'server': '192.0.2.1'},
          },
        ],
      },
    }, presetIdByDnsServerTag: ids);
    expect(migrated.info.join('; '), isNot(contains('without a known preset')));
    final records = (migrated.doc['dns'] as Map)['servers'];
    expect(records, [
      {'kind': 'preset', 'ref': 'ru-direct:dns_ru', 'enabled': true},
      {
        'kind': 'preset',
        'ref': 'ru-direct:yandex_doh',
        'enabled': false,
        'description': 'Off by me',
      },
      {
        'kind': 'user',
        'tag': 'mine',
        'enabled': true,
        'body': {'type': 'udp', 'server': '192.0.2.1'},
      },
    ]);

    await seed(migrated.doc['dns'] as Map<String, dynamic>);
    final before = await settings().readAsString();
    for (var pass = 0; pass < 2; pass++) {
      SettingsStorage.resetCacheForTesting();
      final resolved = await resolve();
      expect(resolved, const <DnsServerRef>[
        DnsServerPreset(
            enabled: true, tag: 'ru-direct:dns_ru', presetId: 'ru-direct'),
        DnsServerPreset(
          enabled: false,
          tag: 'ru-direct:yandex_doh',
          presetId: 'ru-direct',
          description: 'Off by me',
        ),
        DnsServerInline(
            enabled: true,
            tag: 'mine',
            body: {'type': 'udp', 'server': '192.0.2.1'}),
      ]);
    }
    expect(await settings().readAsString(), before);

    // Экспорт 1.0 пишет тот же ref.
    final exported = dnsToBackup(
      servers: await SettingsStorage.getDnsServers(),
      rules: const [],
      dnsFinal: '',
      strategy: '',
    );
    expect([for (final s in exported!['servers'] as List) s['ref']],
        ['ru-direct:dns_ru', 'ru-direct:yandex_doh', null]);
  });

  test('ранняя запись 2.23.3 с повтором пространства читается терпимо: '
      'сервер узнан, дублей нет, экспорт и изменённая запись — ref один раз',
      () async {
    await seed({
      'servers': [
        {
          'kind': 'preset',
          'ref': 'ru-direct:ru-direct:yandex_doh',
          'enabled': false,
          'description': 'd',
        },
        {'kind': 'preset', 'ref': 'ru-direct:ru-direct:dns_ru', 'enabled': true},
      ],
    });
    final resolved = await resolve();
    expect(resolved, const <DnsServerRef>[
      DnsServerPreset(
          enabled: false, tag: 'ru-direct:yandex_doh', description: 'd'),
      DnsServerPreset(enabled: true, tag: 'ru-direct:dns_ru'),
    ]);

    final exported = dnsToBackup(
        servers: resolved, rules: const [], dnsFinal: '', strategy: '');
    expect([for (final s in exported!['servers'] as List) s['ref']],
        ['ru-direct:yandex_doh', 'ru-direct:dns_ru']);

    await SettingsStorage.saveDnsServers(
        [resolved[0].withEnabled(true), resolved[1]]);
    await SettingsStorage.flushToDisk();
    expect((await fileServers()).first, {
      'kind': 'preset',
      'ref': 'ru-direct:yandex_doh',
      'enabled': true,
      'description': 'd',
    });
  });

  test('слияние бэкапа: preset-сервер из хранения и тот же из файла 0.x или '
      '1.0 — одна запись, своя сильнее', () {
    // Хранение после резолвера: пресет известен.
    const local = <DnsServerRef>[
      DnsServerPreset(
        enabled: false,
        tag: 'ru-direct:yandex_doh',
        presetId: 'ru-direct',
        description: 'mine',
      ),
    ];
    final fromFile10 = dnsServerFromRecord(
        {'kind': 'preset', 'ref': 'ru-direct:yandex_doh', 'enabled': true}).value!;
    // Читатель файла 0.x отдаёт тег внутри пресета и presetId отдельно.
    const fromFile0x =
        DnsServerPreset(enabled: true, tag: 'yandex_doh', presetId: 'ru-direct');
    final got = applyDnsBackup(
      incoming: LxDns(servers: [fromFile10, fromFile0x], rules: const []),
      servers: local,
      rules: const [],
      dnsFinal: '',
      strategy: '',
    );
    expect(got.servers, local);
    expect(got.applied, 0);
  });
}
