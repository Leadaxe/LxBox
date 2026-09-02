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
      expect(file.directions.single.label, 'Россия');
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
      final raw = (await buildLxBackup(
        lists: const [],
        rules: const [],
        vars: const {},
        directions: const [src],
      )).json;
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
      // §401 — путь называет ЗАПИСЬ, а не только секцию
      // (registry/backup_warnings.json: «detail называет полный путь — и
      // ключ, и сущность, в которой он встретился»). Анонимный
      // `directions[].sorcery` на файле с двумя десятками Направлений не
      // говорил пользователю, в каком из них искать лишнее поле.
      expect(file.warnings.map((w) => w.detail), ['directions[de].sorcery']);
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
      expect(c.label, 'Мой маршрут');
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
      // §401 — путь адресует конкретную цепочку по её тегу (см. выше).
      expect(file.warnings.single.detail, 'chains[relay].sorcery');
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
        label: 'Мой маршрут',
        hops: ['warp', 'vpn ②'],
        idleTimeout: '0s',
        stripEvasion: false,
        strip: {'tls.utls': false},
        // RFC 7396: null удаляет ключ и обязан пережить перенос как есть.
        rewrite: {
          'vless': {'flow': null},
        },
      );

      final out = (await buildLxBackup(
        lists: const [],
        rules: const [],
        vars: const {},
        chains: const [source],
      )).json;
      final doc = jsonDecode(out) as Map<String, dynamic>;
      final entry = (doc['chains'] as List).single as Map<String, dynamic>;
      expect(entry['tag'], 'chain-1');
      // §405 — имя цепочки едет полем ЗАПИСИ; канон `chain` его не знает.
      expect(entry['label'], 'Мой маршрут');
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
      expect(back.label, source.label);
      expect(back.hops, source.hops);
      expect(back.idleTimeout, source.idleTimeout);
      expect(back.stripEvasion, isFalse);
      expect(back.strip, source.strip);
      expect(back.rewrite, source.rewrite);
    });

    test('label не пишется, когда равен тегу или пуст', () async {
      final out = (await buildLxBackup(
        lists: const [],
        rules: const [],
        vars: const {},
        chains: const [
          SourceChain(tag: 'chain-1', label: 'chain-1', hops: ['a', 'b']),
          SourceChain(tag: 'chain-2', label: '', hops: ['a', 'b']),
        ],
      )).json;
      final entries =
          ((jsonDecode(out) as Map<String, dynamic>)['chains'] as List)
              .cast<Map<String, dynamic>>();
      for (final e in entries) {
        expect(e.containsKey('label'), isFalse,
            reason: '§405 — имя пишется, ТОЛЬКО если отличается от тега: '
                'повтор тега на той стороне неотличим от осознанного имени');
      }
    });

    test('§405 — имя Направления и цепочки переживает круг экспорт→импорт',
        () async {
      final out = (await buildLxBackup(
        lists: const [],
        rules: const [],
        vars: const {},
        directions: const [
          Direction(tag: 'de', label: 'Германия'),
        ],
        chains: const [
          SourceChain(tag: 'chain-1', label: 'Мой маршрут', hops: ['a', 'b']),
        ],
      )).json;

      final back = parseLxBackup(out, knownOutbounds: {'a', 'b'});
      expect(back.directions.single.label, 'Германия');
      expect(back.chains.single.label, 'Мой маршрут');
      expect(back.warnings, isEmpty,
          reason: 'поле наше — ни unknown_field, ни label_dropped');
    });

    test('§405 — label Направления, равный тегу, не пишется', () async {
      final out = (await buildLxBackup(
        lists: const [],
        rules: const [],
        vars: const {},
        directions: const [
          Direction(tag: 'de', label: 'de'),
          Direction(tag: 'nl', label: ''),
        ],
      )).json;
      final entries =
          ((jsonDecode(out) as Map<String, dynamic>)['directions'] as List)
              .cast<Map<String, dynamic>>();
      for (final e in entries) {
        expect(e.containsKey('label'), isFalse,
            reason: 'повтор тега именем не является: на той стороне он был бы '
                'неотличим от осознанно введённого имени');
      }
    });

    test('выключенная цепочка едет ключом enabled: false', () async {
      final out = (await buildLxBackup(
        lists: const [],
        rules: const [],
        vars: const {},
        chains: const [
          SourceChain(tag: 'off', enabled: false, hops: ['a', 'b']),
        ],
      )).json;
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
      final out = (await buildLxBackup(
        lists: const [],
        rules: const [],
        vars: const {},
        chains: chains,
      )).json;
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
      final raw = (await buildLxBackup(
        lists: [list],
        rules: const [],
        vars: const {},
      )).json;
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

    // §401, контракт 0.12.2 — sni/idle_timeout лежат ПЛОСКО в записи: карман
    // extensions.lxbox упразднён, а схема объявляет оба поля поимённо.
    test('masque: круг сохраняет регистрацию, sni/idle_timeout плоские', () {
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
      expect(wire['sni'], 'www.cloudflare.com');
      expect(wire['idle_timeout'], '5m');
      expect(wire.containsKey('extensions'), isFalse,
          reason: 'карман extensions упразднён контрактом 0.12.2');

      final back = masqueAccountFromBackup(wire);
      expect(back, isNotNull);
      expect(back!.privKeyDer, acc.privKeyDer);
      expect(back.serverPubDer, acc.serverPubDer);
      expect(back.port, 443);
      expect(back.sni, 'www.cloudflare.com');
      expect(back.idleTimeout, '5m');
    });

    // Необязательность: незаданные поля в файл не едут вовсе, а не пустыми
    // строками — пустой sni у принимающей стороны это не «SNI отсутствует»,
    // а объявленное значение, которым она перекрыла бы свой дефолт.
    test('masque: незаданные sni/idle_timeout в записи отсутствуют', () {
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
      );
      final wire = masqueAccountToBackup(acc);
      expect(wire.containsKey('sni'), isFalse);
      expect(wire.containsKey('idle_timeout'), isFalse);
      expect(wire.containsKey('extensions'), isFalse);
    });

    // Круг через ФАЙЛ, а не только через пару функций: плоские поля обязаны
    // пережить общий обход §401 — иначе они бы уезжали, но приезжали с
    // backup_unknown_field и в состояние не попадали.
    test('masque: sni/idle_timeout переживают экспорт→импорт файла', () {
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
      final raw = jsonEncode({
        'lx_backup': 1,
        'exported_by': {'app': 'lxbox', 'version': '2.21.0'},
        'exported_at': '2026-09-02T00:00:00Z',
        'warp': [masqueAccountToBackup(acc)],
      });

      final file = parseLxBackup(raw);
      expect(file.warnings, isEmpty,
          reason: 'плоские sni/idle_timeout объявлены схемой — не «незнакомое»');
      expect(file.warp, hasLength(1));

      final back = masqueAccountFromBackup(file.warp.single);
      expect(back, isNotNull);
      expect(back!.sni, 'www.cloudflare.com');
      expect(back.idleTimeout, '5m');
      expect(back.server, acc.server);
      expect(back.port, 443);
    });

    // Старый файл 0.10.x: карман читается общим правилом §401 — ОДИН
    // backup_extensions_dropped на файл, — а не отдельным разбором warp[].
    // Аккаунт при этом импортируется: карман потерян, регистрация цела.
    test('masque: старый файл с extensions даёт один warning, аккаунт цел', () {
      final raw = jsonEncode({
        'lx_backup': 1,
        'exported_by': {'app': 'lxbox', 'version': '2.19.0'},
        'exported_at': '2026-08-01T00:00:00Z',
        'warp': [
          {
            'type': 'masque',
            'private_key_der': 'ZGVy',
            'server_pub_der': 'cHVi',
            'client_v4': '172.16.0.2/32',
            'client_v6': 'fd01::2/128',
            'server': '162.159.198.1',
            'port': 443,
            'extensions': {
              'lxbox': {'sni': 'www.cloudflare.com', 'idle_timeout': '5m'},
            },
          },
        ],
      });

      final file = parseLxBackup(raw);
      final codes = file.warnings.map((w) => w.code).toList();
      expect(codes.where((c) => c == kWarnExtensionsDropped), hasLength(1),
          reason: 'карман любой глубины даёт ровно один warning на файл');
      expect(codes, isNot(contains(kWarnUnknownField)),
          reason: 'внутренности кармана по одной не перечисляются');

      expect(file.warp, hasLength(1));
      final back = masqueAccountFromBackup(file.warp.single);
      expect(back, isNotNull, reason: 'регистрация применима и без кармана');
      expect(back!.privKeyDer, 'ZGVy');
      expect(back.server, '162.159.198.1');
      expect(back.sni, isEmpty, reason: 'карман не читается — sni потерян');
      expect(back.idleTimeout, isEmpty);
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
      final raw = (await buildLxBackup(
        lists: const [],
        rules: const [],
        vars: const {},
        dns: section,
      )).json;
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
      // §401 (П3) — `srs`-правило В ФАЙЛ НЕ ЕДЕТ и обратно не приезжает.
      // Раньше оно возилось карманом `extensions` и «возвращалось целиком»;
      // карман упразднён, потому что провоз непонятого делал экспорт
      // нечистой функцией состояния (П1). Круг обязан быть ЧЕСТНЫМ: то, чего
      // в файле нет, из файла не появляется.
      expect(applied.rules.where((e) => e['kind'] == 'srs'), isEmpty,
          reason: 'srs приехал обратно — значит карман провоза жив');
    });

    test('dns: srs-правило не уезжает в файл и потеря названа (§401 П3/П6)',
        () {
      final warnings = <LxBackupWarning>[];
      final section = dnsToBackup(
        servers: const [],
        rules: const [
          {'kind': 'srs', 'id': 'srs-1', 'name': 'Geo', 'enabled': true},
        ],
        dnsFinal: '',
        strategy: '',
        warnings: warnings,
      );
      expect(section.rules, isEmpty,
          reason: 'происхождения srs у канона нет — записи в файле быть не '
              'должно');
      // П6 — молчаливых потерь нет: пользователь обязан узнать, что правило
      // осталось на этой машине.
      expect(warnings.map((w) => w.code), contains(kWarnLocalOnlyDropped));
      expect(warnings.map((w) => w.detail).join(' '), contains('srs'));
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
      // §401 — запись ОТБРАСЫВАЕТСЯ, а не хранится сырой до re-export: карман
      // провоза упразднён (П3). Молчать о ней при этом нельзя (П6).
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
      final raw = (await buildLxBackup(
        lists: [server],
        rules: const [],
        vars: const {},
      )).json;
      final doc = jsonDecode(raw) as Map<String, dynamic>;
      final entry = (doc['servers'] as List).single as Map<String, dynamic>;
      expect(entry['uri'], startsWith('vless://'),
          reason: 'оболочка осталась пустой — сервер не переносится');
      // §401 (D-082) — имя узла едет `node_tag`, а не `label`: у канона имя
      // одно — тег, и подпись рядом с ним разъехалась бы при переименовании.
      expect(entry['node_tag'], 'Manual');
      expect(entry.containsKey('label'), isFalse,
          reason: 'label одиночного узла экспорт писать не должен');

      final back = parseLxBackup(raw).servers.single;
      expect(back.uri, startsWith('vless://'));
      expect(back.name, 'Manual');
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
      final raw = (await buildLxBackup(
        lists: [server],
        rules: const [],
        vars: const {},
      )).json;
      final entry =
          ((jsonDecode(raw) as Map<String, dynamic>)['servers'] as List).single
              as Map<String, dynamic>;
      expect(entry.containsKey('uri'), isFalse,
          reason: 'схема требует РОВНО ОДНО из uri/config_json');
      expect((entry['config_json'] as Map)['server'], 'example-1.com');
    });
  });

  // ════════════════════════════════════════════════════════════════════════
  // §401 — бэкап как СЕРИАЛИЗАЦИЯ СОСТОЯНИЯ (BACKUP_PRINCIPLES П1/П3/П6)
  // ════════════════════════════════════════════════════════════════════════
  group('§401 состояние, а не карман', () {
    SubscriptionServers subWith({
      SubscriptionIdentityOverride? identity,
      Map<String, DateTime> disabled = const {},
    }) =>
        SubscriptionServers(
          id: 's1',
          name: 'Sub',
          enabled: true,
          tagPrefix: '',
          detourPolicy: DetourPolicy.defaults,
          url: 'https://example-1.com/sub',
          identity: identity,
          disabledHashes: disabled,
          nodes: const [],
        );

    Future<Map<String, dynamic>> exportOf(List<ServerList> lists) async {
      final raw = (await buildLxBackup(
        lists: lists,
        rules: const [],
        vars: const {},
      )).json;
      return jsonDecode(raw) as Map<String, dynamic>;
    }

    group('identity (D-083)', () {
      test('пишутся ТОЛЬКО заданные ключи', () async {
        final doc = await exportOf([
          subWith(
            identity: const SubscriptionIdentityOverride(
              userAgent: 'v2rayNG/1.8',
              sendHwid: true,
            ),
          ),
        ]);
        final id = ((doc['subscriptions'] as List).single
            as Map<String, dynamic>)['identity'] as Map<String, dynamic>;
        expect(id['user_agent'], 'v2rayNG/1.8');
        expect(id['send_hwid'], isTrue);
        // «Не задано» и «задано пустым» значат разное: пустышка в каждом
        // файле отличала бы два ОДИНАКОВЫХ состояния (П1).
        expect(id.containsKey('hwid'), isFalse);
        expect(id.containsKey('device_model'), isFalse);
      });

      test('override не задан → объекта identity в файле нет', () async {
        final doc = await exportOf([subWith()]);
        expect(
            ((doc['subscriptions'] as List).single as Map)
                .containsKey('identity'),
            isFalse);
      });

      test('неизвестный ключ → backup_source_identity_dropped с перечнем', () {
        // `hash_device_model` схема объявляет, а у нас такой настройки нет.
        final raw = jsonEncode({
          'lx_backup': 1,
          'subscriptions': [
            {
              'url': 'https://example-1.com/sub',
              'label': 'Sub',
              'identity': {'user_agent': 'UA', 'hash_device_model': true},
            }
          ],
        });
        final file = parseLxBackup(raw);
        final w =
            file.warnings.where((w) => w.code == kWarnSourceIdentityDropped);
        expect(w, hasLength(1),
            reason: 'ОДИН warning на подписку с перечнем ключей, а не по '
                'строке на ключ');
        expect(w.single.detail, 'Sub: hash_device_model');
        // Применимая часть при этом применена: отбрасывается ключ, не объект.
        expect(file.subscriptions.single.identity!.userAgent, 'UA');
      });

      test('перечень воспроизводим: схема по порядку, чужое по алфавиту', () {
        final raw = jsonEncode({
          'lx_backup': 1,
          'subscriptions': [
            {
              'url': 'https://example-1.com/sub',
              'label': 'Sub',
              'identity': {'zeta': 1, 'hash_device_model': true, 'alpha': 2},
            }
          ],
        });
        expect(
            parseLxBackup(raw)
                .warnings
                .firstWhere((w) => w.code == kWarnSourceIdentityDropped)
                .detail,
            'Sub: hash_device_model, alpha, zeta',
            reason: 'два импорта одного файла обязаны дать один текст');
      });
    });

    test('отметки: ключи-теги и legacy 64-hex проходят как есть', () async {
      final legacy = 'a' * 64;
      final doc = await exportOf([
        subWith(disabled: {
          'DE-1': DateTime.utc(2026, 8, 20),
          legacy: DateTime.utc(2026, 8, 20),
        }),
      ]);
      final disabled = ((doc['subscriptions'] as List).single
          as Map<String, dynamic>)['disabled'] as Map;
      expect(disabled.keys.toSet(), {'DE-1', legacy},
          reason: 'ключ для формата обмена НЕПРОЗРАЧЕН: legacy-форма '
              'переживает перенос и мигрирует уже на приёмнике (§400)');
    });

    group('label одиночной записи (D-082)', () {
      test('label записи servers[] на импорте → node_tag или warning', () {
        // Схема 0.12 поля не знает вовсе — это LEGACY-ВХОД для файлов 0.11 и
        // раньше. Без `node_tag` подпись ещё может стать тегом (потери нет);
        // вместе с ним — расхождение, и label не применяется.
        final both = jsonEncode({
          'lx_backup': 1,
          'servers': [
            {'node_tag': 'Real', 'label': 'Другое', 'uri': 'vless://u@h:443'}
          ],
        });
        final withTag = parseLxBackup(both);
        expect(withTag.servers.single.name, 'Real');
        expect(withTag.warnings.map((w) => w.code), contains(kWarnLabelDropped));

        final onlyLabel = jsonEncode({
          'lx_backup': 1,
          'servers': [
            {'label': 'Имя', 'uri': 'vless://u@h:443'}
          ],
        });
        final noTag = parseLxBackup(onlyLabel);
        expect(noTag.servers.single.name, 'Имя',
            reason: 'тега нет — подпись становится им, потери нет');
        expect(
            noTag.warnings.where((w) => w.code == kWarnLabelDropped), isEmpty);
      });

      test('label Направления ПРИМЕНЯЕТСЯ и warning не поднимает', () {
        // §405 — поле объявлено в схеме, применяет его LxBox: терять нечего.
        final raw = jsonEncode({
          'lx_backup': 1,
          'directions': [
            {'tag': 'de', 'label': 'Германия'}
          ],
        });
        final file = parseLxBackup(raw);
        expect(file.directions.single.tag, 'de');
        expect(file.directions.single.label, 'Германия');
        expect(file.warnings, isEmpty,
            reason: 'ни unknown_field, ни label_dropped: поле своё');
      });

      test('label цепочки ПРИМЕНЯЕТСЯ и warning не поднимает', () {
        // §405 отменил §401-поведение «разошёлся с тегом → label_dropped»:
        // у цепочки LxBox имя есть, и приехавшее применяется.
        final raw = jsonEncode({
          'lx_backup': 1,
          'chains': [
            {
              'tag': 'relay',
              'label': 'Мой маршрут',
              'chain': {
                'hops': ['a', 'b'],
              },
            }
          ],
        });
        final file = parseLxBackup(raw);
        expect(file.chains.single.label, 'Мой маршрут');
        expect(file.warnings, isEmpty);
      });
    });

    group('отбрасывание непонятого (П3/П6)', () {
      test('extensions любой глубины → РОВНО ОДИН warning на файл', () {
        // Карман был с произвольным содержимым: перечислять его внутренности
        // по одной значило бы утопить пользователя в списке.
        final raw = jsonEncode({
          'lx_backup': 1,
          'extensions': {
            'launcher': {'a': 1}
          },
          'subscriptions': [
            {
              'url': 'https://example-1.com/sub',
              'extensions': {
                'lxbox': {'b': 2}
              },
            }
          ],
          'directions': [
            {
              'tag': 'de',
              'extensions': {
                'x': {'c': 3}
              },
            }
          ],
        });
        final file = parseLxBackup(raw);
        expect(file.warnings.where((w) => w.code == kWarnExtensionsDropped),
            hasLength(1));
        // И карман НЕ провозится: состояние-призрак запрещён (П1).
        expect(jsonEncode(file.directions.single.toJson()),
            isNot(contains('extensions')));
      });

      test('skip чужого типа → backup_field_type_mismatch, разбор идёт', () {
        final raw = jsonEncode({
          'lx_backup': 1,
          'subscriptions': [
            {
              'url': 'https://example-1.com/sub',
              'label': 'Sub',
              'skip': ['filter-a', 'filter-b'],
            }
          ],
        });
        final file = parseLxBackup(raw);
        expect(
            file.warnings
                .where((w) => w.code == kWarnFieldTypeMismatch)
                .map((w) => w.detail),
            ['Sub.skip'],
            reason: 'отдельный код от unknown_field: пользователю важно '
                'различать «поля тут нет» и «поле есть, записано иначе»');
        expect(file.subscriptions, hasLength(1), reason: 'разбор продолжен');
      });

      test('неизвестный ключ Направления → путь называет ЗАПИСЬ', () {
        final raw = jsonEncode({
          'lx_backup': 1,
          'directions': [
            {'tag': 'de', 'sorcery': true}
          ],
        });
        final file = parseLxBackup(raw);
        expect(file.warnings.map((w) => w.code), [kWarnUnknownField]);
        expect(file.warnings.single.detail, 'directions[de].sorcery');
      });

      test('exclude_from_global → backup_source_flag_dropped', () {
        // Ключи ОБЪЯВЛЕНЫ в типах контракта, поэтому общий обход неизвестных
        // их не ловит — без отдельного кода они пропадали бы совсем молча.
        final raw = jsonEncode({
          'lx_backup': 1,
          'subscriptions': [
            {
              'url': 'https://example-1.com/sub',
              'label': 'Sub',
              'exclude_from_global': true,
            }
          ],
        });
        expect(
            parseLxBackup(raw)
                .warnings
                .where((w) => w.code == kWarnSourceFlagDropped)
                .map((w) => w.detail),
            ['Sub.exclude_from_global']);
      });
    });

    test('П1 — экспорт ДЕТЕРМИНИРОВАН: два прогона байт-идентичны', () async {
      // «Экспорт — чистая функция состояния: два неотличимых состояния дают
      // неотличимые файлы». Нарушение здесь ломает и diff бэкапов, и саму
      // возможность сказать «состояние не менялось».
      final state = [
        subWith(
          identity: const SubscriptionIdentityOverride(
            userAgent: 'UA',
            sendHwid: true,
            hwid: 'h-1',
          ),
          disabled: {
            'DE-1': DateTime.utc(2026, 8, 20),
            'AT-9': DateTime.utc(2026, 8, 21),
          },
        ),
      ];
      String stripVolatile(String raw) {
        final doc = jsonDecode(raw) as Map<String, dynamic>;
        // Метка времени и версия приложения — не состояние: они меняются
        // сами по себе и к чистоте функции отношения не имеют.
        doc.remove('exported_at');
        doc.remove('exported_by');
        return jsonEncode(doc);
      }

      final first =
          (await buildLxBackup(lists: state, rules: const [], vars: const {}))
              .json;
      final second =
          (await buildLxBackup(lists: state, rules: const [], vars: const {}))
              .json;
      expect(stripVolatile(second), stripVolatile(first));
    });
  });

  // ════════════════════════════════════════════════════════════════════════
  // §401 (П1) — слияние подписок на импорте
  // ════════════════════════════════════════════════════════════════════════
  //
  // «Импорт восстанавливает состояние, неотличимое от настроенного руками».
  // До §401 совпавшая по URL запись получала ТОЛЬКО доливку disabled-отметок,
  // так что восстановление своего же файла на том же устройстве не возвращало
  // ни identity, ни префикс тегов: пользователь видел «импорт прошёл» и
  // настроек на месте не находил.
  group('§401 mergeBackupSubscriptions', () {
    const url = 'https://example-1.com/sub';

    SubscriptionServers local({
      String name = 'Своё имя',
      String tagPrefix = 'local:',
      bool enabled = true,
      int updateIntervalHours = 24,
      SubscriptionIdentityOverride? identity,
      Map<String, DateTime> disabled = const {},
      String at = url,
    }) =>
        SubscriptionServers(
          id: 'local-1',
          name: name,
          enabled: enabled,
          tagPrefix: tagPrefix,
          detourPolicy: DetourPolicy.defaults,
          url: at,
          updateIntervalHours: updateIntervalHours,
          identity: identity,
          disabledHashes: disabled,
          nodes: const [],
        );

    test('совпавшая по URL запись ПРИНИМАЕТ настройки файла', () {
      final out = mergeBackupSubscriptions(
        [local()],
        const [
          LxSubscription(
            url: url,
            label: 'Из файла',
            enabled: false,
            tagPrefix: 'file:',
            updateIntervalHours: 6,
            identity: SubscriptionIdentityOverride(
              userAgent: 'v2rayNG/1.8',
              sendHwid: true,
            ),
          ),
        ],
      );
      final got = out.lists.single as SubscriptionServers;
      expect(got.id, 'local-1', reason: 'запись та же, не пересоздана');
      expect(got.name, 'Из файла');
      expect(got.tagPrefix, 'file:');
      expect(got.enabled, isFalse);
      expect(got.updateIntervalHours, 6);
      expect(got.identity!.userAgent, 'v2rayNG/1.8');
      expect(got.identity!.sendHwid, isTrue);
      expect(out.applied, 1);
    });

    test('identity отсутствует в файле → СБРОС в дефолт, а не «как было»', () {
      // Объекта в файле нет — значит состояние экспортировали без override'а.
      // Оставить своё значило бы не перенести состояние вовсе.
      final out = mergeBackupSubscriptions(
        [
          local(
            identity: const SubscriptionIdentityOverride(userAgent: 'старое'),
          )
        ],
        const [LxSubscription(url: url, label: 'Из файла')],
      );
      expect((out.lists.single as SubscriptionServers).identity, isNull);
    });

    test('пустое имя в файле своё НЕ затирает', () {
      final out = mergeBackupSubscriptions(
        [local(name: 'Своё имя')],
        const [LxSubscription(url: url, tagPrefix: 'file:')],
      );
      expect((out.lists.single as SubscriptionServers).name, 'Своё имя');
    });

    test('disabled-отметки ОБЪЕДИНЯЮТСЯ: своя не перетёрта, чужая долита', () {
      // Исключение из «файл сильнее»: отметка, которой в файле нет, могла
      // быть поставлена уже ПОСЛЕ экспорта — молча включать узел нельзя.
      final mine = DateTime.utc(2026, 8, 1);
      final out = mergeBackupSubscriptions(
        [local(disabled: {'DE-1': mine, 'Only-mine': mine})],
        const [
          LxSubscription(
            url: url,
            disabled: {'DE-1': 1, 'From-file': 1767225600},
          ),
        ],
      );
      final got = out.lists.single as SubscriptionServers;
      expect(got.disabledHashes.keys.toSet(),
          {'DE-1', 'Only-mine', 'From-file'});
      expect(got.disabledHashes['DE-1'], mine,
          reason: 'своя отметка сильнее приехавшей');
    });

    test('подписка не из файла НЕ удаляется', () {
      final out = mergeBackupSubscriptions(
        [local(at: 'https://other.example/sub', name: 'Чужая')],
        const [LxSubscription(url: url, label: 'Новая')],
      );
      expect(out.lists, hasLength(2), reason: 'импорт — слияние, не замена');
      expect((out.lists.first as SubscriptionServers).name, 'Чужая');
    });

    test('новая подписка добавляется без узлов, в хвост', () {
      final out = mergeBackupSubscriptions(
        const [],
        const [
          LxSubscription(
            url: url,
            label: 'Новая',
            tagPrefix: 'p:',
            identity: SubscriptionIdentityOverride(userAgent: 'UA'),
          ),
        ],
      );
      final got = out.lists.single as SubscriptionServers;
      expect(got.url, url);
      expect(got.name, 'Новая');
      expect(got.tagPrefix, 'p:');
      expect(got.identity!.userAgent, 'UA');
      expect(got.nodes, isEmpty, reason: 'тело приедет обычным обновлением');
      expect(out.byUrl[url], 0);
    });

    test('запись без URL пропускается: адресовать её нечем', () {
      final out = mergeBackupSubscriptions(
          const [], const [LxSubscription(url: '', label: 'Безадресная')]);
      expect(out.lists, isEmpty);
      expect(out.applied, 0);
    });

    // ══════════════════════════════════════════════════════════════════════
    // §405 — слияние одиночных узлов и папок
    // ══════════════════════════════════════════════════════════════════════

    test('повторный импорт не удваивает одиночные серверы', () {
      const uri = 'vless://u@h:443';
      final first = mergeBackupServers(const [], const [LxServer(uri: uri)]);
      expect(first.lists, hasLength(1));
      expect(first.applied, 1);

      // Тот же файл во второй раз: тело совпало — применять нечего.
      final second =
          mergeBackupServers(first.lists, const [LxServer(uri: uri)]);
      expect(second.lists, hasLength(1),
          reason: 'идентичность одиночной записи — её тело');
      expect(second.applied, 0,
          reason: 'ничего не применилось: узел уже стоит');
      expect(identical(second.lists.single, first.lists.single), isTrue,
          reason: 'своя запись сильнее приехавшей — её не пересобирают');
    });

    test('повторный импорт не удваивает членов папки', () {
      const a = 'vless://a@h:443';
      const b = 'vless://b@h:443';
      final first = mergeBackupServers(const [], const [
        LxServer(uri: a, folder: 'DE'),
        LxServer(uri: b, folder: 'DE'),
      ]);
      expect((first.lists.single as FolderServers).members, hasLength(2));
      expect(first.applied, 2);

      final second = mergeBackupServers(first.lists, const [
        LxServer(uri: a, folder: 'DE'),
        LxServer(uri: b, folder: 'DE'),
      ]);
      expect(second.lists, hasLength(1), reason: 'папка собирается по имени');
      expect((second.lists.single as FolderServers).members, hasLength(2));
      expect(second.applied, 0);
    });

    test('новое тело в существующей папке доливается', () {
      const a = 'vless://a@h:443';
      const b = 'vless://b@h:443';
      final first =
          mergeBackupServers(const [], const [LxServer(uri: a, folder: 'DE')]);
      final second =
          mergeBackupServers(first.lists, const [LxServer(uri: b, folder: 'DE')]);
      final folder = second.lists.single as FolderServers;
      expect(folder.members.map((m) => m.raw), [a, b],
          reason: 'порядок членов — порядок записей файла');
      expect(second.applied, 1);
    });

    test('одиночный и член папки с одним телом — РАЗНЫЕ записи', () {
      // Дедуп одиночных считает только корень списка: тот же узел, лежащий
      // в папке, — другая запись с другими настройками папки.
      const uri = 'vless://u@h:443';
      final out = mergeBackupServers(const [], const [
        LxServer(uri: uri),
        LxServer(uri: uri, folder: 'DE'),
      ]);
      expect(out.lists, hasLength(2));
      expect(out.applied, 2);
    });

    test('config_json одиночного узла дедупится по сериализованному телу', () {
      const server = LxServer(configJson: {'type': 'vless', 'tag': 'n'});
      final first = mergeBackupServers(const [], const [server]);
      final second = mergeBackupServers(first.lists, const [server]);
      expect(second.lists, hasLength(1));
      expect(second.applied, 0);
    });

    test('запись без тела пропускается: применять нечего', () {
      final out = mergeBackupServers(const [], const [LxServer()]);
      expect(out.lists, isEmpty);
      expect(out.applied, 0);
    });

    test('П1 — круг: импорт своего же файла возвращает состояние', () async {
      final state = local(
        name: 'Моя подписка',
        tagPrefix: 'my:',
        enabled: false,
        updateIntervalHours: 12,
        identity: const SubscriptionIdentityOverride(
          userAgent: 'UA',
          sendHwid: true,
          hwid: 'h-1',
        ),
        disabled: {'DE-1': DateTime.utc(2026, 8, 20)},
      );
      final raw = (await buildLxBackup(
        lists: [state],
        rules: const [],
        vars: const {},
      )).json;

      // Приёмник — «то же устройство», но настройки успели уехать в дефолт.
      final wiped = local(
        name: 'Сброшено',
        tagPrefix: '',
        enabled: true,
        updateIntervalHours: 24,
      );
      final back = mergeBackupSubscriptions(
        [wiped],
        parseLxBackup(raw).subscriptions,
      );
      final got = back.lists.single as SubscriptionServers;
      expect(got.name, 'Моя подписка');
      expect(got.tagPrefix, 'my:');
      expect(got.enabled, isFalse);
      expect(got.updateIntervalHours, 12);
      expect(got.identity!.userAgent, 'UA');
      expect(got.identity!.hwid, 'h-1');
      expect(got.disabledHashes.keys, ['DE-1']);
    });
  });
}
