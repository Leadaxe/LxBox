import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:lxbox/models/auto_select.dart';
import 'package:lxbox/models/node_spec.dart';
import 'package:lxbox/models/node_warning.dart';
import 'package:lxbox/services/node_identity.dart';
import 'package:lxbox/services/parser/body_decoder.dart';
import 'package:lxbox/services/parser/parse_all.dart';
import 'package:lxbox/services/parser/singbox_config.dart';

/// §368 — разбор sing-box JSON: паритет с Xray-веткой.

Map<String, dynamic> vless(String tag, String server,
        {String? detour, int port = 443, String uuid = 'u-1'}) =>
    {
      'type': 'vless',
      'tag': tag,
      'server': server,
      'server_port': port,
      'uuid': uuid,
      'detour': ?detour,
    };

Map<String, dynamic> cfg(List<Map<String, dynamic>> outbounds,
        {Map<String, dynamic>? extra}) =>
    {'outbounds': outbounds, ...?extra};

List<NodeSpec> parse(List<Map<String, dynamic>> configs) =>
    parseSingboxConfigs(configs);

/// Разбор через публичный вход (decode → parseAll): проверяет и flavor.
List<NodeSpec> parseText(Object json) => parseAll(decode(jsonEncode(json)));

void main() {
  group('§368 формы входа', () {
    final ob = vless('hk', 'a.com');

    test('все четыре формы дают одинаковые узлы', () {
      final single = parseText(ob);
      final array = parseText([ob]);
      final config = parseText(cfg([ob]));
      final multi = parseText([
        cfg([ob])
      ]);

      for (final r in [single, array, config, multi]) {
        expect(r, hasLength(1));
        expect(r.single.server, 'a.com');
        expect(r.single.label, 'hk');
      }
    });

    test('flavor распознаётся для каждой формы', () {
      expect((decode(jsonEncode(ob)) as JsonConfig).flavor,
          JsonFlavor.singboxOutbound);
      expect((decode(jsonEncode([ob])) as JsonConfig).flavor,
          JsonFlavor.singboxArray);
      expect((decode(jsonEncode(cfg([ob]))) as JsonConfig).flavor,
          JsonFlavor.singboxConfig);
      expect(
          (decode(jsonEncode([
            cfg([ob])
          ])) as JsonConfig)
              .flavor,
          JsonFlavor.singboxMulti);
    });

    test('массив конфигов: Xray и sing-box различаются по содержимому', () {
      final xray = jsonEncode([
        {
          'outbounds': [
            {'protocol': 'vless', 'tag': 'proxy'}
          ]
        }
      ]);
      expect((decode(xray) as JsonConfig).flavor, JsonFlavor.xrayArray);

      final sb = jsonEncode([
        cfg([ob])
      ]);
      expect((decode(sb) as JsonConfig).flavor, JsonFlavor.singboxMulti);
    });

    test('неоднозначный элемент остаётся xrayArray (ветка уже работает)', () {
      // Ни `type`, ни `protocol` — классификацию менять нельзя.
      final r = decode(jsonEncode([
        {
          'outbounds': [
            {'tag': 'x'}
          ]
        }
      ]));
      expect((r as JsonConfig).flavor, JsonFlavor.xrayArray);
    });

    test('одиночный selector — outbound, а не конфиг (порядок проверок)', () {
      final r = decode(jsonEncode({
        'type': 'selector',
        'tag': 'auto',
        'outbounds': ['a']
      }));
      expect((r as JsonConfig).flavor, JsonFlavor.singboxOutbound);
    });
  });

  group('§368 P1 — что становится узлом', () {
    test('служебные типы узлами не становятся', () {
      final r = parse([
        cfg([
          vless('hk', 'a.com'),
          {'type': 'direct', 'tag': 'direct'},
          {'type': 'block', 'tag': 'block'},
          {'type': 'dns', 'tag': 'dns-out'},
        ])
      ]);
      expect(r, hasLength(1));
      expect(r.single.label, 'hk');
    });

    test('конфиг только из служебных → пусто', () {
      final r = parse([
        cfg([
          {'type': 'direct', 'tag': 'direct'}
        ])
      ]);
      expect(r, isEmpty);
    });

    test('endpoints (WireGuard) разбирается наравне с outbounds', () {
      final r = parse([
        {
          'endpoints': [
            {
              'type': 'wireguard',
              'tag': 'wg',
              'private_key': 'priv',
              'address': ['10.0.0.2/32'],
              'peers': [
                {
                  'address': 'wg.example.com',
                  'port': 51820,
                  'public_key': 'pub',
                  'allowed_ips': ['0.0.0.0/0'],
                }
              ],
            }
          ]
        }
      ]);
      expect(r, hasLength(1));
      expect(r.single, isA<WireguardSpec>());
      expect(r.single.server, 'wg.example.com');
    });

    test('конфиг без outbounds и endpoints → пусто, не бросает', () {
      expect(parse([{}]), isEmpty);
      expect(
          parse([
            {'route': {}, 'dns': {}}
          ]),
          isEmpty);
    });
  });

  group('§368 P2/§342 — два прохода', () {
    test('имя сервера даёт одиночный элемент, а не пул', () {
      final server = vless('proxy', 'shared.com');
      final named = {...server, 'tag': '🇪🇸 Испания'};
      final r = parse([
        // Пул (2 узла) стоит первым в файле, одиночная «карточка» — вторым.
        cfg([server, vless('other', 'other.com')]),
        cfg([named]),
      ]);

      final shared = r.firstWhere((n) => n.server == 'shared.com');
      expect(shared.label, '🇪🇸 Испания');
    });

    test('порядок списка — авторский, не отсортированный', () {
      final r = parse([
        cfg([vless('pool-a', 'p1.com'), vless('pool-b', 'p2.com')]),
        cfg([vless('solo', 's.com')]),
      ]);
      expect(r.map((n) => n.server).toList(),
          ['p1.com', 'p2.com', 's.com']);
    });

    test('порядок стабилен за границей quicksort (40 элементов)', () {
      final configs = [
        for (var i = 0; i < 40; i++)
          cfg([vless('n$i', 'host$i.com', uuid: 'u-$i')])
      ];
      final r = parse(configs);
      expect(r.map((n) => n.server).toList(),
          [for (var i = 0; i < 40; i++) 'host$i.com']);
    });
  });

  group('§368 P3 — имя узла', () {
    test('тег становится именем', () {
      final r = parse([
        cfg([vless('🇩🇪 Frankfurt', 'de.com')])
      ]);
      expect(r.single.label, '🇩🇪 Frankfurt');
      expect(r.single.tag, '🇩🇪 Frankfurt');
    });

    test('пустой тег → фолбэк конвертера', () {
      final r = parse([
        cfg([
          {
            'type': 'vless',
            'server': 'a.com',
            'server_port': 443,
            'uuid': 'u',
          }
        ])
      ]);
      expect(r.single.tag, 'vless-a.com-443');
    });

    test('повтор тега в конфиге → индексный суффикс', () {
      final r = parse([
        cfg([
          vless('proxy', 'a.com', uuid: 'u-a'),
          vless('proxy', 'b.com', uuid: 'u-b'),
        ])
      ]);
      expect(r.map((n) => n.label).toList(), ['proxy 1', 'proxy 2']);
    });
  });

  group('§368 P4 — дедуп', () {
    test('один сервер в двух конфигах под разными тегами → один узел', () {
      final r = parse([
        cfg([vless('a', 'same.com')]),
        cfg([vless('b', 'same.com')]),
      ]);
      expect(r, hasLength(1));
    });

    test('разные credential — разные узлы', () {
      final r = parse([
        cfg([vless('a', 'same.com', uuid: 'u-1')]),
        cfg([vless('b', 'same.com', uuid: 'u-2')]),
      ]);
      expect(r, hasLength(2));
    });

    test('ключ совпадает с nodeIdentityKey', () {
      final r = parse([
        cfg([vless('a', 'x.com')])
      ]);
      expect(nodeIdentityKey(r.single), 'vless|x.com|443|u-1');
    });
  });

  group('§368 P5 — ничего не теряется молча', () {
    test('неизвестный type → warning на соседе', () {
      final r = parse([
        cfg([
          vless('ok', 'a.com'),
          {'type': 'shadowtls', 'tag': 'st', 'server': 'b.com'},
        ])
      ]);
      expect(r, hasLength(1));
      expect(r.single.warnings, contains(const UnsupportedProtocolWarning('shadowtls')));
    });

    test('битая форма outbound не роняет соседей', () {
      // `transport` строкой вместо объекта — конвертер бросит TypeError внутри.
      final r = parse([
        cfg([
          vless('ok', 'a.com'),
          {
            'type': 'vmess',
            'tag': 'bad',
            'server': 'b.com',
            'server_port': 443,
            'uuid': 'u',
            'alter_id': 'не число',
          },
        ])
      ]);
      expect(r, hasLength(1));
      expect(r.single.server, 'a.com');
      expect(r.single.warnings.whereType<UnsupportedProtocolWarning>(),
          isNotEmpty);
    });

    test('warning по одному на тип, не на каждый outbound', () {
      final r = parse([
        cfg([
          vless('ok', 'a.com'),
          {'type': 'shadowtls', 'tag': 'st1'},
          {'type': 'shadowtls', 'tag': 'st2'},
        ])
      ]);
      final unsupported = r.single.warnings
          .whereType<UnsupportedProtocolWarning>()
          .where((w) => w.scheme == 'shadowtls');
      expect(unsupported, hasLength(1));
    });
  });

  group('§368 §4 — detour', () {
    test('A → B: B не самостоятельный узел, A.chained == B', () {
      final r = parse([
        cfg([
          vless('a', 'a.com', detour: 'jump'),
          vless('jump', 'jump.com', uuid: 'u-j'),
        ])
      ]);
      expect(r, hasLength(1));
      expect(r.single.server, 'a.com');
      expect(r.single.chained?.server, 'jump.com');
    });

    test('A → B → C: цепочка разворачивается рекурсивно', () {
      final r = parse([
        cfg([
          vless('a', 'a.com', detour: 'b'),
          vless('b', 'b.com', detour: 'c', uuid: 'u-b'),
          vless('c', 'c.com', uuid: 'u-c'),
        ])
      ]);
      expect(r, hasLength(1));
      expect(r.single.chained?.server, 'b.com');
      expect(r.single.chained?.chained?.server, 'c.com');
    });

    test('звеном может быть любой тип, не только vless/trojan', () {
      final r = parse([
        cfg([
          vless('a', 'a.com', detour: 'jump'),
          {
            'type': 'shadowsocks',
            'tag': 'jump',
            'server': 'ss.com',
            'server_port': 8388,
            'method': 'aes-128-gcm',
            'password': 'p',
          },
        ])
      ]);
      expect(r.single.chained, isA<ShadowsocksSpec>());
    });

    test('одна цель у двух владельцев: копия каждому, узлом не стала', () {
      final r = parse([
        cfg([
          vless('a', 'a.com', detour: 'jump', uuid: 'u-a'),
          vless('b', 'b.com', detour: 'jump', uuid: 'u-b'),
          vless('jump', 'jump.com', uuid: 'u-j'),
        ])
      ]);
      expect(r, hasLength(2));
      expect(r[0].chained?.server, 'jump.com');
      expect(r[1].chained?.server, 'jump.com');
    });

    test('цикл A → B → A: ребро снято, узлы не исчезают', () {
      final r = parse([
        cfg([
          vless('a', 'a.com', detour: 'b', uuid: 'u-a'),
          vless('b', 'b.com', detour: 'a', uuid: 'u-b'),
        ])
      ]);
      // Кольцо рвётся на первом обойдённом узле (`a`), поэтому `a` остаётся
      // самостоятельным узлом, а `b` приезжает его звеном. Молчаливой потери
      // нет: серверы из конфига доехали оба.
      final servers = <String>{};
      for (var n in r) {
        servers.add(n.server);
        for (var c = n.chained; c != null; c = c.chained) {
          servers.add(c.server);
        }
      }
      expect(servers, {'a.com', 'b.com'});
      expect(r, isNotEmpty);
    });

    test('цикл A → B → C → A: все три сервера доезжают', () {
      final r = parse([
        cfg([
          vless('a', 'a.com', detour: 'b', uuid: 'u-a'),
          vless('b', 'b.com', detour: 'c', uuid: 'u-b'),
          vless('c', 'c.com', detour: 'a', uuid: 'u-c'),
        ])
      ]);
      final servers = <String>{};
      for (var n in r) {
        servers.add(n.server);
        for (var c = n.chained; c != null; c = c.chained) {
          servers.add(c.server);
        }
      }
      expect(servers, {'a.com', 'b.com', 'c.com'});
    });

    test('самоссылка → warning, узел жив', () {
      final r = parse([
        cfg([
          vless('a', 'a.com', detour: 'a'),
          vless('other', 'o.com', uuid: 'u-o'),
        ])
      ]);
      final a = r.firstWhere((n) => n.server == 'a.com');
      expect(a.chained, isNull);
      expect(a.warnings.whereType<DetourCycleBrokenWarning>(), isNotEmpty);
    });

    test('висячая ссылка → узел без цепочки + warning', () {
      final r = parse([
        cfg([vless('a', 'a.com', detour: 'nonexistent')])
      ]);
      expect(r.single.chained, isNull);
      expect(r.single.warnings,
          contains(const DetourTargetMissingWarning('nonexistent')));
    });

    test('detour на группу → без цепочки + warning', () {
      final r = parse([
        cfg([
          vless('a', 'a.com', detour: 'auto'),
          vless('m', 'm.com', uuid: 'u-m'),
          {
            'type': 'urltest',
            'tag': 'auto',
            'outbounds': ['m'],
          },
        ])
      ]);
      final a = r.firstWhere((n) => n.server == 'a.com');
      expect(a.chained, isNull);
      expect(a.warnings, contains(const DetourToGroupWarning('auto')));
    });

    test('detour: direct — не звено и не ошибка, молча', () {
      final r = parse([
        cfg([
          vless('a', 'a.com', detour: 'direct'),
          {'type': 'direct', 'tag': 'direct'},
        ])
      ]);
      expect(r.single.chained, isNull);
      expect(r.single.warnings, isEmpty);
    });

    test('цепочка глубже лимита обрезается + warning', () {
      final chain = [
        for (var i = 0; i < 12; i++)
          vless('n$i', 'h$i.com',
              detour: i < 11 ? 'n${i + 1}' : null, uuid: 'u-$i')
      ];
      final r = parse([cfg(chain)]);
      expect(r, hasLength(1));

      var depth = 0;
      NodeSpec? cur = r.single.chained;
      while (cur != null) {
        depth++;
        cur = cur.chained;
      }
      expect(depth, kMaxDetourDepth);
      expect(r.single.warnings,
          contains(const DetourChainTooDeepWarning(kMaxDetourDepth)));
    });
  });

  group('§368 §5 — группы', () {
    Map<String, dynamic> group(List<String> members,
            {String type = 'urltest', Map<String, dynamic>? extra}) =>
        {
          'type': type,
          'tag': 'auto',
          'outbounds': members,
          ...?extra,
        };

    test('urltest → узел автовыбора с ExplicitMembers', () {
      final r = parse([
        cfg([
          vless('a', 'a.com', uuid: 'u-a'),
          vless('b', 'b.com', uuid: 'u-b'),
          group(['a', 'b']),
        ])
      ]);
      expect(r, hasLength(3));
      final g = r.last as AutoSelectSpec;
      expect(g.label, 'auto');
      expect(g.membership, isA<ExplicitMembers>());
      expect((g.membership as ExplicitMembers).keys, [
        'vless|a.com|443|u-a',
        'vless|b.com|443|u-b',
      ]);
    });

    test('группа идёт после своих членов', () {
      final r = parse([
        cfg([
          group(['a']),
          vless('a', 'a.com'),
        ])
      ]);
      expect(r.first.isGroup, isFalse);
      expect(r.last.isGroup, isTrue);
    });

    test('параметры маппятся', () {
      final r = parse([
        cfg([
          vless('a', 'a.com'),
          group(['a'], extra: {
            'url': 'https://example.com/204',
            'interval': '5m',
            'tolerance': 100,
            'idle_timeout': '10m',
            'interrupt_exist_connections': true,
          }),
        ])
      ]);
      final g = r.last as AutoSelectSpec;
      expect(g.params.url, 'https://example.com/204');
      expect(g.params.interval, '5m');
      expect(g.params.tolerance, 100);
      expect(g.params.idleTimeout, '10m');
      expect(g.params.interruptExistConnections, isTrue);
    });

    test('отсутствующие параметры → наши дефолты', () {
      final r = parse([
        cfg([
          vless('a', 'a.com'),
          group(['a']),
        ])
      ]);
      const d = AutoSelectParams();
      final g = r.last as AutoSelectSpec;
      expect(g.params.url, d.url);
      expect(g.params.interval, d.interval);
      expect(g.params.tolerance, d.tolerance);
      expect(g.params.mode, d.mode);
    });

    test('selector → группа + warning', () {
      final r = parse([
        cfg([
          vless('a', 'a.com'),
          group(['a'], type: 'selector'),
        ])
      ]);
      final g = r.last as AutoSelectSpec;
      expect(g.warnings, contains(const SelectorAsAutoWarning()));
    });

    test('вложенная группа выпадает из состава + warning', () {
      final r = parse([
        cfg([
          vless('a', 'a.com'),
          vless('b', 'b.com', uuid: 'u-b'),
          {
            'type': 'urltest',
            'tag': 'inner',
            'outbounds': ['b'],
          },
          {
            'type': 'urltest',
            'tag': 'outer',
            'outbounds': ['a', 'inner'],
          },
        ])
      ]);
      final outer = r.firstWhere((n) => n.label == 'outer') as AutoSelectSpec;
      expect((outer.membership as ExplicitMembers).keys, hasLength(1));
      expect(outer.warnings, contains(const GroupMemberMissingWarning(1)));
    });

    test('состав пуст → группы нет вовсе', () {
      final r = parse([
        cfg([
          vless('a', 'a.com'),
          group(['nonexistent']),
        ])
      ]);
      expect(r.where((n) => n.isGroup), isEmpty);
    });

    test('состав на тегах соседнего конфига резолвится через синонимы', () {
      final r = parse([
        cfg([vless('hk', 'hk.com', uuid: 'u-hk')]),
        cfg([
          vless('other', 'other.com', uuid: 'u-o'),
          {
            'type': 'urltest',
            'tag': 'auto',
            'outbounds': ['hk', 'other'],
          },
        ]),
      ]);
      final g = r.firstWhere((n) => n.isGroup) as AutoSelectSpec;
      expect((g.membership as ExplicitMembers).keys, hasLength(2));
      expect(g.warnings.whereType<GroupMemberMissingWarning>(), isEmpty);
    });

    test('дубли в составе схлопываются', () {
      final r = parse([
        cfg([
          vless('a', 'a.com'),
          vless('b', 'a.com'), // тот же сервер → одна идентичность
          group(['a', 'b']),
        ])
      ]);
      final g = r.firstWhere((n) => n.isGroup) as AutoSelectSpec;
      expect((g.membership as ExplicitMembers).keys, hasLength(1));
    });
  });

  group('§368 — устойчивость к битым формам', () {
    test('мусорные типы полей не бросают', () {
      expect(
          () => parse([
                {'outbounds': 'нет'},
                {'outbounds': null},
                {
                  'outbounds': [42, 'строка', null]
                },
                {
                  'outbounds': [
                    {'type': 'vless', 'tag': 'a', 'detour': 5}
                  ]
                },
                {
                  'outbounds': [
                    {'type': 'urltest', 'tag': 'g', 'outbounds': 'нет'}
                  ]
                },
              ]),
          returnsNormally);
    });

    test('валидные соседи выживают рядом с мусором', () {
      final r = parse([
        {'outbounds': 'нет'},
        cfg([vless('ok', 'a.com')]),
      ]);
      expect(r, hasLength(1));
      expect(r.single.server, 'a.com');
    });

    test('пустой список конфигов → пусто', () {
      expect(parse([]), isEmpty);
    });
  });

  group('§368 — источник для UI (§302)', () {
    test('sourceCompact = сам outbound, sourceExtended = конфиг', () {
      final r = parse([
        cfg([vless('a', 'a.com')], extra: {
          'route': {'rules': []}
        })
      ]);
      expect(r.single.sourceCompact, contains('"tag": "a"'));
      expect(r.single.sourceExtended, contains('route'));
    });
  });
}
