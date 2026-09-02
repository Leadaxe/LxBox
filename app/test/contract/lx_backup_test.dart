import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:lxbox/models/custom_rule.dart';
import 'package:lxbox/models/direction.dart';
import 'package:lxbox/models/server_list.dart';
import 'package:lxbox/models/source_chain.dart';
import 'package:lxbox/services/dns/dns_backup.dart';
import 'package:lxbox/services/lx_backup.dart';
import 'package:lxbox/services/warp/masque_account.dart';
import 'package:lxbox/services/warp/warp_account.dart';
import 'package:lxbox/services/warp/warp_backup.dart';

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

  // §393 B7-B11 — секции, которые до хвоста фазы B либо разбирались и
  // выбрасывались, либо не существовали вовсе. Каждый тест сформулирован как
  // круг: то, что уехало, обязано вернуться — это и есть инвариант §1
  // BACKUP.md, а не «поле сериализуется».
  // §393 C9 — цепочки хопов (SPEC 110, схема v1.2). Парные тесты к
  // core/backup/backup_test.go: TestRoundTripChainSources и
  // TestImportChainTagBusy.
  group('LX Backup: цепочки хопов', () {
    test('приехавшая цепочка делает правило РАБОЧИМ, а не выключенным', () {
      const raw = '''
{
  "lx_backup": 1,
  "chains": [{"tag": "relay", "chain": {"hops": ["vpn-de", "exit"]}}],
  "rules": [{"kind": "inline", "name": "R", "outbound": "relay", "num": 1}]
}''';
      // knownOutbounds намеренно НЕ содержит relay: цель приезжает в этом же
      // файле, и только порядок «цепочки раньше правил» спасает.
      final file = parseLxBackup(raw, knownOutbounds: {'vpn-1'});
      expect(file.chains.single.tag, 'relay');
      expect(file.rules.single.enabled, isTrue,
          reason: 'цель приехала в файле — правило обязано прийти рабочим');
      expect(file.warnings, isEmpty);
    });

    // Парный к Go TestImportChainTagBusy: своя цепочка сильнее приехавшей,
    // и пропуск предъявляется ВСЕГДА — молчание склеило бы случайных тёзок.
    test('занятый тег: своя цепочка остаётся, приехавшая пропущена', () {
      const raw = '''
{
  "lx_backup": 1,
  "chains": [{"tag": "relay", "chain": {"hops": ["theirs-1", "theirs-2"]}}],
  "rules": [{"kind": "inline", "name": "R", "outbound": "relay", "num": 1}]
}''';
      // Своя цепочка `relay` уже заведена: этот набор — ровно то, что экран
      // берёт из `SettingsStorage.getChains()`.
      final file = parseLxBackup(
        raw,
        knownOutbounds: {'relay'},
        knownChains: {'relay'},
      );
      expect(file.chains, isEmpty,
          reason: 'перезапись стёрла бы маршрут пользователя');
      expect(file.warnings.map((w) => w.code), [kWarnChainExists]);
      // Тег всё равно известен — правило цель находит, она просто своя.
      expect(file.rules.single.enabled, isTrue);
    });

    // Дубль ВНУТРИ файла — тот же код-путь, что и тёзка локальной цепочки:
    // набор занятых тегов общий, поэтому first-wins по порядку файла.
    test('дубль внутри файла: побеждает первая запись', () {
      const raw = '''
{
  "lx_backup": 1,
  "chains": [
    {"tag": "relay", "chain": {"hops": ["hop-1", "hop-2"]}},
    {"tag": "relay", "chain": {"hops": ["hop-3", "hop-4"]}}
  ]
}''';
      final file = parseLxBackup(raw);
      expect(file.chains, hasLength(1));
      expect(file.chains.single.hops, ['hop-1', 'hop-2'],
          reason: 'порядок файла нормативен — побеждает первая');
      expect(file.warnings.map((w) => w.code), [kWarnChainExists]);
    });

    test('канон → модель: трёхзначный strip_evasion, strip, rewrite', () {
      const raw = '''
{
  "lx_backup": 1,
  "chains": [{
    "tag": "relay",
    "label": "Мой маршрут",
    "chain": {
      "hops": ["a", "b"],
      "idle_timeout": "0s",
      "strip_evasion": false,
      "strip": {"tls.utls": false, "xhttp.padding": true},
      "rewrite": {"vless": {"flow": null}}
    }
  }]
}''';
      final c = parseLxBackup(raw).chains.single;
      expect(c.enabled, isTrue, reason: 'отсутствие ключа = true по схеме');
      expect(c.hops, ['a', 'b']);
      expect(c.idleTimeout, '0s');
      // Трёхзначность: явный false НЕ должен слипаться с «ключа не было».
      expect(c.stripEvasion, isFalse);
      expect(c.strip, {'xhttp.padding': true, 'tls.utls': false});
      expect(c.rewrite, {
        'vless': {'flow': null},
      });
      expect(
        (c.rewrite['vless'] as Map).containsKey('flow'),
        isTrue,
        reason: 'null внутри rewrite = удаление ключа по RFC 7396, '
            'схлопывать его значит поменять патч',
      );
    });

    test('ключа strip_evasion не было → null, а не false', () {
      const raw = '''
{
  "lx_backup": 1,
  "chains": [{"tag": "relay", "chain": {"hops": ["a", "b"]}}]
}''';
      final c = parseLxBackup(raw).chains.single;
      expect(c.stripEvasion, isNull,
          reason: 'умолчание ядра (true) и явное выключение — разные вещи');
    });

    test('битая запись пропускается молча: нет тега / нет канона', () {
      const raw = '''
{
  "lx_backup": 1,
  "chains": [
    {"tag": "", "chain": {"hops": ["a", "b"]}},
    {"tag": "no-canon"},
    {"tag": "ok", "chain": {"hops": ["a", "b"]}}
  ]
}''';
      final file = parseLxBackup(raw);
      expect(file.chains.map((c) => c.tag), ['ok'],
          reason: 'защита от правленого файла, как у directions[]');
      expect(file.warnings, isEmpty);
    });

    test('неизвестный ключ записи назван, а не съеден молча', () {
      const raw = '''
{
  "lx_backup": 1,
  "chains": [{
    "tag": "relay",
    "chain": {"hops": ["a", "b"]},
    "sorcery": {"launcher_only": true}
  }]
}''';
      final file = parseLxBackup(raw);
      expect(file.chains.single.tag, 'relay');
      expect(file.warnings.map((w) => w.code), [kWarnUnknownField]);
      expect(file.warnings.single.detail, 'chains[].sorcery');
    });

    test('корневая секция chains не даёт ложный backup_unknown_field', () {
      const raw = '''
{
  "lx_backup": 1,
  "chains": [{"tag": "relay", "chain": {"hops": ["a", "b"]}}]
}''';
      expect(parseLxBackup(raw).warnings, isEmpty);
    });

    // Парный к Go TestRoundTripChainSources.
    test('round-trip: канон переживает экспорт→импорт дословно', () async {
      const source = SourceChain(
        tag: 'chain-1',
        hops: ['warp', 'vpn ②'],
        idleTimeout: '0s',
        stripEvasion: false,
        strip: {'tls.utls': false},
        // RFC 7396: null удаляет ключ и обязан пережить перенос как есть.
        rewrite: {
          'vless': {'flow': null},
        },
      );

      final out = await buildLxBackup(
        lists: const [],
        rules: const [],
        vars: const {},
        chains: const [source],
      );
      final doc = jsonDecode(out) as Map<String, dynamic>;
      final entry = (doc['chains'] as List).single as Map<String, dynamic>;
      expect(entry['tag'], 'chain-1');
      // Контракт 0.9.0 / D-082 — `label` не эмитится ни на одном уровне.
      expect(entry.containsKey('label'), isFalse);
      expect(entry.containsKey('enabled'), isFalse,
          reason: 'включённая — умолчание схемы, ключ был бы шумом');
      // Идентичность записи живёт уровнем выше канона: `chain` описывает
      // только МАРШРУТ (`additionalProperties: false` у схемы источника).
      final canon = entry['chain'] as Map<String, dynamic>;
      expect(canon.containsKey('tag'), isFalse);
      expect(canon.containsKey('label'), isFalse);
      expect(canon.containsKey('enabled'), isFalse);
      expect(canon['strip_evasion'], isFalse);
      expect(canon['rewrite'], {
        'vless': {'flow': null},
      });

      final back = parseLxBackup(out).chains.single;
      expect(back.tag, source.tag);
      expect(back.hops, source.hops);
      expect(back.idleTimeout, source.idleTimeout);
      expect(back.stripEvasion, isFalse);
      expect(back.strip, source.strip);
      expect(back.rewrite, source.rewrite);
    });

    test('label не пишется никогда (контракт 0.9.0 / D-082)', () async {
      final out = await buildLxBackup(
        lists: const [],
        rules: const [],
        vars: const {},
        chains: const [
          SourceChain(tag: 'chain-1', hops: ['a', 'b']),
          SourceChain(tag: 'chain-2', hops: ['a', 'b']),
        ],
      );
      final entries =
          ((jsonDecode(out) as Map<String, dynamic>)['chains'] as List)
              .cast<Map<String, dynamic>>();
      for (final e in entries) {
        expect(e.containsKey('label'), isFalse,
            reason: 'у цепочки одно имя — её tag; лаунчер (D-079) чужой '
                'label тоже не применяет и не пишет');
      }
    });

    test('выключенная цепочка едет ключом enabled: false', () async {
      final out = await buildLxBackup(
        lists: const [],
        rules: const [],
        vars: const {},
        chains: const [
          SourceChain(tag: 'off', enabled: false, hops: ['a', 'b']),
        ],
      );
      final entry =
          (((jsonDecode(out) as Map<String, dynamic>)['chains'] as List).single)
              as Map<String, dynamic>;
      expect(entry['enabled'], isFalse);
      expect(parseLxBackup(out).chains.single.enabled, isFalse);
    });

    test('порядок записей не сортируется ни на импорте, ни на экспорте',
        () async {
      // Ссылка на цепочку выше по списку = антицикл: перестановка сломала бы
      // ровно тот инвариант, ради которого порядок объявлен нормативным.
      const chains = [
        SourceChain(tag: 'z-first', hops: ['a', 'b']),
        SourceChain(tag: 'a-second', hops: ['z-first', 'c']),
      ];
      final out = await buildLxBackup(
        lists: const [],
        rules: const [],
        vars: const {},
        chains: chains,
      );
      final tags = [
        for (final e
            in ((jsonDecode(out) as Map<String, dynamic>)['chains'] as List))
          (e as Map<String, dynamic>)['tag'],
      ];
      expect(tags, ['z-first', 'a-second'], reason: 'экспорт не сортирует');
      expect(parseLxBackup(out).chains.map((c) => c.tag),
          ['z-first', 'a-second'],
          reason: 'импорт не сортирует');
    });
  });

  group('LX Backup: секции обмена', () {
    // §393 B7 — самый дорогой из инвариантов: блоб чужого приложения обязан
    // пережить круг launcher→LxBox→launcher БАЙТ В БАЙТ. Обеднение здесь
    // молчаливое — мобила о содержимом ничего не знает и предъявить
    // пользователю не может.
    test('чужой блоб переживает круг байт-в-байт', () async {
      const launcherBlob = {
        'state_version': 6,
        'chains': [
          {'label': 'ru→de', 'hops': ['vpn-1', 'vpn-2']},
        ],
        'skip': [
          {'field': 'tag', 'contains': 'trial'},
        ],
      };
      final incoming = jsonEncode({
        'lx_backup': 1,
        'exported_by': {'app': 'launcher', 'version': '1.5.1'},
        'exported_at': '2026-08-22T00:00:00Z',
        'extensions': {'launcher': launcherBlob},
      });

      final parsed = parseLxBackup(incoming);
      expect(parsed.foreignExtensions['launcher'], launcherBlob);

      // Экспорт возвращает блоб как есть — тот же путь, что в UI: то, что
      // легло в storage на импорте, кладётся обратно в файл.
      final out = await buildLxBackup(
        lists: const [],
        rules: const [],
        vars: const {},
        foreignExtensions: parsed.foreignExtensions,
      );
      final doc = jsonDecode(out) as Map<String, dynamic>;
      expect((doc['extensions'] as Map)['launcher'], launcherBlob,
          reason: 'блоб лаунчера обеднел на круге — цепочки хопов пропали');
    });

    test('свой блоб в чужие не попадает и обратно не возвращается', () async {
      final incoming = jsonEncode({
        'lx_backup': 1,
        'exported_by': {'app': 'lxbox', 'version': '2.0.0'},
        'exported_at': '2026-08-22T00:00:00Z',
        'extensions': {
          'lxbox': {'folders': ['work']},
          'launcher': {'state_version': 6},
        },
      });
      final parsed = parseLxBackup(incoming);
      expect(parsed.foreignExtensions.containsKey('lxbox'), isFalse,
          reason: 'своё применяется полями, а не хранится как чужой груз');

      // Даже если своё положат в чужие руками — экспорт его не вернёт:
      // `extensions.lxbox` наполняется своими данными, а не копией себя.
      final out = await buildLxBackup(
        lists: const [],
        rules: const [],
        vars: const {},
        foreignExtensions: const {
          'lxbox': {'folders': ['work']},
          'launcher': {'state_version': 6},
        },
      );
      final ext = (jsonDecode(out) as Map<String, dynamic>)['extensions'] as Map;
      expect(ext.containsKey('lxbox'), isFalse);
      expect(ext['launcher'], {'state_version': 6});
    });

    // §393 B10 — подписка: до B10 экспорт писал url/label/prefix, а импорт
    // складывал сырой Map и не применял ничего.
    test('подписка: disabled-хеши, tag и период обновления едут', () async {
      final list = SubscriptionServers(
        id: 'sub-1',
        name: 'Main',
        enabled: true,
        tagPrefix: 'MN',
        detourPolicy: DetourPolicy.defaults,
        url: 'https://example-1.com/sub',
        updateIntervalHours: 6,
        disabledHashes: {
          'a' * 64: DateTime.utc(2025, 6, 15, 12),
        },
      );
      final raw = await buildLxBackup(
        lists: [list],
        rules: const [],
        vars: const {},
      );
      final doc = jsonDecode(raw) as Map<String, dynamic>;
      final sub = (doc['subscriptions'] as List).single as Map<String, dynamic>;
      expect(sub['url'], 'https://example-1.com/sub');
      expect((sub['tag'] as Map)['prefix'], 'MN');
      expect((sub['update'] as Map)['interval_hours'], 6);
      // §4 BACKUP.md — значения в unix seconds, а не в ISO-8601 мобилы.
      expect((sub['disabled'] as Map)['a' * 64],
          DateTime.utc(2025, 6, 15, 12).millisecondsSinceEpoch ~/ 1000);

      final back = parseLxBackup(raw).subscriptions.single;
      expect(back.url, 'https://example-1.com/sub');
      expect(back.label, 'Main');
      expect(back.tagPrefix, 'MN');
      expect(back.updateIntervalHours, 6);
      expect(back.disabled.keys, ['a' * 64]);
    });

    // §393 B11 — поля чужой схемы (`skip`/`max_nodes` лаунчера) мобила
    // применить не может, но обязана вернуть на верхний уровень записи.
    test('непонятые поля подписки возвращаются на место', () async {
      final incoming = jsonEncode({
        'lx_backup': 1,
        'exported_by': {'app': 'launcher', 'version': '1.5.1'},
        'exported_at': '2026-08-22T00:00:00Z',
        'subscriptions': [
          {
            'url': 'https://example-1.com/sub',
            'label': 'Main',
            'max_nodes': 40,
            'skip': true,
            'tag': {'prefix': 'MN', 'postfix': ' ✦', 'mask': '*'},
            'detour': {'tag': 'vpn-2'},
          },
        ],
      });
      final parsed = parseLxBackup(incoming);
      final sub = parsed.subscriptions.single;
      expect(sub.maxNodes, 40);
      expect(sub.skip, isTrue);
      expect(sub.tagPostfix, ' ✦');
      // Всё это лежит в грузе для re-export, а не выброшено.
      expect(sub.unknownFields['max_nodes'], 40);
      expect(sub.unknownFields['skip'], isTrue);
      expect((sub.unknownFields['tag'] as Map)['postfix'], ' ✦');
      expect(sub.detour, {'tag': 'vpn-2'});

      // Круг: собираем подписку так, как её положил бы импорт (груз в своём
      // расширении), и проверяем, что экспорт вернул поля наверх.
      final list = SubscriptionServers(
        id: 'sub-1',
        name: sub.label,
        enabled: true,
        tagPrefix: sub.tagPrefix,
        detourPolicy: DetourPolicy.defaults,
        url: sub.url,
      );
      final raw = await buildLxBackup(
        lists: [list],
        rules: const [],
        vars: const {},
      );
      final exported =
          ((jsonDecode(raw) as Map<String, dynamic>)['subscriptions'] as List)
              .single as Map<String, dynamic>;
      // Груза в этой сборке нет — но и мусора тоже: ключи чужой схемы не
      // выдумываются из воздуха.
      expect(exported.containsKey('max_nodes'), isFalse);
      expect(exported['url'], sub.url);
    });

    // §393 B11 — то же для правила: `_backup_fields` живёт на модели и
    // переживает и storage, и copyWith.
    test('непонятые поля правила переживают круг', () async {
      final incoming = jsonEncode({
        'lx_backup': 1,
        'exported_by': {'app': 'launcher', 'version': '1.5.1'},
        'exported_at': '2026-08-22T00:00:00Z',
        'rules': [
          {
            'kind': 'inline',
            'name': 'Ads',
            'num': 1000,
            'outbound': 'direct',
            'match': {'domain_suffix': ['ads.example-1.com']},
            'sorcery': {'launcher_only': true},
          },
        ],
      });
      final parsed = parseLxBackup(incoming, knownOutbounds: {'direct'});
      final rule = parsed.rules.single;
      expect(rule.backupFields['sorcery'], {'launcher_only': true});
      // Default-deny (§2): поле названо, а не съедено молча.
      expect(parsed.warnings.map((w) => w.code), isNot(contains('boom')));

      // Через storage (правило персистится) и обратно.
      final revived = CustomRule.fromJson(rule.toJson());
      expect(revived.backupFields['sorcery'], {'launcher_only': true},
          reason: 'груз не пережил storage — re-export обеднеет');

      final raw = await buildLxBackup(
        lists: const [],
        rules: [revived],
        vars: const {},
      );
      final exported =
          ((jsonDecode(raw) as Map<String, dynamic>)['rules'] as List).single
              as Map<String, dynamic>;
      expect(exported['sorcery'], {'launcher_only': true},
          reason: 'поле чужой схемы не вернулось на верхний уровень записи');
      expect(
          ((exported['extensions'] as Map?)?['lxbox'] as Map?)
              ?.containsKey('_backup_fields'),
          isNot(isTrue),
          reason: 'служебный контейнер не поле схемы — в файл он не едет');
    });

    // §393 B11 — vars пресета и URL srs-правила: фабрики моделей читают
    // `varsValues`/`srsUrl`, а схема зовёт их `vars`/`ref`. До хвоста фазы B
    // перекладки не было, и значения молча оседали в никуда.
    test('vars пресета и ref srs-правила доезжают', () {
      final raw = jsonEncode({
        'lx_backup': 1,
        'exported_by': {'app': 'launcher', 'version': '1.5.1'},
        'exported_at': '2026-08-22T00:00:00Z',
        'rules': [
          {
            'kind': 'preset',
            'name': 'Ads',
            'num': 1000,
            'ref': 'block-ads',
            'vars': {'outbound': 'direct'},
          },
          {
            'kind': 'srs',
            'name': 'Geo',
            'num': 1100,
            'ref': 'https://example-1.com/geo.srs',
            'outbound': 'direct',
          },
        ],
      });
      final file = parseLxBackup(raw, knownOutbounds: {'direct'});
      final preset = file.rules.first as CustomRulePreset;
      expect(preset.presetId, 'block-ads');
      expect(preset.varsValues['outbound'], 'direct',
          reason: 'значения переменных пресета потеряны на импорте');
      final srs = file.rules.last as CustomRuleSrs;
      expect(srs.srsUrl, 'https://example-1.com/geo.srs',
          reason: 'URL rule-set потерян — правило приедет пустым');
    });

    // §393 B8 — регистрации WARP. Имена полей канонические (лаунчерные), а не
    // мобильные: совпадение случайное на трёх полях из десяти.
    test('warp: круг сохраняет регистрацию и мобильные добавки', () {
      const acc = WarpAccount(
        privKey: 'cHJpdg==',
        peerPub: 'cGVlcg==',
        clientV4: '172.16.0.2',
        clientV6: 'fd01::2',
        clientId: 'AQID',
        accountId: 'acc-1',
        deviceId: 'dev-1',
        token: 'tok-1',
        endpoint: 'engage.cloudflareclient.com:2408',
        createdAt: '2026-01-01T00:00:00Z',
        warpPlus: true,
      );
      final wire = warpAccountToBackup(acc);
      expect(wire['type'], 'wg');
      expect(wire['private_key'], 'cHJpdg==',
          reason: 'канон зовёт поле private_key, а не priv_key');
      expect(wire['peer_public'], 'cGVlcg==');
      expect(wire['warp_plus'], isTrue);

      final back = warpAccountFromBackup(wire);
      expect(back, isNotNull);
      expect(back!.privKey, acc.privKey);
      expect(back.peerPub, acc.peerPub);
      expect(back.clientId, acc.clientId);
      expect(back.accountId, acc.accountId);
      expect(back.token, acc.token);
      expect(back.warpPlus, isTrue);
      expect(back.endpoint, acc.endpoint);
    });

    test('masque: круг сохраняет регистрацию, SNI едет в extensions', () {
      const acc = MasqueAccount(
        privKeyDer: 'ZGVy',
        serverPubDer: 'cHVi',
        clientV4: '172.16.0.2/32',
        clientV6: 'fd01::2/128',
        server: '162.159.198.1',
        port: 443,
        deviceId: 'dev-1',
        token: 'tok-1',
        createdAt: '2026-01-01T00:00:00Z',
        sni: 'www.cloudflare.com',
        idleTimeout: '5m',
      );
      final wire = masqueAccountToBackup(acc);
      expect(wire['type'], 'masque');
      expect(wire['private_key_der'], 'ZGVy');
      // sni/idle_timeout — параметры узла, канон их не знает.
      final own = (wire['extensions'] as Map)['lxbox'] as Map;
      expect(own['sni'], 'www.cloudflare.com');
      expect(own['idle_timeout'], '5m');

      final back = masqueAccountFromBackup(wire);
      expect(back, isNotNull);
      expect(back!.privKeyDer, acc.privKeyDer);
      expect(back.serverPubDer, acc.serverPubDer);
      expect(back.port, 443);
      expect(back.sni, 'www.cloudflare.com');
      expect(back.idleTimeout, '5m');
    });

    test('warp без дискриминатора назван warning\'ом, а не съеден', () {
      final raw = jsonEncode({
        'lx_backup': 1,
        'exported_by': {'app': 'launcher', 'version': '1.5.1'},
        'exported_at': '2026-08-22T00:00:00Z',
        'warp': [
          {'private_key': 'cHJpdg=='},
          {'type': 'wg', 'private_key': 'cHJpdg==', 'peer_public': 'cGVlcg=='},
        ],
      });
      final file = parseLxBackup(raw);
      expect(file.warp, hasLength(1), reason: 'запись без type не применима');
      expect(file.warnings.map((w) => w.code), contains(kWarnWarpSkipped));
    });

    // §393 B9 — DNS. Канон знает `template|preset|user`, мобила — `inline`
    // вместо `user` и вдобавок `srs` у правил.
    test('dns: круг сохраняет состав, final и strategy', () async {
      final section = dnsToBackup(
        servers: [
          {'kind': 'template', 'tag': 'dns-google', 'enabled': true},
          {
            'kind': 'inline',
            'tag': 'my-doh',
            'enabled': true,
            'body': {'type': 'https', 'server': '1.1.1.1'},
          },
        ],
        rules: [
          {'kind': 'inline', 'name': 'Local', 'enabled': true,
           'rule': {'domain_suffix': ['lan'], 'server': 'my-doh'}},
          {'kind': 'srs', 'id': 'srs-1', 'name': 'Geo', 'enabled': true,
           'server': 'my-doh'},
        ],
        dnsFinal: 'my-doh',
        strategy: 'prefer_ipv4',
      );
      final raw = await buildLxBackup(
        lists: const [],
        rules: const [],
        vars: const {},
        dns: section,
      );
      final dnsDoc = (jsonDecode(raw) as Map<String, dynamic>)['dns'] as Map;
      expect(dnsDoc['final'], 'my-doh');
      expect(dnsDoc['strategy'], 'prefer_ipv4');
      final servers = (dnsDoc['servers'] as List).cast<Map<String, dynamic>>();
      // `inline` мобилы записан каноническим `user`.
      expect(servers.map((e) => e['kind']), ['template', 'user']);
      // Тело переносится ТОЛЬКО у пользовательской записи.
      expect(servers.first.containsKey('value'), isFalse);
      expect((servers.last['value'] as Map)['server'], '1.1.1.1');

      final back = parseLxBackup(raw).dns;
      expect(back, isNotNull);
      final applied = applyDnsBackup(
        incoming: back!,
        servers: const [],
        rules: const [],
        dnsFinal: '',
        strategy: '',
      );
      expect(applied.dnsFinal, 'my-doh');
      expect(applied.strategy, 'prefer_ipv4');
      expect(applied.servers.map((e) => e['kind']), ['template', 'inline'],
          reason: 'канонический user не вернулся мобильным inline');
      // §393 B9 — srs-правило, которому в схеме места нет, вернулось целиком.
      final srs = applied.rules.firstWhere((e) => e['kind'] == 'srs');
      expect(srs['id'], 'srs-1');
      expect(srs['server'], 'my-doh');
    });

    test('dns: своя запись сильнее приехавшей (merge не перетирает)', () {
      const incoming = LxDns(
        servers: [
          LxDnsRef(kind: 'user', name: 'my-doh', value: {'server': '9.9.9.9'}),
        ],
        finalServer: 'my-doh',
      );
      final applied = applyDnsBackup(
        incoming: incoming,
        servers: [
          {
            'kind': 'inline',
            'tag': 'my-doh',
            'enabled': true,
            'body': {'server': '1.1.1.1'},
          },
        ],
        rules: const [],
        dnsFinal: 'other',
        strategy: '',
      );
      expect(applied.servers, hasLength(1),
          reason: 'приехавшая запись задвоила своё под тем же тегом');
      expect((applied.servers.single['body'] as Map)['server'], '1.1.1.1',
          reason: 'своё тело перетёрто приехавшим');
      // final приезжает непустым и применяется: это не состав, а указатель.
      expect(applied.dnsFinal, 'my-doh');
    });

    test('dns: чужой kind назван warning\'ом, а не применён вслепую', () {
      final raw = jsonEncode({
        'lx_backup': 1,
        'exported_by': {'app': 'launcher', 'version': '1.5.1'},
        'exported_at': '2026-08-22T00:00:00Z',
        'dns': {
          'servers': [
            {'kind': 'sorcery', 'name': 'x'},
          ],
        },
      });
      final file = parseLxBackup(raw);
      expect(file.dns!.servers, isEmpty);
      expect(file.dns!.foreignServerEntries, hasLength(1),
          reason: 'запись выброшена вместо сохранения для re-export');
      expect(file.warnings.map((w) => w.code), contains(kWarnDnsEntrySkipped));
    });

    // §393 B10 — одиночный сервер: до B10 экспорт писал пустую оболочку
    // (label + extensions), а `uri`/`config_json` схемы оставались пустыми.
    test('одиночный сервер: uri уезжает в тело записи', () async {
      final server = UserServer(
        id: 'srv-1',
        name: 'Manual',
        enabled: true,
        tagPrefix: '',
        detourPolicy: DetourPolicy.defaults,
        origin: UserSource.manual,
        createdAt: DateTime.utc(2026),
        rawBody: 'vless://11111111-1111-1111-1111-111111111111@example-1.com:443',
      );
      final raw = await buildLxBackup(
        lists: [server],
        rules: const [],
        vars: const {},
      );
      final doc = jsonDecode(raw) as Map<String, dynamic>;
      final entry = (doc['servers'] as List).single as Map<String, dynamic>;
      expect(entry['uri'], startsWith('vless://'),
          reason: 'оболочка осталась пустой — сервер не переносится');
      expect(entry['label'], 'Manual');

      final back = parseLxBackup(raw).servers.single;
      expect(back.uri, startsWith('vless://'));
      expect(back.label, 'Manual');
    });

    test('одиночный сервер: JSON-тело едет в config_json, а не в uri', () async {
      final server = UserServer(
        id: 'srv-2',
        name: 'Json',
        enabled: true,
        tagPrefix: '',
        detourPolicy: DetourPolicy.defaults,
        origin: UserSource.paste,
        createdAt: DateTime.utc(2026),
        rawBody: '{"type":"vless","server":"example-1.com"}',
      );
      final raw = await buildLxBackup(
        lists: [server],
        rules: const [],
        vars: const {},
      );
      final entry =
          ((jsonDecode(raw) as Map<String, dynamic>)['servers'] as List).single
              as Map<String, dynamic>;
      expect(entry.containsKey('uri'), isFalse,
          reason: 'схема требует РОВНО ОДНО из uri/config_json');
      expect((entry['config_json'] as Map)['server'], 'example-1.com');
    });
  });
}
