import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:lxbox/models/dns_ref.dart';
import 'package:lxbox/models/server_list.dart';
import 'package:lxbox/models/source_chain.dart';
import 'package:lxbox/services/backup_service.dart';
import 'package:lxbox/services/settings_storage.dart';

import '../storage_migration/golden_harness.dart';

/// §439 §3.4 — внутренний бэкап (`app: lxbox`, `kind: backup`) со снимком
/// хранения 2.23.2: блок `storage` мигрирует при разборе, превью и
/// категорийный фильтр видят форму 1.0 (источники делятся по
/// `sources[].kind`: цепочка — Routing, прочее — Server lists), восстановление
/// собирает тот же `config.json`, что и хранение до миграции.
void main() {
  /// Блок `storage`, каким его писал внутренний бэкап 2.23.2.
  Map<String, dynamic> legacyStorage() => {
        'vars': {
          'log_level': 'warn',
          'debug_enabled': 'true',
          'debug_token': 'tok',
        },
        'server_lists': [
          {
            'type': 'subscription',
            'id': 'sub-1',
            'name': 'Provider',
            'enabled': true,
            'tag_prefix': 'PR',
            'url': 'https://example.com/sub/1',
          },
          {
            'type': 'user',
            'id': 'srv-1',
            'name': '',
            'enabled': true,
            'raw_body': 'vless://11111111-1111-1111-1111-111111111111'
                '@198.51.100.1:443?type=ws&security=tls#Tokyo',
          },
          {
            'type': 'folder',
            'id': 'fold-1',
            'name': 'Personal',
            'enabled': true,
            'created_at': '2026-02-02T00:00:00.000',
            'members': [
              {
                'raw': 'vless://22222222-2222-2222-2222-222222222222'
                    '@198.51.100.2:443?type=ws&security=tls#Osaka',
              },
            ],
          },
        ],
        'chains': [
          {'tag': 'second', 'hops': ['first', 'vpn-1'], 'order': 12},
          {'tag': 'first', 'hops': ['Tokyo', 'Osaka'], 'order': 11},
        ],
        'custom_rules': [
          {
            'id': 'r1',
            'name': 'Ads',
            'enabled': true,
            'kind': 'inline',
            'num': 960,
            'domainSuffixes': ['.ads.example'],
            'outbound': 'reject',
          },
        ],
        'dns_options': {
          'servers': [
            {'enabled': true, 'kind': 'preset', 'tag': 'yandex_udp'},
          ],
          'rules': [
            {'kind': 'preset', 'presetId': 'ru-direct', 'enabled': true},
          ],
        },
        'route_final': 'vpn-1',
        'directions': [
          {'tag': 'vpn-1', 'label': 'Main', 'enabled': true},
        ],
        'directions_migrated': true,
        'excluded_nodes': ['gone'],
      };

  String envelope(Map<String, dynamic> storage) => jsonEncode({
        'app': 'lxbox',
        'kind': 'backup',
        'created_at': '2026-09-01T00:00:00Z',
        'source_app_version': '2.23.2+22302',
        'storage': storage,
      });

  const allStorageCategories = {
    BackupCategory.serverLists,
    BackupCategory.routing,
    BackupCategory.appSettings,
    BackupCategory.debugConfig,
  };

  late StorageSandbox box;

  setUp(() async {
    box = await StorageSandbox.create();
  });

  tearDown(() => box.dispose());

  group('разбор архива 2.23.2', () {
    test('блок мигрирует: превью считает по sources[].kind', () async {
      final contents =
          await const BackupService().parseImport(envelope(legacyStorage()));

      final migration = contents.storageMigration!;
      expect(migration.migrated, isTrue);
      final storage = contents.storage!;
      expect(storage['storage_version'], 1);
      for (final k in ['server_lists', 'chains', 'custom_rules', 'dns_options',
        'excluded_nodes']) {
        expect(storage.containsKey(k), isFalse, reason: k);
      }

      expect(contents.availableCategories(), allStorageCategories);
      expect(contents.countFor(BackupCategory.serverLists), 3,
          reason: 'цепочки в счёт источников не входят');
      expect(contents.splitServerLists(), (subs: 1, custom: 2));
      expect(contents.countFor(BackupCategory.routing), 1);
      expect(contents.countFor(BackupCategory.debugConfig), 2);
    });

    test('preset-сервер DNS получает ref по шаблону приложения', () async {
      final contents =
          await const BackupService().parseImport(envelope(legacyStorage()));
      final dns = contents.storage!['dns'] as Map<String, dynamic>;
      expect((dns['servers'] as List).single,
          {'kind': 'preset', 'ref': 'ru-direct:yandex_udp', 'enabled': true});
      expect((dns['rules'] as List).single,
          {'kind': 'preset', 'ref': 'ru-direct', 'enabled': true});
    });

    test('категорийный фильтр делит sources[] по виду записи', () async {
      final storage =
          (await const BackupService().parseImport(envelope(legacyStorage())))
              .storage!;
      List<String> kinds(Map<String, dynamic> filtered) => [
            for (final r in (filtered['sources'] as List? ?? const []))
              (r as Map)['kind'] as String,
          ];

      final servers = BackupService.filterStorageForExport(storage,
          include: {BackupCategory.serverLists});
      expect(kinds(servers), ['subscription', 'server', 'folder']);
      expect(servers.containsKey('rules'), isFalse);
      expect(servers.containsKey('dns'), isFalse);
      expect(servers['storage_version'], 1);

      final routing = BackupService.filterStorageForExport(storage,
          include: {BackupCategory.routing});
      expect(kinds(routing), ['chain', 'chain']);
      expect(routing.containsKey('rules'), isTrue);
      expect(routing.containsKey('dns'), isTrue);
      expect(routing['storage_version'], 1);
    });
  });

  group('восстановление архива 2.23.2', () {
    test('replace только Routing: цепочки по старому order, правила и DNS; '
        'источников нет', () async {
      final svc = const BackupService();
      final contents = await svc.parseImport(envelope(legacyStorage()));
      final result = await svc.applyImport(contents,
          merge: false, include: {BackupCategory.routing});
      expect(result.errors, isEmpty);
      expect(result.droppedKeys, isEmpty);
      expect(result.routingApplied, 1);

      expect(await SettingsStorage.getServerLists(), isEmpty);
      expect((await SettingsStorage.getChains()).map((c) => c.tag),
          ['first', 'second']);
      expect((await SettingsStorage.getCustomRules()).single.name, 'Ads');
      expect((await SettingsStorage.getDnsServers()).single,
          const DnsServerPreset(
              enabled: true, tag: 'yandex_udp', presetId: 'ru-direct'));
    });

    test('merge Server lists: источники дописываются по id, цепочки хранения '
        'на месте', () async {
      await SettingsStorage.saveServerLists([
        SubscriptionServers(
          id: 'sub-1',
          name: 'Local copy',
          enabled: false,
          tagPrefix: '',
          detourPolicy: DetourPolicy.defaults,
          url: 'https://example.com/local',
        ),
      ]);
      await SettingsStorage.setChains(
          const [SourceChain(tag: 'mine', hops: ['a', 'b'])]);

      final svc = const BackupService();
      final contents = await svc.parseImport(envelope(legacyStorage()));
      final result = await svc.applyImport(contents,
          merge: true, include: {BackupCategory.serverLists});
      expect(result.errors, isEmpty);
      expect(result.serverListsApplied, 2);

      final lists = await SettingsStorage.getServerLists();
      expect(lists.map((l) => l.id), ['sub-1', 'srv-1', 'fold-1']);
      expect(lists.first.name, 'Local copy',
          reason: 'id уже есть — запись хранения не заменяется');
      expect((await SettingsStorage.getChains()).map((c) => c.tag), ['mine']);
    });

    test('merge Routing: цепочки архива заменяют цепочки хранения, источники '
        'на месте', () async {
      await SettingsStorage.saveServerLists([
        UserServer(
          id: 'keep',
          name: '',
          enabled: true,
          tagPrefix: '',
          detourPolicy: DetourPolicy.defaults,
          rawBody: 'vless://33333333-3333-3333-3333-333333333333'
              '@198.51.100.3:443?type=ws&security=tls#Keep',
        ),
      ]);
      await SettingsStorage.setChains(
          const [SourceChain(tag: 'mine', hops: ['a', 'b'])]);

      final svc = const BackupService();
      final contents = await svc.parseImport(envelope(legacyStorage()));
      final result = await svc.applyImport(contents,
          merge: true, include: {BackupCategory.routing});
      expect(result.errors, isEmpty);

      expect((await SettingsStorage.getServerLists()).map((l) => l.id),
          ['keep']);
      expect((await SettingsStorage.getChains()).map((c) => c.tag),
          ['first', 'second']);
    });
  });

  // §4.2 — снимок хранения 2.23.2, восстановленный из внутреннего бэкапа в
  // пустое хранение, собирает тот же config.json, что и само хранение
  // (эталон golden_config_test).
  for (final name in kStorageFixtures) {
    test('$name: бэкап 2.23.2 → replace всех категорий → config.json = эталон',
        timeout: kGoldenTimeout, () async {
      await box.seed(name, storage: false);
      final raw = await fixtureFile(name).readAsString();

      final svc = const BackupService();
      final contents = await svc.parseImport(
          envelope(jsonDecode(raw) as Map<String, dynamic>));
      expect(contents.storageMigration!.migrated, isTrue);
      final result = await svc.applyImport(contents,
          merge: false, include: allStorageCategories);
      expect(result.errors, isEmpty);

      final built = await buildGoldenConfig(box);
      final golden = goldenFile('$name.config.json').readAsStringSync();
      expect(built.configJson, golden,
          reason: jsonDiff(jsonDecode(golden), built.config).join('\n'));
    });
  }
}
