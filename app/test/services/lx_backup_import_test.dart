import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:lxbox/config/consts.dart';
import 'package:lxbox/models/custom_rule.dart';
import 'package:lxbox/models/direction.dart';
import 'package:lxbox/models/parser_config.dart';
import 'package:lxbox/services/l10n/locale_controller.dart';
import 'package:lxbox/services/lx_backup.dart';
import 'package:lxbox/services/lx_backup_import.dart';
import 'package:lxbox/services/settings_storage.dart';
import 'package:lxbox/services/template_loader.dart';

import '../storage_migration/golden_harness.dart';

// D-117 — импорт в пустое воспроизводит файл.
//
// BACKUP.md §3: известные цели импорта — один список после слияния (цели и
// Направления файла, их `-auto`, цепочки, корневые узлы, служебные теги
// шаблона приёмника). BACKUP.md §9 п. 7: несортируемый пресет встаёт на номер
// шаблона приёмника, откуда бы номер ни приехал.

/// Файл 1.0 со всеми видами целей, которые приезжают этим же файлом.
String _fileWithOwnTargets({
  List<Map<String, dynamic>> rules = const [],
  String? routeFinal,
}) =>
    jsonEncode({
      'lx_backup': 2,
      'exported_by': {'app': 'launcher', 'version': '1.6.0'},
      'exported_at': '2026-09-15T00:00:00Z',
      'sources': [
        {
          'kind': 'server',
          'id': '01SRVD117000000000000000000',
          'tag': 'relay-root',
          'enabled': true,
          'body': {
            'type': 'trojan',
            'server': 'example-4.com',
            'server_port': 443,
            'password': 'testpass404',
          },
        },
        {
          'kind': 'chain',
          'id': '01CHND117000000000000000000',
          'tag': 'via-relay',
          'enabled': true,
          'body': {'type': 'chain', 'idle_timeout': '0s'},
          'hops': [
            {'tag': 'relay-root'},
          ],
        },
      ],
      'directions': [
        {
          'tag': 'ru-exit',
          'filter': 'ru',
          'auto': {'url': 'http://cp.example-1.com/generate_204'},
        },
        {
          'tag': 'streaming',
          'filter': 'nl',
          'include': ['ru-exit'],
        },
      ],
      'rules': rules,
      if (routeFinal != null) 'route': {'final': routeFinal},
    });

Map<String, dynamic> _rule(String name, String outbound, int num) => {
      'kind': 'inline',
      'name': name,
      'enabled': true,
      'num': num,
      'body': {
        'domain_suffix': ['$name.example-1.com'],
        'outbound': outbound,
      },
    };

final _targetRules = [
  _rule('to-direction', 'ru-exit', 1000),
  _rule('to-chain', 'via-relay', 1001),
  _rule('to-direct-out', kDirectOutboundTag, 1002),
  _rule('to-vpn-1-auto', 'vpn-1-auto', 1003),
  _rule('to-direction-auto', 'ru-exit-auto', 1004),
  _rule('to-root-node', 'relay-root', 1005),
  _rule('to-ghost', 'ghost', 1006),
];

Map<String, bool> _enabledByName(List<CustomRule> rules) =>
    {for (final r in rules) r.name: r.enabled};

const _expectedEnabled = {
  'to-direction': true,
  'to-chain': true,
  'to-direct-out': true,
  'to-vpn-1-auto': true,
  'to-direction-auto': true,
  'to-root-node': true,
  'to-ghost': false,
};

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late WizardTemplate template;
  setUpAll(() async {
    LocaleController.I.setting = 'en';
    template = await TemplateLoader.load();
  });
  tearDownAll(() {
    TemplateLoader.invalidate();
    LocaleController.I.setting = 'system';
  });

  group('D-117 известные цели: план импорта', () {
    test('служебные теги шаблона — outbound\'ы config и magic_nodes', () {
      expect(templateSystemTags(template),
          containsAll([kDirectOutboundTag, kBlockOutboundTag]));
    });

    test('пустой приёмник с шаблоном: цели, приехавшие файлом, и служебные '
        'теги не выключают правила; route.final на цель файла применён; '
        'include на Направление файла цел', () {
      // vpn-1 приёмника с автовыбором: так его сидит шаблон.
      final receiver = LxImportReceiver(
        directions: [
          Direction(
            tag: 'vpn-1',
            label: 'VPN 1',
            enabled: true,
            auto: const DirectionAuto(),
          ),
        ],
        systemTags: templateSystemTags(template),
        selectableRules: template.selectableRules,
      );
      final plan = planLxBackupImport(
        _fileWithOwnTargets(rules: _targetRules, routeFinal: 'ru-exit'),
        receiver,
      );

      expect(_enabledByName(plan.rules), _expectedEnabled);
      expect(
          [for (final w in plan.file.warnings) '${w.code} ${w.detail}'],
          ['$kWarnUnknownOutbound to-ghost → ghost'],
          reason: 'единственная неизвестная цель — ghost');
      expect(plan.file.routeFinal, 'ru-exit');
      expect(plan.knownTargets,
          containsAll(['ru-exit', 'ru-exit-auto', 'via-relay', 'relay-root',
            'vpn-1', 'vpn-1-auto', kDirectOutboundTag, kBlockOutboundTag]));
      final streaming =
          plan.directions.singleWhere((d) => d.tag == 'streaming');
      expect(streaming.include, ['ru-exit']);
      expect(plan.appliedChains, 1);
    });

    test('route.final на цель, которой нет нигде, не применяется', () {
      final plan = planLxBackupImport(
        _fileWithOwnTargets(routeFinal: 'vpn-9'),
        LxImportReceiver(systemTags: templateSystemTags(template)),
      );
      expect(plan.file.routeFinal, isNull);
      expect(plan.file.warnings.map((w) => w.code), [kWarnFinalDropped]);
    });

    test('-auto Направления без автовыбора — не цель', () {
      final plan = planLxBackupImport(
        _fileWithOwnTargets(
            rules: [_rule('to-streaming-auto', 'streaming-auto', 1000)]),
        LxImportReceiver(systemTags: templateSystemTags(template)),
      );
      expect(plan.rules.single.enabled, isFalse);
    });

    test('Направление файла, отсеянное гейтом тегов, целью не становится', () {
      final raw = jsonEncode({
        'lx_backup': 1,
        'exported_by': {'app': 'launcher', 'version': '1.5.1'},
        'exported_at': '2026-09-15T00:00:00Z',
        'directions': [
          {'tag': 'block-out', 'filter': 'x'},
        ],
        'rules': [
          {
            'kind': 'inline',
            'name': 'to-block-out',
            'outbound': 'block-out',
            'num': 1000,
            'match': {
              'domain': ['a.example-1.com'],
            },
          },
        ],
      });
      final plan = planLxBackupImport(
        raw,
        LxImportReceiver(systemTags: templateSystemTags(template)),
      );
      expect(plan.appliedDirections, 0);
      expect(plan.rules.single.enabled, isFalse,
          reason: 'block-out — служебный тег сборки, Направлению не положен');
    });

    test('приёмнику нечего сказать о целях — цели не режутся', () {
      final raw = jsonEncode({
        'lx_backup': 2,
        'exported_by': {'app': 'launcher', 'version': '1.6.0'},
        'exported_at': '2026-09-15T00:00:00Z',
        'rules': [_rule('to-ghost', 'ghost', 1000)],
        'route': {'final': 'ghost'},
      });
      final plan = planLxBackupImport(raw, const LxImportReceiver());
      expect(plan.knownTargets, isNull);
      expect(plan.rules.single.enabled, isTrue);
      expect(plan.file.routeFinal, 'ghost');
      expect(plan.file.warnings, isEmpty);
    });

    test('0.x: те же цели тем же списком', () {
      final raw = jsonEncode({
        'lx_backup': 1,
        'exported_by': {'app': 'launcher', 'version': '1.5.1'},
        'exported_at': '2026-09-15T00:00:00Z',
        'directions': [
          {
            'tag': 'ru-exit',
            'filter': 'ru',
            'auto': {'url': 'http://cp.example-1.com/generate_204'},
          },
        ],
        'servers': [
          {
            'id': '01SRVD1170X0000000000000000',
            'node_tag': 'relay-root',
            'uri': 'trojan://testpass404@example-4.com:443#relay-root',
          },
        ],
        'rules': [
          for (final (name, target) in const [
            ('to-direction-auto', 'ru-exit-auto'),
            ('to-root-node', 'relay-root'),
            ('to-direct-out', kDirectOutboundTag),
          ])
            {
              'kind': 'inline',
              'name': name,
              'outbound': target,
              'num': 1000,
              'match': {
                'domain': ['$name.example-1.com'],
              },
            },
        ],
        'route': {'final': 'ru-exit-auto'},
      });
      final plan = planLxBackupImport(
        raw,
        LxImportReceiver(systemTags: templateSystemTags(template)),
      );
      expect(plan.rules.map((r) => r.enabled), everyElement(isTrue));
      expect(plan.file.routeFinal, 'ru-exit-auto');
      expect(plan.file.warnings, isEmpty);
    });
  });

  group('D-117 известные цели: сервис в пустом хранении', () {
    test('импорт в пустое хранение не выключает правила на цели файла, '
        'direct-out и vpn-1-auto; route.final и include сохранены', () async {
      final box = await StorageSandbox.create();
      addTearDown(box.dispose);
      // Свежая установка: `main()` до первого экрана сидит Направления
      // шаблона (vpn-1 с автовыбором), других записей нет.
      await SettingsStorage.migrateDirectionsIfNeeded(
        template.groupTemplates,
        varDefaults: {for (final v in template.vars) v.name: v.defaultValue},
      );
      expect(await SettingsStorage.getCustomRules(), isEmpty);
      expect(await SettingsStorage.getServerLists(), isEmpty);

      const importer = LxBackupImportService();
      final preview = await importer.prepare(
          _fileWithOwnTargets(rules: _targetRules, routeFinal: 'via-relay'));
      expect(preview.file.warnings.map((w) => w.detail),
          ['to-ghost → ghost'],
          reason: 'превью называет ровно то, что не применится');

      final result = await importer.apply(preview);
      expect(result.appliedDirections, 2);
      expect(result.appliedChains, 1);

      final rules = await SettingsStorage.getCustomRules();
      expect(_enabledByName(rules), _expectedEnabled);
      expect(await SettingsStorage.getRouteFinal(), 'via-relay');
      final directions = await SettingsStorage.getDirections();
      expect(directions.map((d) => d.tag),
          containsAll(['vpn-1', 'ru-exit', 'streaming']));
      expect(directions.singleWhere((d) => d.tag == 'streaming').include,
          ['ru-exit']);
      expect((await SettingsStorage.getChains()).map((c) => c.tag),
          ['via-relay']);
    });
  });

  group('D-117 голова оси после импорта', () {
    test('несортируемый пресет со сдвинутым номером встаёт на номер шаблона, '
        'сортируемый пресет и правило пользователя держат номер файла', () {
      int templateNum(String id) =>
          template.selectableRules.firstWhere((r) => r.presetId == id).num;
      // Ось сплошной нумерации лаунчера 1.5.3–1.5.6: голова уехала на 1000.
      final raw = jsonEncode({
        'lx_backup': 2,
        'exported_by': {'app': 'launcher', 'version': '1.5.5'},
        'exported_at': '2026-09-15T00:00:00Z',
        'rules': [
          {'kind': 'preset', 'ref': 'traffic-processing', 'enabled': true,
            'num': 1000},
          {'kind': 'preset', 'ref': 'block-ads', 'enabled': true, 'num': 1001},
          _rule('user', kDirectOutboundTag, 1002),
        ],
      });
      final plan = planLxBackupImport(
        raw,
        LxImportReceiver(
          systemTags: templateSystemTags(template),
          selectableRules: template.selectableRules,
        ),
      );
      expect(
        [for (final r in plan.rules) '${r.name}=${r.orderNum}'],
        [
          'traffic-processing=${templateNum('traffic-processing')}',
          'block-ads=1001',
          'user=1002',
        ],
      );
      expect(templateNum('traffic-processing'), isNot(1000));
    });

    test('без шаблона у приёмника номер головы из файла не трогается', () {
      final raw = jsonEncode({
        'lx_backup': 2,
        'exported_by': {'app': 'launcher', 'version': '1.5.5'},
        'exported_at': '2026-09-15T00:00:00Z',
        'rules': [
          {'kind': 'preset', 'ref': 'traffic-processing', 'enabled': true,
            'num': 1000},
        ],
      });
      final plan = planLxBackupImport(raw, const LxImportReceiver());
      expect(plan.rules.single.orderNum, 1000);
    });
  });
}
