import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:lxbox/models/custom_rule.dart';
import 'package:lxbox/models/parser_config.dart';
import 'package:lxbox/services/builder/rule_order.dart';
import 'package:lxbox/services/l10n/locale_controller.dart';
import 'package:lxbox/services/lx_backup.dart';
import 'package:lxbox/services/template_loader.dart';

/// BACKUP.md §9 п. 7 — крайние случаи оси порядка импорта (форма лаунчера
/// `5cbcc436`): файл без номеров размечает загрузка (`markRuleOrder`) — пресеты
/// по шаблону, голова `traffic-processing` первой; частично размеченный файл
/// ставит неразмеченные корневые в хвост, но не ниже `kUserRuleNumStart`.

String _file10(List<Map<String, dynamic>> rules) => jsonEncode({
      'lx_backup': 2,
      'exported_by': {'app': 'launcher', 'version': 'test'},
      'exported_at': '2026-09-15T00:00:00Z',
      'rules': rules,
    });

String _file0x(List<Map<String, dynamic>> rules) => jsonEncode({
      'lx_backup': 1,
      'exported_by': {'app': 'launcher', 'version': '1.5.1'},
      'exported_at': '2026-09-15T00:00:00Z',
      'rules': rules,
    });

Map<String, dynamic> _inline10(String name, String domain, {int? num}) => {
      'kind': 'inline',
      'name': name,
      'enabled': true,
      'num': ?num,
      'body': {
        'domain': [domain],
        'outbound': 'direct-out',
      },
    };

Map<String, dynamic> _preset10(String ref, {int? num}) =>
    {'kind': 'preset', 'ref': ref, 'enabled': true, 'num': ?num};

List<String> _axis(List<CustomRule> rules) =>
    [for (final r in rules) '${r.name}=${r.orderNum}'];

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

  int templateNum(String presetId) =>
      template.selectableRules.firstWhere((r) => r.presetId == presetId).num;

  group('файл без номеров', () {
    for (final (format, raw) in [
      (
        '1.0',
        _file10([
          _inline10('user-a', 'a.example-1.com'),
          _preset10('block-ads'),
          _inline10('user-b', 'b.example-1.com'),
          _preset10('traffic-processing'),
        ]),
      ),
      (
        '0.x',
        _file0x([
          {
            'kind': 'inline',
            'name': 'user-a',
            'outbound': 'direct-out',
            'match': {
              'domain': ['a.example-1.com'],
            },
          },
          {'kind': 'preset', 'name': 'block-ads', 'ref': 'block-ads'},
          {
            'kind': 'inline',
            'name': 'user-b',
            'outbound': 'direct-out',
            'match': {
              'domain': ['b.example-1.com'],
            },
          },
          {
            'kind': 'preset',
            'name': 'traffic-processing',
            'ref': 'traffic-processing',
          },
        ]),
      ),
    ]) {
      test('$format: номера не проставляются, загрузка даёт пресетам номера '
          'шаблона и голову первой', () {
        final file = parseLxBackup(raw);
        final imported = renumberBackupAxis(file.rules, const [], const []);
        expect([for (final r in imported) r.name],
            ['user-a', 'block-ads', 'user-b', 'traffic-processing'],
            reason: 'порядок файла');
        expect(imported.map((r) => r.orderNum), everyElement(isNull),
            reason: 'разметка — дело загрузки, а не импорта');

        final loaded =
            normalizeRuleOrder(imported, template.selectableRules, template);
        expect(_axis(loaded), [
          'traffic-processing=${templateNum('traffic-processing')}',
          'block-ads=${templateNum('block-ads')}',
          'user-a=$kUserRuleNumStart',
          'user-b=${kUserRuleNumStart + 1}',
        ]);
        expect(templateNum('traffic-processing'), 0,
            reason: 'голова оси: sniff — первое правило route.rules');
        expect(templateNum('block-ads'), lessThan(kUserRuleNumStart));
      });
    }
  });

  group('частично размеченный файл', () {
    test('максимум ниже 1000: неразмеченные получают 1000 и дальше', () {
      final file = parseLxBackup(_file10([
        _preset10('traffic-processing', num: 0),
        _inline10('unmarked-1', 'a.example-1.com'),
        _preset10('private-ip', num: 950),
        _inline10('unmarked-2', 'b.example-1.com'),
      ]));
      final rules = renumberBackupAxis(file.rules, const [], const []);
      expect(_axis(rules), [
        'traffic-processing=0',
        'private-ip=950',
        'unmarked-1=$kUserRuleNumStart',
        'unmarked-2=${kUserRuleNumStart + 1}',
      ]);
    });

    test('максимум выше 1000: неразмеченные — за максимумом', () {
      final file = parseLxBackup(_file10([
        _inline10('unmarked', 'a.example-1.com'),
        _preset10('ru-inside', num: 1110),
        _inline10('user', 'b.example-1.com', num: 1000),
      ]));
      final rules = renumberBackupAxis(file.rules, const [], const []);
      expect(_axis(rules), ['user=1000', 'ru-inside=1110', 'unmarked=1111']);
    });
  });
}
