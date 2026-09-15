import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:lxbox/models/custom_rule.dart';
import 'package:lxbox/models/record_codec.dart';
import 'package:lxbox/services/lx_backup.dart';

/// D-111 (BACKUP.md §2 «Одно правило — одно тело») на обоих входах LX Backup:
/// запись 1.0 с массивом тел в `body` и правило `kind: json` 0.x с массивом в
/// `match` раскладываются на записи по элементу-объекту — `имя`, `имя #2`… с
/// общими `enabled` и `num`, `id` только у первой, тело каждой части как есть.
/// Элемент не объект — `backup_unknown_field`, прочие части идут.

String _file10(List<Map<String, dynamic>> rules) => jsonEncode({
      'lx_backup': 2,
      'exported_by': {'app': 'launcher', 'version': 'test'},
      'exported_at': '2026-09-15T00:00:00Z',
      'rules': rules,
    });

String _file0x(List<Map<String, dynamic>> rules) => jsonEncode({
      'lx_backup': 1,
      'exported_by': {'app': 'lxbox', 'version': '2.23.2'},
      'exported_at': '2026-09-15T00:00:00Z',
      'rules': rules,
    });

const _first = {
  'domain_suffix': ['first.example-1.com'],
  'outbound': 'proxy',
};
const _second = {
  'ip_cidr': ['203.0.113.0/24'],
  'action': 'reject',
};
const _sniff = {'action': 'sniff', 'inbound': ['tun-in']};

/// Тело правила так, как оно уйдёт в конфиг: у json — его текст, у прочих —
/// `body` записи хранения.
Object? _body(CustomRule r) =>
    r is CustomRuleJson ? jsonDecode(r.json) : ruleToRecord(r)['body'];

List<String> _codes(LxBackupFile f) => [for (final w in f.warnings) w.code];

void main() {
  group('вход 1.0: массив тел в body', () {
    test('части по элементу: имена #N, общие enabled и num, id у первой, тело '
        'как есть, не-объект назван', () {
      final file = parseLxBackup(
        _file10([
          {
            'kind': 'inline',
            'id': 'r-arr',
            'name': 'Raw array',
            'enabled': false,
            'num': 1001,
            'body': [_first, _second, 'not a rule', _sniff],
          },
        ]),
        knownOutbounds: const {'proxy'},
      );
      expect(file.rules.map((r) => r.name),
          ['Raw array', 'Raw array #2', 'Raw array #3']);
      expect(file.rules.map((r) => r.enabled), [false, false, false]);
      expect(file.rules.map((r) => r.orderNum), [1001, 1001, 1001]);
      expect(file.rules.map(_body), [_first, _second, _sniff]);
      expect(file.rules.last, isA<CustomRuleJson>(),
          reason: 'самостоятельный action — тело целиком');
      expect(_codes(file), [kWarnUnknownField]);
      expect(file.warnings.single.detail, contains('[2]'));
      // `id` файла держит первая часть, у остальных свой: id — идентичность
      // правила, двух правил с одним id не бывает.
      expect(file.rules.first.id, 'r-arr');
      expect(file.rules.map((r) => r.id).toSet(), hasLength(3));
    });

    test('безымянная запись остаётся безымянной во всех частях', () {
      final file = parseLxBackup(_file10([
        {
          'kind': 'inline',
          'enabled': true,
          'body': [_first, _second],
        },
      ]));
      expect(file.rules.map((r) => r.name), ['', '']);
    });

    test('цель проверяется у каждой части отдельно', () {
      final file = parseLxBackup(
        _file10([
          {
            'kind': 'inline',
            'name': 'Mixed',
            'enabled': true,
            'body': [
              _first,
              {'domain': ['x.example-2.com'], 'outbound': 'nowhere'},
            ],
          },
        ]),
        knownOutbounds: const {'proxy'},
      );
      expect(file.rules.map((r) => r.enabled), [true, false]);
      expect(_codes(file), [kWarnUnknownOutbound]);
    });

    test('пустой массив — запись отброшена с названием', () {
      final file = parseLxBackup(_file10([
        {'kind': 'inline', 'name': 'Empty', 'enabled': true, 'body': <Object>[]},
      ]));
      expect(file.rules, isEmpty);
      expect(_codes(file), [kWarnUnknownField]);
    });

    test('тело-объект — одна запись', () {
      final file = parseLxBackup(_file10([
        {'kind': 'inline', 'name': 'One', 'enabled': true, 'body': _sniff},
      ]));
      expect(file.rules.map((r) => r.name), ['One']);
      expect(file.rules.map(_body), [_sniff]);
      expect(file.warnings, isEmpty);
    });
  });

  group('вход 0.x: kind json с массивом в match', () {
    test('части — правила вида json с телом элемента, общие enabled и num', () {
      final file = parseLxBackup(
        _file0x([
          {
            'kind': 'json',
            'name': 'Raw array',
            'enabled': false,
            'num': 1001,
            'match': [_first, _second, 'not a rule'],
          },
        ]),
        knownOutbounds: const {'proxy'},
      );
      expect(file.rules.map((r) => r.name), ['Raw array', 'Raw array #2']);
      expect(file.rules, everyElement(isA<CustomRuleJson>()),
          reason: 'json 0.x — сырое тело, без переписи в типизированное');
      expect(file.rules.map((r) => r.enabled), [false, false]);
      expect(file.rules.map((r) => r.orderNum), [1001, 1001]);
      expect(file.rules.map(_body), [_first, _second]);
      expect(_codes(file), [kWarnUnknownField]);
    });

    test('match-объект — одно сырое правило; не объект и не массив — отброс', () {
      final file = parseLxBackup(_file0x([
        {'kind': 'json', 'name': 'Object', 'enabled': true, 'match': _first},
        {'kind': 'json', 'name': 'Broken', 'enabled': true, 'match': 'text'},
      ]));
      expect(file.rules.map((r) => r.name), ['Object']);
      expect(file.rules.single, isA<CustomRuleJson>());
      expect(_body(file.rules.single), _first);
      expect(_codes(file), [kWarnUnknownField]);
      expect(file.warnings.single.detail, contains('Broken'));
    });

    test('части json 0.x и 1.0 одного массива дают одни и те же тела', () {
      final v0 = parseLxBackup(_file0x([
        {'kind': 'json', 'name': 'A', 'enabled': true, 'match': [_first, _sniff]},
      ]));
      final v1 = parseLxBackup(_file10([
        {
          'kind': 'inline',
          'name': 'A',
          'enabled': true,
          'body': [_first, _sniff],
        },
      ]));
      expect(v0.rules.map((r) => r.name), v1.rules.map((r) => r.name));
      expect(v0.rules.map(_body), v1.rules.map(_body));
    });
  });
}
