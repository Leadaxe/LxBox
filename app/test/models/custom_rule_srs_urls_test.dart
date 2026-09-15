import 'package:flutter_test/flutter_test.dart';
import 'package:lxbox/models/codec/rule_record.dart';
import 'package:lxbox/models/custom_rule.dart';
import 'package:lxbox/services/storage_migration/legacy_form_v0.dart';

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

    test('запись: refs — список при одном и нескольких наборах', () {
      final one = ruleToRecord(CustomRuleSrs(name: 'a', srsUrl: 'https://x/a.srs'));
      expect(one['refs'], ['https://x/a.srs']);
      expect(one.containsKey('ref'), isFalse);

      final two = ruleToRecord(CustomRuleSrs(
        name: 'a',
        srsUrls: const ['https://x/a.srs', 'https://x/b.srs'],
      ));
      expect(two['refs'], ['https://x/a.srs', 'https://x/b.srs']);
    });

    test('чтение: refs главнее ref; без refs — ref', () {
      final a = ruleFromRecord({
        'kind': 'srs',
        'name': 'a',
        'ref': 'https://x/z.srs',
        'refs': ['https://x/a.srs', 'https://x/b.srs'],
      }).value!;
      expect(a.srsUrls, ['https://x/a.srs', 'https://x/b.srs']);
      final b = ruleFromRecord(
          {'kind': 'srs', 'name': 'b', 'ref': 'https://x/d.srs'}).value!;
      expect(b.srsUrls, ['https://x/d.srs']);
    });

    test('форма 2.23.2: srsUrls главнее srsUrl; без srsUrls — srsUrl', () {
      final a = readLegacyCustomRule({
        'kind': 'srs',
        'name': 'a',
        'srsUrl': 'https://x/a.srs',
        'srsUrls': ['https://x/a.srs', 'https://x/b.srs'],
      });
      expect(a.srsUrls, ['https://x/a.srs', 'https://x/b.srs']);
      final b = readLegacyCustomRule(
          {'kind': 'srs', 'name': 'b', 'srsUrl': 'https://x/d.srs'});
      expect(b.srsUrls, ['https://x/d.srs']);
    });

    test('round-trip записи сохраняет порядок', () {
      final r = CustomRuleSrs(
          name: 'a', srsUrls: const ['https://x/c.srs', 'https://x/a.srs']);
      expect(ruleFromRecord(ruleToRecord(r)).value!.srsUrls,
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
