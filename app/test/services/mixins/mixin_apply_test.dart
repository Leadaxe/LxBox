import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:lxbox/models/mixin.dart';
import 'package:lxbox/models/validation.dart';
import 'package:lxbox/services/mixins/mixin_apply.dart';

/// §704 §2/§4 — глаголы × число совпадений, на golden rich_v0.
void main() {
  late String goldenRaw;
  setUpAll(() {
    goldenRaw = File('test/fixtures/storage/golden/rich_v0.config.json')
        .readAsStringSync();
  });
  Map<String, dynamic> golden() =>
      jsonDecode(goldenRaw) as Map<String, dynamic>;

  Mixin mx(String target, String op, Object? value,
          {String name = 'm', bool enabled = true}) =>
      Mixin(
          name: name, target: target, op: op, value: value, enabled: enabled);

  MixinApplyResult run(List<Mixin> ms, [Map<String, dynamic>? cfg]) =>
      applyMixins(cfg ?? golden(), ms);

  Map<String, dynamic> ok(List<Mixin> ms) {
    final r = run(ms);
    expect(r.issues, isEmpty, reason: r.issues.map((i) => i.renderEn()).join());
    return r.config;
  }

  String reason(Mixin m) {
    final r = run([m]);
    expect(r.issues, hasLength(1));
    return r.issues.single.reason;
  }

  List rules(Map c) => (c['route'] as Map)['rules'] as List;
  List outs(Map c) => c['outbounds'] as List;

  test('без включённых миксинов — тот же объект', () {
    final cfg = golden();
    expect(identical(run([], cfg).config, cfg), isTrue);
    expect(identical(run([mx('log.level', 'set', 'warn', enabled: false)], cfg)
        .config, cfg), isTrue);
  });

  test('вход не меняется', () {
    final cfg = golden();
    run([mx('log.level', 'set', 'warn')], cfg);
    expect((cfg['log'] as Map)['level'], 'debug');
  });

  group('append / prepend', () {
    test('append: значение и значение-список', () {
      final c = ok([
        mx('inbounds', 'append', {'type': 'direct', 'tag': 'dns-in'}),
        mx('inbounds', 'append', [
          {'type': 'direct', 'tag': 'a'},
          {'type': 'direct', 'tag': 'b'},
        ]),
      ]);
      expect((c['inbounds'] as List).map((e) => e['tag']),
          ['tun-in', 'mixed-in', 'dns-in', 'a', 'b']);
    });

    test('prepend сохраняет порядок значения', () {
      final c = ok([
        mx('route.rules[0].inbound', 'prepend', ['x', 'y']),
      ]);
      expect(rules(c)[0]['inbound'], ['x', 'y', 'tun-in', 'mixed-in']);
    });

    test('0 / несколько / не список', () {
      expect(reason(mx('nope', 'append', 1)), 'no match');
      expect(reason(mx('route.rules[inbound=tun-in].inbound', 'append', 'z')),
          'needs a single list');
      expect(reason(mx('log', 'append', 1)), 'needs a single list');
    });
  });

  group('before / after', () {
    test('before одного: правило hijack-dns (пример §4)', () {
      final c = ok([
        mx('route.rules[action=hijack-dns]', 'before',
            {'inbound': ['dns-in'], 'action': 'hijack-dns'}),
      ]);
      expect(rules(c)[1], {'inbound': ['dns-in'], 'action': 'hijack-dns'});
      expect(rules(c)[2], {'protocol': 'dns', 'action': 'hijack-dns'});
    });

    test('after нескольких — после последнего, список по порядку', () {
      final c = ok([
        mx('route.rules[action=resolve,strategy=prefer_ipv4]', 'after', [
          {'domain_suffix': ['.nas.home'], 'outbound': 'direct-out'},
          {'domain_suffix': ['.b'], 'outbound': 'direct-out'},
        ]),
      ]);
      expect(rules(c)[5]['domain_suffix'], ['.nas.home']);
      expect(rules(c)[6]['domain_suffix'], ['.b']);
      expect(rules(c)[7]['outbound'], 'vpn-2');
    });

    test('before нескольких — перед первым', () {
      final c = ok([mx('outbounds[type=vless]', 'before', {'tag': 'X', 'type': 'direct'})]);
      expect(outs(c)[2]['tag'], 'X');
      expect(outs(c)[3]['tag'], 'PR DE-1');
    });

    test('ошибки: 0, не элемент списка', () {
      expect(reason(mx('route.rules[action=nope]', 'before', {})), 'no match');
      expect(reason(mx('inbounds', 'after', {})), 'not a list element');
      expect(reason(mx('log.level', 'before', {})), 'not a list element');
    });
  });

  group('set', () {
    test('скаляр (пример §4)', () {
      expect((ok([mx('log.level', 'set', 'warn')])['log'] as Map)['level'],
          'warn');
    });

    test('несколько — одно значение каждому, копии независимы', () {
      final c = ok([mx('outbounds[type=vless].tls', 'set', {'enabled': false})]);
      final tls = [
        for (final o in outs(c))
          if (o['type'] == 'vless') o['tls'],
      ];
      expect(tls, hasLength(4));
      expect(tls.every((t) => (t as Map)['enabled'] == false), isTrue);
      expect(identical(tls[0], tls[1]), isFalse);
    });

    test('элемент списка, корень, отказы', () {
      final c = ok([mx('route.rules[0]', 'set', {'action': 'sniff'})]);
      expect(rules(c)[0], {'action': 'sniff'});
      final root = ok([mx('', 'set', {'log': {}})]);
      expect(root.keys, ['log']);
      expect(reason(mx('', 'set', 1)), 'the root can only be set to an object');
      expect(reason(mx('nope.x', 'set', 1)), 'no match');
    });
  });

  group('merge', () {
    test('несколько объектов (пример §4)', () {
      final c = ok([mx('outbounds[type=vless]', 'merge', {'tcp_fast_open': true})]);
      for (final o in outs(c)) {
        expect(o['tcp_fast_open'], o['type'] == 'vless' ? true : isNull);
      }
    });

    test('вглубь, список заменяет список, чужие ключи целы, новые в конце', () {
      final c = ok([
        mx('outbounds[tag=PR DE-1]', 'merge', {
          'tls': {
            'utls': {'fingerprint': 'chrome'},
            'alpn': ['h2'],
          },
          'zz': 1,
        }),
        mx('route.rules[0]', 'merge', {'inbound': ['only']}),
      ]);
      final o = outs(c)[2] as Map;
      expect(o['tls']['utls'], {'enabled': true, 'fingerprint': 'chrome'});
      expect(o['tls']['server_name'], 'example-11.com');
      expect(o['tls']['alpn'], ['h2']);
      expect(o.keys.last, 'zz');
      expect(rules(c)[0]['inbound'], ['only']);
    });

    test('корень (пример §4) и отказы', () {
      final c = ok([mx('', 'merge', {'services': []})]);
      expect(c['services'], isEmpty);
      expect(reason(mx('log.level', 'merge', {'a': 1})), 'not an object');
      expect(reason(mx('log', 'merge', 1)), 'merge needs an object value');
      expect(reason(mx('outbounds[type=nope]', 'merge', {})), 'no match');
    });
  });

  group('remove', () {
    test('узел целиком: элемент списка (пример §4) и ключ', () {
      final c = ok([
        mx('route.rules[rule_set=Ads]', 'remove', true),
        mx('log.timestamp', 'remove', true),
      ]);
      expect(rules(c).any((r) => r['rule_set'] == 'Ads'), isFalse);
      expect(rules(c), hasLength(15));
      expect((c['log'] as Map).containsKey('timestamp'), isFalse);
    });

    test('несколько элементов одного списка', () {
      final c = ok([mx('outbounds[type=vless]', 'remove', true)]);
      expect(outs(c).any((o) => o['type'] == 'vless'), isFalse);
      expect(outs(c), hasLength(21));
    });

    test('ключами с вложенным путём (пример §4), отсутствующий — не ошибка', () {
      final c = ok([
        mx('outbounds[tag=PR DE-1]', 'remove', ['tcp_fast_open', 'tls.utls', 'a.b.c']),
      ]);
      final tls = outs(c)[2]['tls'] as Map;
      expect(tls.containsKey('utls'), isFalse);
      expect(tls['enabled'], isTrue);
    });

    test('отказы', () {
      expect(reason(mx('', 'remove', true)), 'cannot remove the root');
      expect(reason(mx('log.level', 'remove', ['x'])), 'not an object');
      expect(reason(mx('log', 'remove', false)),
          'remove expects true or a list of keys');
      expect(reason(mx('nope', 'remove', true)), 'no match');
    });
  });

  test('порядок двух миксинов: второй видит результат первого', () {
    final c = ok([
      mx('inbounds', 'append', {'type': 'direct', 'tag': 'dns-in'}),
      mx('inbounds[tag=dns-in]', 'merge', {'listen_port': 5353}),
    ]);
    expect((c['inbounds'] as List).last,
        {'type': 'direct', 'tag': 'dns-in', 'listen_port': 5353});
    // Обратный порядок — второй не находит цель.
    final r = run([
      mx('inbounds[tag=dns-in]', 'merge', {'listen_port': 5353}, name: 'first'),
      mx('inbounds', 'append', {'type': 'direct', 'tag': 'dns-in'}),
    ]);
    expect(r.issues.single.name, 'first');
    expect(r.applied, 1);
  });

  test('отказ не меняет конфиг, остальные применяются', () {
    final r = run([
      mx('log.level', 'set', 'warn'),
      mx('nope', 'set', 1, name: 'bad'),
    ]);
    expect((r.config['log'] as Map)['level'], 'warn');
    expect(r.config.containsKey('nope'), isFalse);
    expect(r.issues.single.renderEn(), 'Mixin "bad": nope: no match');
  });

  test('дубль тега — issue миксина, который его внёс', () {
    final r = run([
      mx('inbounds', 'append', {'type': 'direct', 'tag': 'dns-in'}, name: 'ok'),
      mx('outbounds', 'append', {'type': 'direct', 'tag': 'vpn-1'}, name: 'dup'),
      mx('endpoints', 'append', {'type': 'wireguard', 'tag': 'direct-out'},
          name: 'cross'),
      mx('dns.servers', 'append', {'type': 'local', 'tag': 'my-doh'}, name: 'd'),
    ]);
    expect(r.issues.map((i) => i.renderEn()), [
      'Mixin "dup": duplicate tag "vpn-1" in outbounds',
      'Mixin "cross": duplicate tag "direct-out" in endpoints',
      'Mixin "d": duplicate tag "my-doh" in dns.servers',
    ]);
    expect(r.issues.every((i) => i.severity == Severity.fatal), isTrue);
  });

  test('синтаксис, неизвестный глагол, пустое имя', () {
    expect(reason(mx('a..b', 'set', 1)), startsWith('syntax: '));
    expect(reason(mx('log', 'patch', 1)), 'unknown action "patch"');
    final r = run([Mixin(target: 'nope', op: 'set', value: 1)]);
    expect(r.issues.single.renderEn(), 'Mixin "nope → set": nope: no match');
    expect(r.issues.single.mixinId, isNotEmpty);
  });

  test('типизированные списки собранного конфига не мешают вставке', () {
    final cfg = <String, dynamic>{
      'route': <String, dynamic>{
        'rules': <Map<String, dynamic>>[
          {'inbound': <String>['a']},
        ],
      },
    };
    final r = run([
      mx('route.rules', 'append', 'scalar'),
      mx('route.rules[0].inbound', 'append', {'obj': 1}),
    ], cfg);
    expect(r.issues, isEmpty);
    expect(rules(r.config).last, 'scalar');
  });
}
