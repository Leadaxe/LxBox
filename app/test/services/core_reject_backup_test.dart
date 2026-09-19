// §489 — вердикт страховки в бэкап не едет; локальное хранилище не трогаем.
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:lxbox/models/core_reject_verdict.dart';
import 'package:lxbox/models/server_list.dart';
import 'package:lxbox/services/core_reject/core_reject_backup.dart';
import 'package:lxbox/services/dns/dns_backup.dart';
import 'package:lxbox/services/lx_backup.dart';
import 'package:lxbox/services/lx_backup_import.dart';
import 'package:lxbox/services/lx_backup_slice.dart';

import '../parser/engine_test_setup.dart';

const _url = 'https://example-1.com/sub';
const _uri = 'vless://11111111-1111-1111-1111-111111111111@example-2.com:443'
    '?type=tcp&security=tls&sni=example-2.com#Tokyo';

Future<LxBackupExport> _export(List<ServerList> lists) => buildLxBackup(
      lists: lists,
      rules: const [],
      vars: const {},
      chains: const [],
      dns: dnsToBackup(
        servers: const [],
        rules: const [],
        strategy: '',
        dnsFinal: '',
        warnings: const [],
      ),
    );

Map<String, dynamic> _source(String json, String kind) =>
    ((jsonDecode(json) as Map)['sources'] as List)
        .cast<Map<String, dynamic>>()
        .firstWhere((s) => s['kind'] == kind);

SubscriptionServers _sub({
  Map<String, DateTime> disabled = const {},
  Map<String, List<StoredWarning>> warnings = const {},
}) =>
    SubscriptionServers(
      id: 'sub-1',
      name: 'Provider',
      enabled: true,
      tagPrefix: '',
      detourPolicy: DetourPolicy.defaults,
      url: _url,
      disabledHashes: disabled,
      nodeWarnings: warnings,
    );

void main() {
  setUpAll(loadEngineSections);

  group('§221 — warnings в allowlist, в бэкап вердикт не едет', () {
    test('warnings объявлен в slice-таблице у всех трёх видов записи', () {
      for (final r in [
        BackupRecord.subscription,
        BackupRecord.server,
        BackupRecord.folderNode,
      ]) {
        final field = kBackupFields
            .where((f) => f.record == r && f.key == 'warnings')
            .toList();
        expect(field, hasLength(1), reason: '$r');
        expect(field.single.travels, true,
            reason: '$r: ключ хранения в allowlist');
      }
    });

    test('страховка: вердикт и выключение не попадают в файл', () async {
      final out = await _export([
        _sub(
          disabled: {'Tokyo': DateTime.utc(2026, 9, 19)},
          warnings: {
            'Tokyo': [StoredWarning.coreRejected('parse encryption: bad')]
          },
        ),
      ]);
      expect(out.warnings, isEmpty);
      final sub = _source(out.json, 'subscription');
      expect(sub.containsKey('warnings'), false);
      expect(sub.containsKey('disabled'), false);
    });

    test('ручное выключение без вердикта экспортируется', () async {
      final out = await _export([
        _sub(disabled: {'Tokyo': DateTime.utc(2026, 9, 19)}),
      ]);
      final sub = _source(out.json, 'subscription');
      expect(sub['disabled'], isNotNull);
      expect(sub.containsKey('warnings'), false);
    });
  });

  group('экспорт → импорт', () {
    test('страховка: после импорта узел включён, вердикта нет', () async {
      final local = _sub(
        disabled: {'Tokyo': DateTime.utc(2026, 9, 19)},
        warnings: {'Tokyo': [StoredWarning.coreRejected('bad tokyo')]},
      );
      final out = await _export([local]);
      final plan = planLxBackupImport(
        out.json,
        LxImportReceiver(lists: const [], receiverTargets: const {'vpn-1'}),
      );
      final sub = plan.lists.whereType<SubscriptionServers>().single;
      expect(sub.disabledHashes.containsKey('Tokyo'), false);
      expect(sub.nodeWarnings.containsKey('Tokyo'), false);
    });

    test('старый файл с вердиктом: импорт игнорирует, узел включён', () async {
      final json = jsonEncode({
        'lx_backup': 2,
        'exported_by': {'app': 'test', 'version': '0'},
        'exported_at': '2026-09-19T00:00:00Z',
        'sources': [
          {
            'kind': 'subscription',
            'id': 'sub-file',
            'name': 'Provider',
            'enabled': true,
            'url': _url,
            'disabled': {
              'Tokyo': DateTime.utc(2026, 9, 19).millisecondsSinceEpoch ~/ 1000,
            },
            'warnings': {
              'Tokyo': [
                {
                  'code': 'core_rejected',
                  'params': {'reason': 'из старого файла'},
                },
              ],
            },
          },
        ],
      });
      final plan = planLxBackupImport(
        json,
        LxImportReceiver(lists: const [], receiverTargets: const {'vpn-1'}),
      );
      expect(plan.file.warnings, isEmpty);
      final sub = plan.lists.whereType<SubscriptionServers>().single;
      expect(sub.disabledHashes.containsKey('Tokyo'), false);
      expect(sub.nodeWarnings.containsKey('Tokyo'), false);
    });

    test('совпавшая подписка: локальный вердикт не перетирается файлом',
        () async {
      final out = await _export([
        _sub(
          disabled: {'Tokyo': DateTime.utc(2026, 9, 19)},
          warnings: {'Tokyo': [StoredWarning.coreRejected('из файла')]},
        ),
      ]);
      final local = _sub(
        disabled: {'Tokyo': DateTime.utc(2026, 9, 1)},
        warnings: {'Tokyo': [StoredWarning.coreRejected('свой')]},
      );
      final plan = planLxBackupImport(
        out.json,
        LxImportReceiver(lists: [local], receiverTargets: const {'vpn-1'}),
      );
      final sub = plan.lists.whereType<SubscriptionServers>().single;
      expect(sub.nodeWarnings['Tokyo']!.single.reason, 'свой');
      expect(sub.disabledHashes.containsKey('Tokyo'), true);
    });

    test('ручная отметка из файла доливается, страховочная — нет', () async {
      final json = jsonEncode({
        'lx_backup': 2,
        'exported_by': {'app': 'test', 'version': '0'},
        'exported_at': '2026-09-19T00:00:00Z',
        'sources': [
          {
            'kind': 'subscription',
            'id': 'sub-file',
            'name': 'Provider',
            'enabled': true,
            'url': _url,
            'disabled': {
              'Osaka': DateTime.utc(2026, 9, 19).millisecondsSinceEpoch ~/ 1000,
              'Kyoto': DateTime.utc(2026, 9, 18).millisecondsSinceEpoch ~/ 1000,
            },
            'warnings': {
              'Kyoto': [
                {
                  'code': 'core_rejected',
                  'params': {'reason': 'bad kyoto'},
                },
              ],
            },
          },
        ],
      });
      final local = _sub(
        disabled: {'Tokyo': DateTime.utc(2026, 9, 1)},
        warnings: {'Tokyo': [StoredWarning.coreRejected('bad tokyo')]},
      );
      final plan = planLxBackupImport(
        json,
        LxImportReceiver(lists: [local], receiverTargets: const {'vpn-1'}),
      );
      final sub = plan.lists.whereType<SubscriptionServers>().single;
      expect(sub.disabledHashes.keys.toSet(), {'Tokyo', 'Osaka'});
      expect(sub.disabledHashes.containsKey('Kyoto'), false);
      expect(sub.nodeWarnings['Tokyo']!.single.reason, 'bad tokyo');
    });

    test('ручной сервер: страховка не едет, ручное выключение — да',
        () async {
      final outInsurance = await _export([
        UserServer(
          id: 'srv-1',
          name: '',
          enabled: false,
          tagPrefix: '',
          detourPolicy: DetourPolicy.defaults,
          origin: UserSource.paste,
          rawBody: _uri,
          warnings: [StoredWarning.coreRejected('bad server')],
        ),
      ]);
      expect(_source(outInsurance.json, 'server')['enabled'], true);
      expect(_source(outInsurance.json, 'server').containsKey('warnings'), false);

      final plan = planLxBackupImport(
        outInsurance.json,
        LxImportReceiver(lists: const [], receiverTargets: const {'vpn-1'}),
      );
      expect(plan.file.warnings, isEmpty);
      final srv = plan.lists.whereType<UserServer>().single;
      expect(srv.enabled, true);
      expect(srv.warnings, isEmpty);

      final outManual = await _export([
        UserServer(
          id: 'srv-2',
          name: '',
          enabled: false,
          tagPrefix: '',
          detourPolicy: DetourPolicy.defaults,
          origin: UserSource.paste,
          rawBody: _uri,
        ),
      ]);
      expect(_source(outManual.json, 'server')['enabled'], false);

      final planManual = planLxBackupImport(
        outManual.json,
        LxImportReceiver(lists: const [], receiverTargets: const {'vpn-1'}),
      );
      expect(planManual.file.warnings, isEmpty);
      expect(planManual.lists.whereType<UserServer>().single.enabled, false);
    });

    test('в одной подписке: страховка срезается, ручное выключение остаётся',
        () async {
      final out = await _export([
        _sub(
          disabled: {
            'Tokyo': DateTime.utc(2026, 9, 19),
            'Osaka': DateTime.utc(2026, 9, 18),
          },
          warnings: {
            'Tokyo': [StoredWarning.coreRejected('bad tokyo')],
          },
        ),
      ]);
      final sub = _source(out.json, 'subscription');
      expect((sub['disabled'] as Map).keys.toSet(), {'Osaka'});
      expect(sub.containsKey('warnings'), false);

      final plan = planLxBackupImport(
        out.json,
        LxImportReceiver(lists: const [], receiverTargets: const {'vpn-1'}),
      );
      expect(plan.file.warnings, isEmpty);
      final got = plan.lists.whereType<SubscriptionServers>().single;
      expect(got.disabledHashes.keys.toSet(), {'Osaka'});
      expect(got.nodeWarnings, isEmpty);
    });

    test('старый файл ручного сервера с вердиктом: импорт без ошибок, узел включён',
        () async {
      final json = jsonEncode({
        'lx_backup': 2,
        'exported_by': {'app': 'test', 'version': '0'},
        'exported_at': '2026-09-19T00:00:00Z',
        'sources': [
          {
            'kind': 'server',
            'id': 'srv-old',
            'tag': 'Tokyo',
            'enabled': false,
            'warnings': [
              {
                'code': 'core_rejected',
                'params': {'reason': 'из старого файла'},
              },
            ],
            'origin': {'kind': 'uri', 'raw': _uri},
          },
        ],
      });
      final plan = planLxBackupImport(
        json,
        LxImportReceiver(lists: const [], receiverTargets: const {'vpn-1'}),
      );
      expect(plan.file.warnings, isEmpty);
      final srv = plan.lists.whereType<UserServer>().single;
      expect(srv.enabled, true);
      expect(srv.warnings, isEmpty);
    });
  });

  group('sanitizeCoreRejectInBackupRecord', () {
    test('папка: член со страховкой в файле включён', () {
      final out = sanitizeCoreRejectInBackupRecord({
        'kind': 'folder',
        'nodes': [
          {
            'kind': 'server',
            'tag': 'n1',
            'enabled': false,
            'warnings': [
              {
                'code': 'core_rejected',
                'params': {'reason': 'bad'},
              },
            ],
            'origin': {'kind': 'uri', 'raw': _uri},
          },
        ],
      }, BackupRecord.folder);
      final node = (out['nodes'] as List).single as Map;
      expect(node['enabled'], true);
      expect(node.containsKey('warnings'), false);
    });
  });

  group('папка: экспорт → импорт', () {
    const other = 'trojan://secret@example-3.com:443#Osaka';

    test('страховка включена и без вердикта, ручное выключение остаётся',
        () async {
      final out = await _export([
        FolderServers(
          id: 'fold-1',
          name: 'EU',
          enabled: true,
          tagPrefix: '',
          detourPolicy: DetourPolicy.defaults,
          members: [
            FolderMember(
              raw: _uri,
              enabled: false,
              warnings: [StoredWarning.coreRejected('bad')],
            ),
            FolderMember(raw: other, enabled: false),
          ],
        ),
      ]);
      final folder = _source(out.json, 'folder');
      final nodes = (folder['nodes'] as List).cast<Map<String, dynamic>>();
      Map<String, dynamic> nodeWith(String hay) => nodes.firstWhere(
            (n) => (n['origin'] as Map)['raw'].toString().contains(hay),
          );
      final insurance = nodeWith('example-2.com');
      final manual = nodeWith('example-3.com');
      expect(insurance['enabled'], true);
      expect(insurance.containsKey('warnings'), false);
      expect(manual['enabled'], false);

      final plan = planLxBackupImport(
        out.json,
        LxImportReceiver(lists: const [], receiverTargets: const {'vpn-1'}),
      );
      expect(plan.file.warnings, isEmpty);
      final got = plan.lists.whereType<FolderServers>().single;
      FolderMember memberWith(String hay) =>
          got.members.firstWhere((m) => m.raw.contains(hay));
      expect(memberWith('example-2.com').enabled, true);
      expect(memberWith('example-2.com').warnings, isEmpty);
      expect(memberWith('example-3.com').enabled, false);
    });
  });

  group('плашка после перезапуска', () {
    test('CoreRejectState не пишет плашку на диск', () {
      final src = File('lib/services/core_reject/core_reject_state.dart')
          .readAsStringSync();
      expect(src.contains('SharedPreferences'), isFalse);
      expect(src.contains('path_provider'), isFalse);
      expect(src.contains('writeAsString'), isFalse);
      expect(src.contains('Hive'), isFalse);
    });
  });
}
