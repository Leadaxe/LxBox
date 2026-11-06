import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:lxbox/models/mixin.dart';
import 'package:lxbox/services/mixins/mixin_apply.dart';
import 'package:lxbox/services/mixins/mixin_preview.dart';
import 'package:lxbox/services/mixins/mixin_suggest.dart';

/// §704 §5 — предпросмотр одного миксина и автодополнение Target.
void main() {
  late Map<String, dynamic> golden;
  setUpAll(() {
    golden = jsonDecode(File('test/fixtures/storage/golden/rich_v0.config.json')
        .readAsStringSync()) as Map<String, dynamic>;
  });

  Mixin mx(String target, String op, Object? value) =>
      Mixin(name: 'm', target: target, op: op, value: value);

  List<String> markers(MixinPreview p) =>
      [for (final r in p.fragment!.rows) r.marker];

  group('previewMixin', () {
    test('before: родитель цели, вставка помечена +', () {
      final p = previewMixin(
          golden,
          mx('route.rules[action=hijack-dns]', 'before',
              {'inbound': ['dns-in'], 'action': 'hijack-dns'}));
      expect(p.matches, 1);
      expect(p.issue, isNull);
      expect(p.fragment!.parentPath, 'route.rules');
      expect(markers(p).take(3), [' ', '+', ' ']);
      expect(p.fragment!.rows[1].text,
          '{"inbound":["dns-in"],"action":"hijack-dns"}');
      expect(p.fragment!.rows, hasLength(17));
      // Вход не тронут.
      expect(((golden['route'] as Map)['rules'] as List), hasLength(16));
    });

    test('after нескольких — вставка после последнего', () {
      final p = previewMixin(golden,
          mx('route.rules[action=resolve,strategy=prefer_ipv4]', 'after', {'a': 1}));
      expect(p.matches, 2);
      expect(markers(p).indexOf('+'), 5);
    });

    test('append: показан сам список', () {
      final p = previewMixin(golden, mx('inbounds', 'append', [{'tag': 'x'}]));
      expect(p.fragment!.parentPath, 'inbounds');
      expect(markers(p), [' ', ' ', '+']);
    });

    test('prepend значения-списка', () {
      final p =
          previewMixin(golden, mx('route.rules[0].inbound', 'prepend', ['a', 'b']));
      expect(p.fragment!.parentPath, 'route.rules[0].inbound');
      expect(markers(p), ['+', '+', ' ', ' ']);
    });

    test('merge нескольких: изменённые ~', () {
      final p = previewMixin(
          golden, mx('outbounds[type=vless]', 'merge', {'tcp_fast_open': true}));
      expect(p.matches, 4);
      expect(p.fragment!.parentPath, 'outbounds');
      final m = markers(p);
      expect(m.where((x) => x == '~'), hasLength(4));
      expect(m[2], '~');
    });

    test('remove элемента: строка -, значение удалённого', () {
      final p = previewMixin(golden, mx('route.rules[rule_set=Ads]', 'remove', true));
      expect(markers(p)[3], '-');
      expect((p.fragment!.rows[3].value as Map)['rule_set'], 'Ads');
      expect(p.fragment!.rows, hasLength(16));
    });

    test('remove ключами: объект-элемент списка ~', () {
      final p = previewMixin(
          golden, mx('outbounds[tag=PR DE-1]', 'remove', ['tls.utls']));
      expect(markers(p)[2], '~');
      expect(markers(p).where((x) => x != ' '), hasLength(1));
    });

    test('скаляр: одна строка было → стало', () {
      final p = previewMixin(golden, mx('log.level', 'set', 'warn'));
      expect(p.fragment!.parentPath, 'log.level');
      expect(p.fragment!.rows.single.text, '"debug" → "warn"');
      expect(p.fragment!.rows.single.marker, '~');
    });

    test('ключ объекта удалён / корень merge', () {
      final p = previewMixin(golden, mx('log.timestamp', 'remove', true));
      expect(p.fragment!.parentPath, 'log');
      expect(markers(p), [' ', '-']);
      final r = previewMixin(golden, mx('', 'merge', {'zz': 1}));
      expect(r.fragment!.parentPath, '');
      expect(markers(r).last, '+');
      expect(r.fragment!.rows.last.text, '"zz": 1');
    });

    test('отказы: синтаксис, нет совпадений, тип цели, дубль', () {
      final s = previewMixin(golden, mx('a..b', 'set', 1));
      expect(s.matches, 0);
      expect(s.issue!.reason, startsWith('syntax: '));
      expect(s.fragment, isNull);
      final n = previewMixin(golden, mx('nope', 'set', 1));
      expect(n.issue!.reason, 'no match');
      final t = previewMixin(golden,
          mx('route.rules[inbound=tun-in].inbound', 'append', 'z'));
      expect(t.matches, 4);
      expect(t.issue!.reason, 'needs a single list');
      final d = previewMixin(golden, mx('outbounds', 'append', {'tag': 'vpn-1'}));
      expect(d.issue!.reason, 'duplicate tag "vpn-1" in outbounds');
      expect(d.fragment, isNotNull);
      expect(jsonDecode(jsonEncode(d.toJson()))['issue']['message'],
          'Mixin "m": duplicate tag "vpn-1" in outbounds');
    });
  });

  test('mixinPreviewBase: миксины выше по списку, без самого', () {
    final a = mx('inbounds', 'append', {'tag': 'dns-in'});
    final b = mx('inbounds[tag=dns-in]', 'merge', {'listen_port': 1});
    final base = mixinPreviewBase(golden, [a, b], beforeId: b.id);
    expect((base['inbounds'] as List).last, {'tag': 'dns-in'});
    expect(previewMixin(base, b).matches, 1);
    expect((mixinPreviewBase(golden, [a, b])['inbounds'] as List).last,
        {'tag': 'dns-in', 'listen_port': 1});
  });

  group('suggestMixinPath', () {
    List<String> sug(String text, [int? cursor]) =>
        suggestMixinPath(text, cursor ?? text.length, golden);

    test('начало строки и после точки — ключи уровня', () {
      expect(sug(''), containsAll(['log', 'dns', 'inbounds', 'route']));
      expect(sug('ro'), ['route']);
      expect(sug('log.'), ['level', 'timestamp']);
      expect(sug('route.ru'), contains('rules'));
    });

    test('ключ набран целиком: [ у списка, . у объекта', () {
      expect(sug('route.rules'), containsAll(['rules', 'rules[']));
      expect(sug('log'), containsAll(['log', 'log.']));
    });

    test('после [ — поля элементов и индексы', () {
      final s = sug('outbounds[');
      expect(s, containsAll(['type=', 'tag=', '0]']));
      expect(s, contains('tls.'));
      expect(s.contains('transport='), isFalse);
      expect(sug('outbounds[ta'), ['tag=']);
      expect(sug('outbounds[tls.'), containsAll(['enabled=', 'utls.']));
    });

    test('после = — значения поля, уникальные, по порядку', () {
      final s = sug('outbounds[type=');
      expect(s.take(3), ['direct', 'block', 'vless']);
      expect(s.toSet().length, s.length);
      expect(sug('outbounds[tag=PR '), ['PR DE-1', 'PR NL-1', 'PR FI-1', 'PR ss-1']);
      expect(sug('route.rules[inbound='), ['tun-in', 'mixed-in']);
    });

    test('после , — поля без использованных, без индексов', () {
      final s = sug('route.rules[action=resolve,');
      expect(s.contains('action='), isFalse);
      expect(s, contains('strategy='));
      expect(s.any((x) => x.endsWith(']')), isFalse);
    });

    test('после ] — точка; неразборный префикс — пусто', () {
      expect(sug('outbounds[0]'), ['.']);
      expect(sug('outbounds[0].'), contains('tag'));
      expect(sug('a..'), isEmpty);
      expect(sug(r'$'), isEmpty);
      expect(sug('nope.'), isEmpty);
    });

    test('курсор в середине и подстановка', () {
      const text = 'outbounds[ty].tag';
      final at = suggestMixinPathAt(text, 12, golden);
      expect(at.items.first, 'type=');
      final (next, cur) = applyMixinPathSuggestion(text, 12, at, 'type=');
      expect(next, 'outbounds[type=].tag');
      expect(cur, 15);
      final v = suggestMixinPathAt('outbounds[tag= PR', 17, golden);
      final (n2, _) =
          applyMixinPathSuggestion('outbounds[tag= PR', 17, v, v.items.first);
      expect(n2, 'outbounds[tag= PR DE-1');
    });
  });
}
