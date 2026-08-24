import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:lxbox/models/custom_rule.dart';
import 'package:lxbox/models/direction.dart';
import 'package:lxbox/services/lx_backup.dart';

// LX Backup v1, сторона LxBox (SPEC 103, фаза 4).
//
// Парные тесты к core/backup/*_test.go в лаунчере: перенос настроек между
// приложениями имеет смысл ровно настолько, насколько обе стороны одинаково
// понимают битую ссылку, непереносимую переменную и чужой блок extensions.

const _contractRoot = 'contract';

void main() {
  group('LX Backup: словарь переносимых переменных', () {
    test('совпадает с реестром', () {
      final file = File('$_contractRoot/registry/vars.json');
      if (!file.existsSync()) {
        markTestSkipped('контракт не синхронизирован');
        return;
      }
      final data = jsonDecode(file.readAsStringSync()) as Map<String, dynamic>;
      final vars = (data['vars'] as Map).cast<String, dynamic>();
      final registryPortable = <String>{
        for (final e in vars.entries)
          if ((e.value as Map)['portable'] == true) e.key,
      };
      expect(kLxPortableVars, registryPortable,
          reason: 'список переносимых переменных разошёлся с реестром: '
              'бэкап либо теряет настройку, либо тащит на чужую машину '
              'значение, которое там значит другое');
    });
  });

  group('LX Backup: импорт', () {
    // Ссылка в никуда не повод терять правило — оно приезжает выключенным.
    // Включённое правило с несуществующей целью роняет конфиг ядра целиком.
    test('несуществующий outbound выключает правило', () {
      final raw = jsonEncode({
        'lx_backup': 1,
        'exported_by': {'app': 'launcher', 'version': '1.4.2'},
        'exported_at': '2026-08-22T00:00:00Z',
        'rules': [
          {
            'kind': 'inline', 'name': 'Ghost', 'outbound': 'vpn-9', 'num': 1000,
            'match': {'domain_suffix': ['x.example-1.com']},
          },
        ],
      });
      final file = parseLxBackup(raw, knownOutbounds: {'proxy'});
      expect(file.rules, hasLength(1));
      expect(file.rules.single.enabled, isFalse,
          reason: 'правило с мёртвой целью приехало включённым — ядро отвергнет конфиг');
      expect(file.warnings.map((w) => w.code), contains(kWarnUnknownOutbound));
    });

    test('зарезервированные литералы известны всегда', () {
      for (final tag in ['direct', 'block', 'reject', 'drop']) {
        final raw = jsonEncode({
          'lx_backup': 1,
          'exported_by': {'app': 'launcher'},
          'exported_at': '2026-08-22T00:00:00Z',
          'rules': [
            {'kind': 'inline', 'name': 'R', 'outbound': tag, 'match': {}},
          ],
        });
        final file = parseLxBackup(raw, knownOutbounds: {'proxy'});
        expect(file.rules.single.enabled, isTrue, reason: 'литерал $tag');
        expect(file.warnings.map((w) => w.code),
            isNot(contains(kWarnUnknownOutbound)));
      }
    });

    test('route.final в никуда не применяется', () {
      final raw = jsonEncode({
        'lx_backup': 1,
        'exported_by': {'app': 'launcher'},
        'exported_at': '2026-08-22T00:00:00Z',
        'route': {'final': 'vpn-9'},
      });
      final file = parseLxBackup(raw, knownOutbounds: {'proxy'});
      expect(file.routeFinal, isNull);
      expect(file.warnings.map((w) => w.code), contains(kWarnFinalDropped));
    });

    test('непереносимая переменная пропускается с warning', () {
      final raw = jsonEncode({
        'lx_backup': 1,
        'exported_by': {'app': 'launcher'},
        'exported_at': '2026-08-22T00:00:00Z',
        'vars': {'log_level': 'debug', 'tun_interface': 'utun0'},
      });
      final file = parseLxBackup(raw);
      expect(file.vars, {'log_level': 'debug'});
      expect(file.warnings.map((w) => w.code), contains(kWarnVarSkipped));
    });

    test('чужой extensions сохраняется целиком', () {
      final foreign = {'state_version': 6, 'skip': [{'field': 'tag'}]};
      final raw = jsonEncode({
        'lx_backup': 1,
        'exported_by': {'app': 'launcher'},
        'exported_at': '2026-08-22T00:00:00Z',
        'extensions': {'launcher': foreign},
      });
      final file = parseLxBackup(raw);
      expect(file.foreignExtensions['launcher'], foreign,
          reason: 'блоб чужой стороны изменён — обратный экспорт обеднеет');
    });

    test('версия новее поддерживаемой отвергается', () {
      final raw = jsonEncode({
        'lx_backup': kLxBackupVersion + 1,
        'exported_by': {'app': 'launcher'},
        'exported_at': '2026-08-22T00:00:00Z',
      });
      expect(() => parseLxBackup(raw), throwsFormatException);
    });

    test('чужой файл не притворяется бэкапом', () {
      expect(() => parseLxBackup('{"outbounds":[]}'), throwsFormatException);
    });

    test('неизвестный ключ корня назван, но файл читается', () {
      final raw = jsonEncode({
        'lx_backup': 1,
        'exported_by': {'app': 'launcher'},
        'exported_at': '2026-08-22T00:00:00Z',
        'channels': [{'id': 1}],
      });
      final file = parseLxBackup(raw);
      expect(file.version, 1);
      expect(file.warnings.map((w) => w.code), contains(kWarnUnknownField));
    });

    test('порядок правил сохраняется по оси num', () {
      final raw = jsonEncode({
        'lx_backup': 1,
        'exported_by': {'app': 'launcher'},
        'exported_at': '2026-08-22T00:00:00Z',
        'rules': [
          {'kind': 'inline', 'name': 'third', 'num': 9000, 'outbound': 'direct', 'match': {}},
          {'kind': 'inline', 'name': 'first', 'num': 10, 'outbound': 'direct', 'match': {}},
          {'kind': 'inline', 'name': 'second', 'num': 500, 'outbound': 'direct', 'match': {}},
        ],
      });
      final file = parseLxBackup(raw);
      expect(file.rules.map((r) => r.name), ['first', 'second', 'third']);
    });
  });

  group('LX Backup: экспорт', () {
    test('mobile-only матчеры уезжают в extensions, а не теряются', () async {
      final rule = CustomRuleInline(
        name: 'Apps',
        orderNum: 1000,
        domainSuffixes: ['example-1.com'],
        packages: ['com.example.app'],
        wifiSsids: ['HomeNet'],
        outbound: 'direct',
      );
      final raw = await buildLxBackup(
        lists: const [],
        rules: [rule],
        vars: const {'log_level': 'debug', 'tun_interface': 'utun0'},
      );
      final doc = jsonDecode(raw) as Map<String, dynamic>;

      final exported = (doc['rules'] as List).single as Map<String, dynamic>;
      expect((exported['match'] as Map)['domain_suffix'], ['example-1.com']);
      final ext = (exported['extensions'] as Map)['lxbox'] as Map;
      expect(ext['packages'], ['com.example.app']);
      expect(ext['wifiSsids'], ['HomeNet']);

      // Переменные — только переносимые.
      expect(doc['vars'], {'log_level': 'debug'});
    });

    // Round-trip: правило, прошедшее экспорт и импорт, сохраняет и общую
    // часть, и mobile-only матчеры.
    test('round-trip сохраняет mobile-only поля', () async {
      final rule = CustomRuleInline(
        name: 'Apps',
        orderNum: 1000,
        domainSuffixes: ['example-1.com'],
        packages: ['com.example.app'],
        wifiSsids: ['HomeNet'],
        outbound: 'direct',
      );
      final raw = await buildLxBackup(lists: const [], rules: [rule], vars: const {});
      final back = parseLxBackup(raw, knownOutbounds: {'direct'});

      expect(back.rules, hasLength(1));
      final got = back.rules.single as CustomRuleInline;
      expect(got.name, 'Apps');
      expect(got.domainSuffixes, ['example-1.com']);
      expect(got.packages, ['com.example.app'],
          reason: 'mobile-only матчер потерян на round-trip');
      expect(got.wifiSsids, ['HomeNet']);
      expect(got.outbound, 'direct');
    });
  });

  // §393 B1/B2 — Направления едут вместе с правилами (BACKUP.md §3, схема
  // v1.1). Переносится КАНОН (`schema/direction.schema.json`), а не внутренняя
  // структура: у сторон они разные.
  group('LX Backup: Направления', () {
    test('приехавшая цель делает правило РАБОЧИМ, а не выключенным', () {
      const raw = '''
{
  "lx_backup": 1,
  "directions": [{"tag": "ru-exit", "label": "Россия", "filter": "RU"}],
  "rules": [{"kind": "inline", "name": "R", "outbound": "ru-exit", "num": 1}]
}''';
      // knownOutbounds намеренно НЕ содержит ru-exit: цель приезжает в этом
      // же файле, и только порядок «Направления раньше правил» спасает.
      final file = parseLxBackup(raw, knownOutbounds: {'vpn-1'});
      expect(file.directions.single.tag, 'ru-exit');
      expect(file.rules.single.enabled, isTrue,
          reason: 'цель приехала в файле — правило обязано прийти рабочим');
      expect(file.warnings, isEmpty);
    });

    test('занятый тег не применяется и назван warning\'ом', () {
      const raw = '''
{
  "lx_backup": 1,
  "directions": [{"tag": "vpn-1", "label": "Чужая"}],
  "rules": [{"kind": "inline", "name": "R", "outbound": "vpn-1", "num": 1}]
}''';
      final file = parseLxBackup(raw, knownOutbounds: {'vpn-1'});
      expect(file.directions, isEmpty,
          reason: 'перезапись стёрла бы настройки пользователя');
      expect(file.warnings.map((w) => w.code), [kWarnDirectionExists]);
      // Тег всё равно известен — правило цель находит, она просто своя.
      expect(file.rules.single.enabled, isTrue);
    });

    test('канон → модель: флаги, тело фильтра, enabled по умолчанию', () {
      const raw = '''
{
  "lx_backup": 1,
  "directions": [{
    "tag": "de",
    "filter": "DE|Germany",
    "invert": true,
    "default": "premium",
    "include_direct": true,
    "include_block": true,
    "include": ["vpn-1"],
    "auto": {"mode": "round_robin", "interval": "9m", "pool": 5}
  }]
}''';
      final d = parseLxBackup(raw).directions.single;
      expect(d.enabled, isTrue, reason: 'отсутствие ключа = true по схеме');
      expect(d.label, '', reason: 'пустое имя законно — показываем tag');
      expect(d.nodeFilter, 'DE|Germany', reason: 'фильтр едет ТЕЛОМ regex');
      expect(d.nodeFilterInvert, isTrue);
      expect(d.defaultFilter, 'premium');
      expect(d.includeDirect, isTrue);
      expect(d.includeBlock, isTrue);
      expect(d.include, ['vpn-1']);
      expect(d.auto!.mode, UrltestMode.roundRobin);
      expect(d.auto!.interval, '9m');
      expect(d.auto!.pool, 5);
      // Незаданное берётся своим умолчанием, а не чужим нулём.
      expect(d.auto!.tolerance, const DirectionAuto().tolerance);
    });

    test('round-trip сохраняет отбор, флаги и автовыбор', () async {
      const src = Direction(
        tag: 'de',
        label: 'Германия',
        enabled: false,
        nodeFilter: 'DE',
        nodeFilterInvert: true,
        defaultFilter: 'premium',
        includeDirect: true,
        include: ['vpn-1'],
        auto: DirectionAuto(interval: '9m', tolerance: 120),
      );
      final raw = await buildLxBackup(
        lists: const [],
        rules: const [],
        vars: const {},
        directions: const [src],
      );
      final doc = jsonDecode(raw) as Map<String, dynamic>;
      final exported = (doc['directions'] as List).single as Map<String, dynamic>;
      expect(exported['filter'], 'DE', reason: 'обёртка/флаги в тело не лезут');
      expect(exported['enabled'], false);

      final back = parseLxBackup(raw).directions.single;
      expect(back.tag, 'de');
      expect(back.label, 'Германия');
      expect(back.enabled, isFalse);
      expect(back.nodeFilter, 'DE');
      expect(back.nodeFilterInvert, isTrue);
      expect(back.defaultFilter, 'premium');
      expect(back.includeDirect, isTrue);
      expect(back.includeBlock, isFalse);
      expect(back.include, ['vpn-1']);
      expect(back.auto!.interval, '9m');
      expect(back.auto!.tolerance, 120);
    });

    test('неизвестное поле записи названо, а не съедено (default-deny)', () {
      const raw = '''
{
  "lx_backup": 1,
  "directions": [{"tag": "de", "sorcery": true}]
}''';
      final file = parseLxBackup(raw);
      expect(file.directions.single.tag, 'de');
      expect(file.warnings.map((w) => w.detail), ['directions[].sorcery']);
    });
  });
}
