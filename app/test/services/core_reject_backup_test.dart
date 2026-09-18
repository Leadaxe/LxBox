// Фича 478 — вердикт едет в бэкап вместе с отметкой выключения (§221:
// allowlist кодека ↔ slice-таблица экспорта симметричны). Без него узел
// приехал бы выключенным без объяснения.
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:lxbox/models/core_reject_verdict.dart';
import 'package:lxbox/models/server_list.dart';
import 'package:lxbox/services/dns/dns_backup.dart';
import 'package:lxbox/services/lx_backup.dart';
import 'package:lxbox/services/lx_backup_import.dart';
import 'package:lxbox/services/lx_backup_slice.dart';

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
  group('§221 — симметрия allowlist ↔ экспорт', () {
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
            reason: '$r: вердикт обязан ехать вместе с отметкой выключения');
      }
    });

    test('поле не срезается экспортом и без предупреждения', () async {
      final out = await _export([
        _sub(
          disabled: {'Tokyo': DateTime.utc(2026, 9, 19)},
          warnings: {
            'Tokyo': [StoredWarning.coreRejected('parse encryption: bad')]
          },
        ),
      ]);
      expect(out.warnings, isEmpty,
          reason: 'объявленное поле не даёт backup_local_only_dropped');
      final sub = _source(out.json, 'subscription');
      expect(sub['warnings'], {
        'Tokyo': [
          {
            'code': 'core_rejected',
            'params': {'reason': 'parse encryption: bad'}
          }
        ]
      });
      expect(sub['disabled'], isNotNull,
          reason: 'вердикт едет РЯДОМ с отметкой, а не вместо неё');
    });
  });

  group('экспорт → импорт', () {
    test('новая подписка: вердикт приезжает вместе с выключенностью',
        () async {
      final out = await _export([
        _sub(
          disabled: {'Tokyo': DateTime.utc(2026, 9, 19)},
          warnings: {'Tokyo': [StoredWarning.coreRejected('bad tokyo')]},
        ),
      ]);
      final plan = planLxBackupImport(
        out.json,
        LxImportReceiver(lists: const [], receiverTargets: const {'vpn-1'}),
      );
      final sub = plan.lists.whereType<SubscriptionServers>().single;
      expect(sub.disabledHashes.containsKey('Tokyo'), true);
      expect(sub.nodeWarnings['Tokyo']!.single.reason, 'bad tokyo');
    });

    test('совпавшая подписка: свой вердикт не перетирается файловым',
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
      expect(sub.nodeWarnings['Tokyo']!.single.reason, 'свой',
          reason: 'объединение, как у disabled: локальное решение сильнее');
    });

    test('чужая отметка доливается вместе со своей причиной', () async {
      final out = await _export([
        _sub(
          disabled: {'Osaka': DateTime.utc(2026, 9, 19)},
          warnings: {'Osaka': [StoredWarning.coreRejected('bad osaka')]},
        ),
      ]);
      final local = _sub(
        disabled: {'Tokyo': DateTime.utc(2026, 9, 1)},
        warnings: {'Tokyo': [StoredWarning.coreRejected('bad tokyo')]},
      );
      final plan = planLxBackupImport(
        out.json,
        LxImportReceiver(lists: [local], receiverTargets: const {'vpn-1'}),
      );
      final sub = plan.lists.whereType<SubscriptionServers>().single;
      expect(sub.nodeWarnings.keys.toSet(), {'Tokyo', 'Osaka'});
      expect(sub.nodeWarnings['Osaka']!.single.reason, 'bad osaka');
    });

    test('ручной сервер: вердикт переживает экспорт→импорт', () async {
      final out = await _export([
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
      expect(_source(out.json, 'server')['warnings'], isNotNull);
      final plan = planLxBackupImport(
        out.json,
        LxImportReceiver(lists: const [], receiverTargets: const {'vpn-1'}),
      );
      final srv = plan.lists.whereType<UserServer>().single;
      expect(srv.enabled, false);
      expect(srv.warnings.single.reason, 'bad server');
    });

    test('без вердикта ключа в файле нет', () async {
      final out = await _export([
        _sub(disabled: {'Tokyo': DateTime.utc(2026, 9, 19)}),
      ]);
      expect(_source(out.json, 'subscription').containsKey('warnings'), false);
    });
  });
}
