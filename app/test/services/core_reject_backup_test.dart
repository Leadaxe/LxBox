// §489 / контракт 1.1.67 — `core_rejected` при переносе бэкапом: экспорт
// сервера пишет как есть, подписка — картой disabled{} без причины; импорт
// запись снимает, выключение берёт из файла (узел не включается).
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:lxbox/models/core_reject_verdict.dart';
import 'package:lxbox/models/node_spec.dart' show AutoSelectSpec;
import 'package:lxbox/models/server_list.dart';
import 'package:lxbox/services/core_reject/core_reject_backup.dart';
import 'package:lxbox/services/core_reject/core_reject_guard.dart';
import 'package:lxbox/services/core_reject/core_reject_state.dart';
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

  group('§221 — warnings в allowlist; причина у подписки не едет', () {
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

    test('подписка: выключение едет картой disabled без причины', () async {
      final out = await _export([
        _sub(
          disabled: {'Tokyo': DateTime.utc(2026, 9, 19)},
          warnings: {
            'Tokyo': [StoredWarning.coreRejected('parse encryption: bad')]
          },
        ),
      ]);
      expect(out.warnings, isEmpty);
      expect(out.json.contains('core_rejected'), isFalse);
      final sub = _source(out.json, 'subscription');
      expect(sub.containsKey('warnings'), false);
      expect((sub['disabled'] as Map).keys, ['Tokyo']);
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
    test('страховка: после импорта узел выключен, вердикта нет', () async {
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
      expect(sub.disabledHashes.containsKey('Tokyo'), true);
      expect(sub.nodeWarnings.containsKey('Tokyo'), false);
    });

    test('файл с вердиктом: запись снята, узел остаётся выключенным', () async {
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
      expect(sub.disabledHashes.containsKey('Tokyo'), true);
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

    test('отметки из файла доливаются, вердикт файла — нет', () async {
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
      expect(sub.disabledHashes.keys.toSet(), {'Tokyo', 'Osaka', 'Kyoto'});
      expect(sub.nodeWarnings.containsKey('Kyoto'), false);
      expect(sub.nodeWarnings['Tokyo']!.single.reason, 'bad tokyo');
    });

    test('ручной сервер: экспорт как есть, импорт снимает вердикт',
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
      expect(_source(outInsurance.json, 'server')['enabled'], false);
      expect(
          (_source(outInsurance.json, 'server')['warnings'] as List).single
              ['code'],
          'core_rejected');

      final plan = planLxBackupImport(
        outInsurance.json,
        LxImportReceiver(lists: const [], receiverTargets: const {'vpn-1'}),
      );
      expect(plan.file.warnings, isEmpty);
      final srv = plan.lists.whereType<UserServer>().single;
      expect(srv.enabled, false);
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

    test('в одной подписке: причина срезается, оба выключения остаются',
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
      expect((sub['disabled'] as Map).keys.toSet(), {'Tokyo', 'Osaka'});
      expect(sub.containsKey('warnings'), false);

      final plan = planLxBackupImport(
        out.json,
        LxImportReceiver(lists: const [], receiverTargets: const {'vpn-1'}),
      );
      expect(plan.file.warnings, isEmpty);
      final got = plan.lists.whereType<SubscriptionServers>().single;
      expect(got.disabledHashes.keys.toSet(), {'Tokyo', 'Osaka'});
      expect(got.nodeWarnings, isEmpty);
    });

    test('файл ручного сервера с вердиктом: импорт без ошибок, узел выключен',
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
      expect(srv.enabled, false);
      expect(srv.warnings, isEmpty);
    });
  });

  group('sanitizeCoreRejectInBackupRecord', () {
    test('папка: у члена вердикт снят, выключение осталось', () {
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
      expect(node['enabled'], false);
      expect(node.containsKey('warnings'), false);
    });
  });

  group('папка: экспорт → импорт', () {
    const other = 'trojan://secret@example-3.com:443#Osaka';

    test('экспорт как есть; импорт снимает вердикт, выключения остаются',
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
      expect(insurance['enabled'], false);
      expect((insurance['warnings'] as List).single['code'], 'core_rejected');
      expect(manual['enabled'], false);

      final plan = planLxBackupImport(
        out.json,
        LxImportReceiver(lists: const [], receiverTargets: const {'vpn-1'}),
      );
      expect(plan.file.warnings, isEmpty);
      final got = plan.lists.whereType<FolderServers>().single;
      FolderMember memberWith(String hay) =>
          got.members.firstWhere((m) => m.raw.contains(hay));
      expect(memberWith('example-2.com').enabled, false);
      expect(memberWith('example-2.com').warnings, isEmpty);
      expect(memberWith('example-3.com').enabled, false);
    });

    test('файл папки с вердиктом: импорт без ошибок, узел выключен',
        () async {
      final json = jsonEncode({
        'lx_backup': 2,
        'exported_by': {'app': 'test', 'version': '0'},
        'exported_at': '2026-09-19T00:00:00Z',
        'sources': [
          {
            'kind': 'folder',
            'id': 'fold-old',
            'name': 'EU',
            'enabled': true,
            'nodes': [
              {
                'kind': 'server',
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
              {
                'kind': 'server',
                'tag': 'Osaka',
                'enabled': false,
                'origin': {'kind': 'uri', 'raw': other},
              },
            ],
          },
        ],
      });
      final plan = planLxBackupImport(
        json,
        LxImportReceiver(lists: const [], receiverTargets: const {'vpn-1'}),
      );
      expect(plan.file.warnings, isEmpty);
      final got = plan.lists.whereType<FolderServers>().single;
      FolderMember memberWith(String hay) =>
          got.members.firstWhere((m) => m.raw.contains(hay));
      expect(memberWith('example-2.com').enabled, false);
      expect(memberWith('example-2.com').warnings, isEmpty);
      expect(memberWith('example-3.com').enabled, false);
    });
  });

  group('контракт 1.1.66 — warnings узла-группы едут как есть', () {
    test('экспорт пишет, импорт кладёт в состояние; core_rejected снят',
        () async {
      final out = await _export([
        FolderServers(
          id: 'fold-g',
          name: 'EU',
          enabled: true,
          tagPrefix: '',
          detourPolicy: DetourPolicy.defaults,
          members: [
            FolderMember(raw: _uri),
            FolderMember.auto(
              AutoSelectSpec(id: 'g', tag: 'Auto', label: 'Auto'),
              warnings: const [
                StoredWarning(
                    code: 'group_member_missing', params: {'count': '2'}),
              ],
            ),
          ],
        ),
      ]);
      final nodes = (_source(out.json, 'folder')['nodes'] as List)
          .cast<Map<String, dynamic>>();
      final auto = nodes.firstWhere((n) => n['kind'] == 'auto');
      expect((auto['warnings'] as List).single['code'], 'group_member_missing');

      final plan = planLxBackupImport(
        out.json,
        LxImportReceiver(lists: const [], receiverTargets: const {'vpn-1'}),
      );
      final got = plan.lists.whereType<FolderServers>().single;
      final g = got.members.firstWhere((m) => m.node is AutoSelectSpec);
      expect(g.warnings.map((w) => w.code), ['group_member_missing']);
      expect(g.warnings.single.params['count'], '2');
    });
  });

  group('плашка после перезапуска', () {
    tearDown(CoreRejectState.I.resetForTest);

    test('плашка живёт в памяти процесса и после сброса состояния не видна', () {
      CoreRejectState.I.resetForTest();
      CoreRejectState.I.finish(const CoreRejectRun(
        outcome: CoreRejectOutcome.startedWithDisabled,
        disabled: [DisabledNode(tag: 'n1', reason: 'bad')],
      ));
      expect(CoreRejectState.I.bannerVisible, isTrue);
      expect(CoreRejectState.I.bannerNodes, isNotEmpty);

      // Перезапуск приложения = новый процесс: синглтон создаётся заново.
      // В тесте это [CoreRejectState.resetForTest] — персиста у плашки нет.
      CoreRejectState.I.resetForTest();
      expect(CoreRejectState.I.bannerVisible, isFalse);
      expect(CoreRejectState.I.bannerNodes, isEmpty);
    });
  });
}
