import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:lxbox/services/mixins/mixin_path.dart';

/// §704 §3 — грамматика пути и разрешение на golden-конфиге.
void main() {
  late Map<String, dynamic> golden;
  setUpAll(() {
    golden = jsonDecode(File('test/fixtures/storage/golden/rich_v0.config.json')
        .readAsStringSync()) as Map<String, dynamic>;
  });

  MixinPath parse(String s) {
    final p = parseMixinPath(s);
    expect(p, isA<MixinPath>(), reason: '$s → $p');
    return p as MixinPath;
  }

  MixinPathError fail(String s) {
    final p = parseMixinPath(s);
    expect(p, isA<MixinPathError>(), reason: s);
    return p as MixinPathError;
  }

  List<String> paths(String s) =>
      [for (final m in parse(s).resolve(golden)) m.path];

  group('грамматика', () {
    test('пустой путь — корень', () {
      final p = parse('');
      expect(p.isRoot, isTrue);
      final m = p.resolve(golden).single;
      expect(m.isRoot, isTrue);
      expect(identical(m.value, golden), isTrue);
    });

    test('сегменты, индекс, условия', () {
      final p = parse('route.rules[action=resolve,strategy=prefer_ipv4].x');
      expect(p.segments.map((s) => s.name), ['route', 'rules', 'x']);
      expect(p.segments[1].conditions!.map((c) => '$c'),
          ['action=resolve', 'strategy=prefer_ipv4']);
      expect(parse('outbounds[3]').segments.single.index, 3);
      expect(parse('a[tls.enabled=true]').segments.single.conditions!.single
          .field, ['tls', 'enabled']);
    });

    test('пробелы внутри значения и вокруг', () {
      final c = parse('outbounds[ tag = S2 Fastest ]').segments.single
          .conditions!.single;
      expect(c.fieldText, 'tag');
      expect(c.value, 'S2 Fastest');
    });

    test('ошибки с offset', () {
      expect(fail(r'$.a').offset, 0);
      expect(fail('a.').offset, 2);
      expect(fail('.a').offset, 0);
      expect(fail('a..b').offset, 2);
      expect(fail('a[').offset, 2);
      expect(fail('a[]').offset, 2);
      expect(fail('a[tag]').offset, 5);
      expect(fail('a[=x]').offset, 2);
      expect(fail('a[tag=x').offset, 7);
      expect(fail('a[0]b').offset, 4);
      expect(fail('a[x=1]]').offset, 6);
    });
  });

  group('разрешение на golden rich_v0', () {
    test('примеры §4', () {
      expect(paths('inbounds'), ['inbounds']);
      expect(paths('route.rules[action=hijack-dns]'), ['route.rules[1]']);
      expect(paths('route.rules[action=resolve,strategy=prefer_ipv4]'),
          ['route.rules[2]', 'route.rules[4]']);
      expect(paths('route.rules[action=resolve,inbound=mixed-in]'),
          ['route.rules[2]']);
      expect(paths('outbounds[type=vless]'), [
        'outbounds[2]',
        'outbounds[6]',
        'outbounds[10]',
        'outbounds[14]',
      ]);
      expect(paths('route.rules[rule_set=Ads]'), ['route.rules[3]']);
      expect(paths('log.level'), ['log.level']);
    });

    test('пробелы в теге', () {
      expect(paths('outbounds[tag=PR DE-1]'), ['outbounds[2]']);
      expect(paths('outbounds[tag=S2 Fastest]'), ['outbounds[9]']);
    });

    test('регистр учитывается', () {
      expect(paths('outbounds[tag=pr de-1]'), isEmpty);
    });

    test('вложенное поле условия', () {
      final p = paths('outbounds[tls.utls.enabled=true]');
      expect(p, contains('outbounds[2]'));
      for (final path in p) {
        expect(path, startsWith('outbounds['));
      }
    });

    test('список скаляров — «содержит»', () {
      expect(paths('route.rules[rule_set=Geo sets-2]'), ['route.rules[7]']);
      expect(paths('route.rules[inbound=mixed-in]'),
          ['route.rules[0]', 'route.rules[2]']);
    });

    test('число и bool', () {
      expect(paths('route.rules[port=443]'), ['route.rules[7]']);
      expect(paths('route.rules[ip_is_private=true]'),
          ['route.rules[4]', 'route.rules[5]']);
      expect(paths('route.rules[ip_is_private=1]'), isEmpty);
    });

    test('индекс скобкой и через точку', () {
      expect(paths('outbounds[0].tag'), ['outbounds[0].tag']);
      expect(paths('outbounds.0.tag'), ['outbounds[0].tag']);
      expect(parse('outbounds.0.tag').resolve(golden).single.value,
          'direct-out');
      expect(paths('outbounds[999]'), isEmpty);
    });

    test('путь вглубь после условия', () {
      final ms = parse('outbounds[type=vless].tag').resolve(golden);
      expect(ms.map((m) => m.value),
          ['PR DE-1', 'S2 JP-1', 'VLESS Reality', 'EU de-1']);
      expect(ms.first.parentPath, 'outbounds[2]');
    });

    test('нет узла / не тот тип — пусто', () {
      expect(paths('nope'), isEmpty);
      expect(paths('log.level.x'), isEmpty);
      expect(paths('log[0]'), isEmpty);
      expect(paths('route.rules[action=nope]'), isEmpty);
    });

    test('место узла: родитель и ключ/индекс', () {
      final m = parse('route.rules[action=hijack-dns]').resolve(golden).single;
      expect(m.isListElement, isTrue);
      expect(m.index, 1);
      expect(m.parentPath, 'route.rules');
      final k = parse('log.level').resolve(golden).single;
      expect(k.key, 'level');
      expect(k.parentPath, 'log');
      expect(k.isListElement, isFalse);
    });
  });
}
