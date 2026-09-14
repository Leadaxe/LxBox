import 'package:flutter_test/flutter_test.dart';
import 'package:lxbox/models/custom_rule.dart';

/// ## 12 контракта (D-100) — несколько `.srs`-наборов в одном правиле.
void main() {
  group('CustomRuleSrs.srsUrls', () {
    test('одиночный srsUrl → список из одного, srsUrl = первый', () {
      final r = CustomRuleSrs(name: 'a', srsUrl: ' https://x/a.srs ');
      expect(r.srsUrls, ['https://x/a.srs']);
      expect(r.srsUrl, 'https://x/a.srs');
      expect(r.cacheIds, [r.id]);
    });

    test('список главнее одиночного; trim, пустые и повторы отброшены', () {
      final r = CustomRuleSrs(
        name: 'a',
        srsUrl: 'https://x/ignored.srs',
        srsUrls: const ['https://x/a.srs', ' ', 'https://x/b.srs', 'https://x/a.srs'],
      );
      expect(r.srsUrls, ['https://x/a.srs', 'https://x/b.srs']);
      expect(r.srsUrl, 'https://x/a.srs');
      expect(r.cacheIds, [r.id, '${r.id}~1']);
    });

    test('toJson: srsUrl всегда, srsUrls только при двух и более', () {
      final one = CustomRuleSrs(name: 'a', srsUrl: 'https://x/a.srs').toJson();
      expect(one['srsUrl'], 'https://x/a.srs');
      expect(one.containsKey('srsUrls'), isFalse,
          reason: 'старая версия приложения читает srsUrl — без дубля ключа');

      final two = CustomRuleSrs(
        name: 'a',
        srsUrls: const ['https://x/a.srs', 'https://x/b.srs'],
      ).toJson();
      expect(two['srsUrl'], 'https://x/a.srs');
      expect(two['srsUrls'], ['https://x/a.srs', 'https://x/b.srs']);
    });

    test('fromJson: srsUrls главнее srsUrl; без srsUrls — srsUrl', () {
      final a = CustomRule.fromJson({
        'kind': 'srs',
        'name': 'a',
        'srsUrl': 'https://x/a.srs',
        'srsUrls': ['https://x/a.srs', 'https://x/b.srs'],
      });
      expect(a.srsUrls, ['https://x/a.srs', 'https://x/b.srs']);
      final b = CustomRule.fromJson({'kind': 'srs', 'name': 'b', 'srsUrl': 'https://x/d.srs'});
      expect(b.srsUrls, ['https://x/d.srs']);
    });

    test('roundtrip toJson/fromJson сохраняет порядок', () {
      final r = CustomRuleSrs(
          name: 'a', srsUrls: const ['https://x/c.srs', 'https://x/a.srs']);
      expect(CustomRule.fromJson(r.toJson()).srsUrls,
          ['https://x/c.srs', 'https://x/a.srs']);
    });

    test('copyWith: srsUrls заменяет список, одиночный srsUrl — тоже', () {
      final r = CustomRuleSrs(
          name: 'a', srsUrls: const ['https://x/a.srs', 'https://x/b.srs']);
      expect(r.copyWith(srsUrl: 'https://x/z.srs').srsUrls, ['https://x/z.srs']);
      expect(r.copyWith(srsUrls: const ['https://x/q.srs']).srsUrls,
          ['https://x/q.srs']);
      expect(r.copyWith(name: 'b').srsUrls, r.srsUrls);
    });

    test('parseSrsUrlsText: строки/пробелы, пустые и повторы', () {
      expect(parseSrsUrlsText('https://x/a.srs\n\n https://x/b.srs \nhttps://x/a.srs'),
          ['https://x/a.srs', 'https://x/b.srs']);
      expect(parseSrsUrlsText('   '), isEmpty);
    });

    test('summary: один хост; несколько — хост первого и (+N)', () {
      expect(CustomRuleSrs(name: 'a', srsUrl: 'https://x.io/a.srs').summary(),
          'SRS: x.io');
      expect(
          CustomRuleSrs(name: 'a', srsUrls: const [
            'https://x.io/a.srs',
            'https://y.io/b.srs',
            'https://z.io/c.srs'
          ]).summary(),
          'SRS: x.io (+2)');
    });

    test('прочие kind → srsUrls пуст', () {
      expect(CustomRuleInline(name: 'i', domains: const ['a']).srsUrls, isEmpty);
    });
  });
}
