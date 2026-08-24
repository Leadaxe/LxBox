import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:lxbox/models/auto_select.dart';
import 'package:lxbox/models/direction.dart';
import 'package:lxbox/models/node_spec.dart';
import 'package:lxbox/models/template_vars.dart';
import 'package:lxbox/services/builder/server_list_build.dart';
import 'package:lxbox/services/parser/body_decoder.dart';
import 'package:lxbox/services/parser/parse_all.dart';
import 'package:lxbox/services/parser/uri_parsers.dart';

/// §322 — `routing.balancers` + `burstObservatory` → узел автовыбора.
///
/// Провайдер задаёт пул префиксом тега; после §321-дедупа этих тегов уже нет
/// (сервер выжил под именем страны), поэтому резолв идёт через таблицу
/// синонимов §321 P6.
void main() {
  Map<String, dynamic> vless(String addr, {String? tag, String uuid = 'u-1'}) => {
        'tag': tag ?? 'proxy',
        'protocol': 'vless',
        'settings': {
          'vnext': [
            {
              'address': addr,
              'port': 443,
              'users': [
                {'id': uuid, 'encryption': 'none'}
              ],
            }
          ],
        },
        'streamSettings': {'network': 'tcp', 'security': 'none'},
      };

  Map<String, dynamic> plain(String remarks, List<Map<String, dynamic>> obs) => {
        'remarks': remarks,
        'outbounds': [
          ...obs,
          {'tag': 'direct', 'protocol': 'freedom'},
          {'tag': 'block', 'protocol': 'blackhole'},
        ],
      };

  Map<String, dynamic> withBalancer(
    String remarks,
    List<Map<String, dynamic>> obs, {
    List<String> selector = const ['proxy'],
    String type = 'leastLoad',
    Map<String, dynamic> settings = const {'expected': 7, 'maxRTT': '1500ms'},
    Map<String, dynamic>? ping,
    String? fallbackTag,
  }) =>
      {
        ...plain(remarks, obs),
        'routing': {
          'rules': [
            {'network': 'tcp,udp', 'balancerTag': 'B'}
          ],
          'balancers': [
            {
              'tag': 'B',
              'selector': selector,
              'strategy': {'type': type, 'settings': settings},
              if (fallbackTag != null) 'fallbackTag': fallbackTag as Object,
            }
          ],
        },
        'burstObservatory': {
          'pingConfig': ping ??
              {
                'destination': 'http://www.gstatic.com/generate_204',
                'interval': '2m',
                'timeout': '3s',
                'sampling': 3,
              },
          'subjectSelector': selector,
        },
      };

  List<NodeSpec> parse(List<Map<String, dynamic>> elements) =>
      parseAll(decode(jsonEncode(elements)));

  /// Эмуляция билдера: обычные узлы получают итоговые теги, потом резолв пула.
  List<String> poolOf(List<NodeSpec> nodes, AutoSelectSpec a) =>
      resolveAutoSelectMembers(a, {
        for (final n in nodes)
          if (n is! AutoSelectSpec) n: 'L: ${n.label}',
      });

  group('создание узла', () {
    test('элемент с balancers → +1 узел автовыбора', () {
      final nodes = parse([
        withBalancer('🇪🇺 Авто', [
          vless('1.1.1.1', tag: 'proxy-1'),
          vless('2.2.2.2', tag: 'proxy-2'),
        ])
      ]);
      final autos = nodes.whereType<AutoSelectSpec>().toList();
      expect(autos, hasLength(1));
      expect(autos.single.label, '🇪🇺 Авто');
      expect(nodes.whereType<VlessSpec>(), hasLength(2));
    });

    test('элемент без balancers → узла автовыбора нет', () {
      final nodes = parse([
        plain('🇩🇪 Германия', [vless('1.1.1.1')])
      ]);
      expect(nodes.whereType<AutoSelectSpec>(), isEmpty);
    });

    test('узел-группа: нет адреса; URI синтетический', () {
      final a = parse([
        withBalancer('Авто', [vless('1.1.1.1', tag: 'proxy-1')])
      ]).whereType<AutoSelectSpec>().single;
      expect(a.isGroup, isTrue);
      expect(a.server, isEmpty);
      expect(a.port, 0);
      // §7 — форма autogroup:// нужна для хранения в папке, но это не ссылка
      // на сервер: адреса в ней нет, только правило и параметры.
      expect(a.toUri(), startsWith('autogroup://'));
    });

    test('эмитит urltest, а не прокси', () {
      final a = parse([
        withBalancer('Авто', [vless('1.1.1.1', tag: 'proxy-1')])
      ]).whereType<AutoSelectSpec>().single;
      final m = a.emitRaw(const TemplateVars()).map;
      expect(m['type'], 'urltest');
      expect(m['outbounds'], isEmpty); // состав дописывает билдер
    });
  });

  group('схема имён элемента (§322 §6.5)', () {
    List<String> labelsOf(List<Map<String, dynamic>> els) =>
        parse(els).map((n) => n.label).toList();

    test('1 узел без группы → чистый remarks', () {
      expect(labelsOf([plain('🇩🇪 Германия', [vless('1.1.1.1')])]),
          ['🇩🇪 Германия']);
    });

    test('N узлов без группы → у ВСЕХ тег, включая первый', () {
      expect(
        labelsOf([
          plain('Пул', [
            vless('1.1.1.1', tag: 'a'),
            vless('2.2.2.2', tag: 'b'),
          ])
        ]),
        ['Пул a', 'Пул b'],
      );
    });

    test('группа берёт чистый remarks, узлы — с тегом', () {
      // Реальный баг Liberty: первый узел и группа дрались за одно имя, и
      // группа получала `-1` от allocateTag.
      final labels = labelsOf([
        withBalancer('🇪🇺 Авто', [
          vless('1.1.1.1', tag: 'proxy-a'),
          vless('2.2.2.2', tag: 'proxy-b'),
        ])
      ]);
      expect(labels, ['🇪🇺 Авто proxy-a', '🇪🇺 Авто proxy-b', '🇪🇺 Авто']);
      // Ровно одна сущность носит чистое имя.
      expect(labels.where((l) => l == '🇪🇺 Авто'), hasLength(1));
    });

    test('элемент с группой: даже один выживший НЕ берёт remarks', () {
      // Все шесть «БС»-групп Liberty таковы: из трёх узлов уцелел один.
      final labels = labelsOf([
        plain('🇩🇪 Германия', [vless('1.1.1.1', uuid: 'u-de')]),
        withBalancer('Пул', [
          vless('1.1.1.1', tag: 'proxy-dup', uuid: 'u-de'), // дубль
          vless('9.9.9.9', tag: 'proxy-uniq'),
        ]),
      ]);
      expect(labels, ['🇩🇪 Германия', 'Пул proxy-uniq', 'Пул']);
    });

    test('повторяющийся тег → индексный фолбэк, не «Пул proxy» дважды', () {
      expect(
        labelsOf([
          plain('Пул', [
            vless('1.1.1.1', tag: 'proxy'),
            vless('2.2.2.2', tag: 'proxy'),
          ])
        ]),
        ['Пул 1', 'Пул 2'],
      );
    });

    test('пустой тег → индекс, без хвостового пробела', () {
      final labels = labelsOf([
        plain('Пул', [
          vless('1.1.1.1', tag: ''),
          vless('2.2.2.2', tag: 'b'),
        ])
      ]);
      // Порядок — как в элементе: пустой тег стоит первым.
      expect(labels, ['Пул 1', 'Пул b']);
      expect(labels.every((l) => l.trim() == l), isTrue);
    });
  });

  group('маппинг стратегии', () {
    AutoSelectSpec build({
      String type = 'leastLoad',
      Map<String, dynamic> settings = const {},
    }) =>
        parse([
          withBalancer('A', [vless('1.1.1.1', tag: 'proxy-1')],
              type: type, settings: settings)
        ]).whereType<AutoSelectSpec>().single;

    test('random (дефолт Xray) → round_robin по ВСЕМУ набору', () {
      // У `random` нет ни settings, ни expected: раскладка по всем членам.
      final a = parse([
        withBalancer('A', [
          vless('1.1.1.1', tag: 'proxy-1'),
          vless('2.2.2.2', tag: 'proxy-2'),
          vless('3.3.3.3', tag: 'proxy-3'),
        ], type: 'random', settings: const {})
      ]).whereType<AutoSelectSpec>().single;
      expect(a.params.mode, UrltestMode.roundRobin);
      expect(a.params.pool, 3);
    });

    test('роль strategy отсутствует → как random', () {
      final a = parse([
        {
          ...plain('A', [vless('1.1.1.1', tag: 'proxy-1')]),
          'routing': {
            'balancers': [
              {'tag': 'B', 'selector': ['proxy']}, // без strategy вовсе
            ],
          },
        }
      ]).whereType<AutoSelectSpec>().single;
      expect(a.params.mode, UrltestMode.roundRobin);
      expect(a.params.pool, 1);
    });

    test('roundRobin → round_robin по всему набору', () {
      final a = parse([
        withBalancer('A', [
          vless('1.1.1.1', tag: 'proxy-1'),
          vless('2.2.2.2', tag: 'proxy-2'),
        ], type: 'roundRobin', settings: const {})
      ]).whereType<AutoSelectSpec>().single;
      expect(a.params.mode, UrltestMode.roundRobin);
      expect(a.params.pool, 2);
    });

    test('leastPing → least_test', () {
      expect(build(type: 'leastPing').params.mode, UrltestMode.leastTest);
    });

    test('leastLoad с expected>1 → round_robin', () {
      expect(build(type: 'leastLoad', settings: {'expected': 7}).params.mode,
          UrltestMode.roundRobin);
    });

    test('expected≤1 → least_test, а не пул из одного', () {
      // «Держи ОДНОГО живого» — это простой urltest. Балансировщику с пулом
      // из одного нечего балансировать (все шесть «БС»-групп Liberty).
      for (final e in [1, 0]) {
        expect(build(type: 'leastLoad', settings: {'expected': e}).params.mode,
            UrltestMode.leastTest,
            reason: 'expected=$e');
      }
    });

    test('expected → pool', () {
      expect(build(settings: {'expected': 7}).params.pool, 7);
    });

    test('leastLoad без expected → round_robin (пул по умолчанию)', () {
      final p = build(type: 'leastLoad').params;
      expect(p.mode, UrltestMode.roundRobin);
      expect(p.pool, const AutoSelectParams().pool);
    });

    test('maxRTT → pool_tolerance (1:1, семантика расходится)', () {
      // Xray: абсолютный потолок. Наш: окно от лучшего. Числа переносим как
      // есть — минимум по пулу на парсинге неизвестен.
      expect(build(settings: {'maxRTT': '1500ms'}).params.poolTolerance, 1500);
      expect(build(settings: {'maxRTT': '3s'}).params.poolTolerance, 3000);
    });

    test('pool_tolerance клампится по 15000 (SPEC 019)', () {
      expect(build(settings: {'maxRTT': '30s'}).params.poolTolerance,
          kMaxPoolTolerance);
    });

    test('pingConfig → url + interval', () {
      final a = parse([
        withBalancer('A', [vless('1.1.1.1', tag: 'proxy-1')], ping: {
          'destination': 'http://example.com/generate_204',
          'interval': '2m',
        })
      ]).whereType<AutoSelectSpec>().single;
      expect(a.params.url, 'http://example.com/generate_204');
      expect(a.params.interval, '2m');
    });
  });

  group('битые формы balancers не роняют парсинг', () {
    // Подписку пишет провайдер: любое поле может приехать другого типа.
    // Каст вместо `is` уронил бы парсинг ВСЕЙ подписки, а не одного пункта.
    Map<String, dynamic> withRouting(Object? routing) => {
          ...plain('X', [
            vless('1.1.1.1', tag: 'proxy-1'),
            vless('2.2.2.2', tag: 'proxy-2'),
          ]),
          // ignore: use_null_aware_elements — читаемость важнее краткости
          if (routing != null) 'routing': routing,
        };

    void survives(String what, Object? routing, {int nodes = 2, int groups = 0}) {
      final r = parse([withRouting(routing)]);
      expect(r.whereType<VlessSpec>(), hasLength(nodes), reason: what);
      expect(r.whereType<AutoSelectSpec>(), hasLength(groups), reason: what);
    }

    test('balancers пустой / не массив / мусор внутри', () {
      survives('пустой массив', {'balancers': const []});
      survives('число', {'balancers': 42});
      survives('объект вместо массива', {'balancers': {'tag': 'B'}});
      survives('строка внутри массива', {'balancers': const ['мусор']});
    });

    test('routing не объект', () {
      survives('строка', 'мусор');
      survives('список', const [1, 2]);
    });

    test('поля балансировщика битых типов → группа всё равно собирается', () {
      Map<String, dynamic> bal(Map<String, dynamic> b) => {
            'balancers': [
              {'tag': 'B', ...b}
            ]
          };
      survives('нет selector', bal({'strategy': {'type': 'random'}}), groups: 1);
      survives('selector строкой', bal({'selector': 'proxy'}), groups: 1);
      survives('strategy строкой',
          bal({'selector': const ['proxy'], 'strategy': 'leastPing'}),
          groups: 1);
      survives(
          'settings числом',
          bal({
            'selector': const ['proxy'],
            'strategy': {'type': 'leastLoad', 'settings': 5},
          }),
          groups: 1);
    });

    test('expected строкой читается как число', () {
      final a = parse([
        withBalancer('A', [vless('1.1.1.1', tag: 'proxy-1')],
            settings: const {'expected': '7'})
      ]).whereType<AutoSelectSpec>().single;
      expect(a.params.pool, 7);
    });

    test('burstObservatory не объект → дефолтные url/interval', () {
      final a = parse([
        {
          ...withBalancer('A', [vless('1.1.1.1', tag: 'proxy-1')]),
          'burstObservatory': 7,
        }
      ]).whereType<AutoSelectSpec>().single;
      expect(a.params.url, const AutoSelectParams().url);
      expect(a.params.interval, const AutoSelectParams().interval);
    });
  });

  group('selector → include-правило', () {
    test('["proxy"] → ^(proxy)', () {
      final a = parse([
        withBalancer('A', [vless('1.1.1.1', tag: 'proxy-1')])
      ]).whereType<AutoSelectSpec>().single;
      expect((a.membership as RuleMembers).include, '^(proxy)');
    });

    test('несколько префиксов → альтернатива', () {
      final a = parse([
        withBalancer('A', [vless('1.1.1.1', tag: 'proxy-1')],
            selector: ['proxy', 'backup'])
      ]).whereType<AutoSelectSpec>().single;
      expect((a.membership as RuleMembers).include, '^(proxy|backup)');
    });

    test('спецсимволы тега экранируются', () {
      final r = RuleMembers.fromXraySelector(['a.b+c']);
      expect(RegExp(r.include).hasMatch('a.b+c-1'), isTrue);
      expect(RegExp(r.include).hasMatch('axbxc'), isFalse);
    });
  });

  group('резолв пула через синонимы (§321 P6)', () {
    test('находит узлы, выжившие под именами стран', () {
      final nodes = parse([
        // Одиночные короче → по P2 идут первыми и дают имена.
        plain('🇪🇸 Испания', [vless('1.1.1.1')]),
        plain('🇩🇪 Германия', [vless('2.2.2.2')]),
        withBalancer('🇪🇺 Авто', [
          vless('1.1.1.1', tag: 'proxy-1-1-1-1'),
          vless('2.2.2.2', tag: 'proxy-2-2-2-2'),
        ]),
      ]);
      final a = nodes.whereType<AutoSelectSpec>().single;
      // Правило написано на тегах провайдера, а узлы зовутся по-русски.
      expect(poolOf(nodes, a), ['L: 🇪🇸 Испания', 'L: 🇩🇪 Германия']);
    });

    test('пул ограничен СВОИМ элементом', () {
      // Тег `proxy` есть у обоих одиночных элементов; без ограничения
      // областью `^(proxy)` затянул бы их в пул (реальный баг на Liberty).
      final nodes = parse([
        plain('🇪🇸 Испания', [vless('1.1.1.1')]),
        plain('🇩🇪 Германия', [vless('2.2.2.2')]),
        plain('🇫🇷 Франция', [vless('3.3.3.3')]),
        withBalancer('Авто', [
          vless('1.1.1.1', tag: 'proxy-a'),
          vless('2.2.2.2', tag: 'proxy-b'),
        ]),
      ]);
      final a = nodes.whereType<AutoSelectSpec>().single;
      final pool = poolOf(nodes, a);
      expect(pool, hasLength(2));
      expect(pool, isNot(contains('L: 🇫🇷 Франция')));
    });

    test('уникальный член пула тоже в составе', () {
      final nodes = parse([
        plain('🇪🇸 Испания', [vless('1.1.1.1')]),
        withBalancer('Авто', [
          vless('1.1.1.1', tag: 'proxy-a'),
          vless('9.9.9.9', tag: 'proxy-uniq'), // только здесь
        ]),
      ]);
      final a = nodes.whereType<AutoSelectSpec>().single;
      expect(poolOf(nodes, a), hasLength(2));
    });

    test('исчезнувший член просто пропускается', () {
      final nodes = parse([
        plain('🇪🇸 Испания', [vless('1.1.1.1')]),
        withBalancer('Авто', [
          vless('1.1.1.1', tag: 'proxy-a'),
          vless('2.2.2.2', tag: 'proxy-b'),
        ]),
      ]);
      final a = nodes.whereType<AutoSelectSpec>().single;
      // Резолвим по неполному набору — как если бы узел выключили (§283).
      final partial = {
        for (final n in nodes)
          if (n is VlessSpec && n.server == '1.1.1.1') n: 'L: 🇪🇸 Испания',
      };
      expect(resolveAutoSelectMembers(a, partial), ['L: 🇪🇸 Испания']);
    });
  });

  group('явный список', () {
    test('порядок задаёт список, не обход контейнера', () {
      final nodes = parse([
        plain('A', [vless('1.1.1.1', uuid: 'u-a')]),
        plain('B', [vless('2.2.2.2', uuid: 'u-b')]),
      ]);
      final resolved = {for (final n in nodes) n: 'L: ${n.label}'};
      final a = AutoSelectSpec(
        id: 'x',
        tag: 'auto',
        label: 'Auto',
        membership: const ExplicitMembers([
          'vless|2.2.2.2|443|u-b',
          'vless|1.1.1.1|443|u-a',
        ]),
      );
      expect(resolveAutoSelectMembers(a, resolved), ['L: B', 'L: A']);
    });

    test('неизвестный ключ пропускается, остальные остаются', () {
      final nodes = parse([
        plain('A', [vless('1.1.1.1', uuid: 'u-a')])
      ]);
      final a = AutoSelectSpec(
        id: 'x',
        tag: 'auto',
        label: 'Auto',
        membership: const ExplicitMembers([
          'vless|9.9.9.9|443|gone',
          'vless|1.1.1.1|443|u-a',
        ]),
      );
      expect(resolveAutoSelectMembers(a, {for (final n in nodes) n: 'L: A'}),
          ['L: A']);
    });
  });

  group('формат эмиссии urltest (ядро SPEC 019)', () {
    Map<String, dynamic> emit(AutoSelectParams p) => AutoSelectSpec(
          id: 'x',
          tag: 't',
          label: 'A',
          params: p,
        ).emitRaw(const TemplateVars()).map;

    test('round_robin: pool/tolerance/sticky ВНУТРИ balancer{}', () {
      // Плоские `pool`/`pool_tolerance` ядро отвергает как unknown field —
      // падает весь конфиг, а не одна группа (device 31.07.2026).
      final m = emit(const AutoSelectParams(
        mode: UrltestMode.roundRobin,
        pool: 7,
        poolTolerance: 1500,
      ));
      expect(m.containsKey('pool'), isFalse, reason: 'плоский pool = unknown field');
      expect(m.containsKey('pool_tolerance'), isFalse);
      expect(m.containsKey('sticky_hash'), isFalse);
      expect(m['mode'], 'round_robin');
      expect(m['balancer'], {
        'pool': 7,
        'pool_tolerance': 1500,
        'sticky_hash': ['process', 'domain'],
      });
    });

    test('least_test: ни mode, ни balancer (бит-в-бит апстрим)', () {
      final m = emit(const AutoSelectParams());
      expect(m.containsKey('mode'), isFalse);
      // `balancer` без round_robin роняет старт ядра.
      expect(m.containsKey('balancer'), isFalse);
      expect(m.keys, containsAll(['tag', 'type', 'outbounds', 'url', 'interval']));
    });

    test('interrupt_exist_connections эмитится всегда', () {
      expect(emit(const AutoSelectParams())['interrupt_exist_connections'],
          isFalse);
      expect(
          emit(const AutoSelectParams(interruptExistConnections: true))[
              'interrupt_exist_connections'],
          isTrue);
    });

    test('снятая липкость → sentinel ["none"] (§210)', () {
      // Пустой список ядро схлопывает в nil = дефолт ["process","domain"].
      final m = emit(const AutoSelectParams(
        mode: UrltestMode.roundRobin,
        stickyHash: [],
      ));
      expect((m['balancer'] as Map)['sticky_hash'], ['none']);
    });
  });

  group('URI-форма autogroup:// (§7)', () {
    AutoSelectSpec rt(AutoSelectSpec a) => parseUri(a.toUri()) as AutoSelectSpec;

    test('правило переживает round-trip', () {
      final a = AutoSelectSpec(
        id: 'x',
        tag: 't',
        label: '🇪🇺 Авто | Лучший ⚡',
        membership: const RuleMembers(include: '^(proxy)', exclude: 'decoy'),
        params: const AutoSelectParams(
          mode: UrltestMode.roundRobin,
          pool: 7,
          poolTolerance: 1500,
          interval: '2m',
        ),
      );
      final b = rt(a);
      expect(b.label, '🇪🇺 Авто | Лучший ⚡');
      final m = b.membership as RuleMembers;
      expect(m.include, '^(proxy)');
      expect(m.exclude, 'decoy');
      expect(b.params.mode, UrltestMode.roundRobin);
      expect(b.params.pool, 7);
      expect(b.params.poolTolerance, 1500);
      expect(b.params.interval, '2m');
    });

    test('явный список переживает round-trip', () {
      final a = AutoSelectSpec(
        id: 'y',
        tag: 't',
        label: 'E',
        membership: const ExplicitMembers([
          'vless|1.1.1.1|443|u-1',
          'vless|2.2.2.2|443|u-2',
        ]),
      );
      expect((rt(a).membership as ExplicitMembers).keys,
          ['vless|1.1.1.1|443|u-1', 'vless|2.2.2.2|443|u-2']);
    });

    test('interrupt переживает round-trip', () {
      final a = AutoSelectSpec(
        id: 'i',
        tag: 't',
        label: 'A',
        params: const AutoSelectParams(interruptExistConnections: true),
      );
      expect((parseUri(a.toUri()) as AutoSelectSpec)
          .params
          .interruptExistConnections, isTrue);
    });

    test('дефолты в URI не пишутся', () {
      final uri = AutoSelectSpec(id: 'z', tag: 't', label: 'A').toUri();
      expect(uri, isNot(contains('url=')));
      expect(uri, isNot(contains('interval=')));
      expect(uri, isNot(contains('pool=')));
    });

    test('пустое правило = все члены контейнера', () {
      final b = rt(AutoSelectSpec(id: 'z', tag: 't', label: 'A'));
      final m = b.membership as RuleMembers;
      expect(m.include, isEmpty);
      expect(m.exclude, isEmpty);
    });

    test('снятые sticky-чипы переживают round-trip (§210 sentinel)', () {
      final a = AutoSelectSpec(
        id: 'z',
        tag: 't',
        label: 'A',
        params: const AutoSelectParams(
            mode: UrltestMode.roundRobin, stickyHash: []),
      );
      expect(rt(a).params.stickyHash, isEmpty);
    });

    test('чужая схема не парсится как группа', () {
      expect(parseUri('vless://u@1.1.1.1:443#N'), isNot(isA<AutoSelectSpec>()));
    });
  });

  test('битый regex не роняет узел', () {
    final nodes = parse([
      plain('A', [vless('1.1.1.1')])
    ]);
    final a = AutoSelectSpec(
      id: 'x',
      tag: 'auto',
      label: 'Auto',
      membership: const RuleMembers(include: '[unclosed'),
    );
    // Битый include = пустой → берём всех (как nodesFor §125).
    expect(resolveAutoSelectMembers(a, {for (final n in nodes) n: 'L: A'}),
        ['L: A']);
  });
}
