import 'package:flutter_test/flutter_test.dart';
import 'package:lxbox/models/dns_ref.dart';

/// §294 — DnsServerRef / DnsRuleRef.
///
/// Главный инвариант: **byte-compat round-trip** `fromJson → toJson == input`
/// для всех kind'ов (§221 backup — форма на диске не мигрируется). Плюс
/// толерантность чтения (legacy/unknown → null, не бросает) и строгость
/// write-пути (`fromJsonStrict` бросает).
void main() {
  group('§294 DnsServerRef round-trip (byte-compat)', () {
    test('inline с body + description', () {
      final j = {
        'enabled': true,
        'kind': 'inline',
        'tag': 'my_udp',
        'body': {'type': 'udp', 'server': '1.1.1.1'},
        'description': 'Custom',
      };
      expect(DnsServerRef.fromJson(j)!.toJson(), j);
    });

    test('preset bare (как auto-discover резолвера)', () {
      final j = {'enabled': true, 'kind': 'preset', 'tag': 'yandex_udp'};
      expect(DnsServerRef.fromJson(j)!.toJson(), j);
    });

    test('template без varValues (как resolver output)', () {
      final j = {'enabled': false, 'kind': 'template', 'tag': 'google_udp'};
      expect(DnsServerRef.fromJson(j)!.toJson(), j);
    });

    test('template с varValues', () {
      final j = {
        'enabled': true,
        'kind': 'template',
        'tag': 'doh',
        'varValues': {'url': 'https://x'},
      };
      expect(DnsServerRef.fromJson(j)!.toJson(), j);
    });

    test('пустой varValues НЕ эмитится (симметрия с резолвером)', () {
      final parsed = DnsServerRef.fromJson(
          {'enabled': true, 'kind': 'template', 'tag': 't', 'varValues': {}});
      expect(parsed!.toJson().containsKey('varValues'), isFalse);
    });
  });

  group('§294 DnsServerRef read tolerance', () {
    test('legacy full-body (нет kind) → null, не бросает', () {
      expect(
          DnsServerRef.fromJson(
              {'type': 'udp', 'tag': 'x', 'server': '1.1.1.1'}),
          isNull);
    });
    test('unknown kind → null', () {
      expect(DnsServerRef.fromJson({'kind': 'weird', 'tag': 'x'}), isNull);
    });
    test('inline без Map-body → null (malformed, как резолвер)', () {
      expect(DnsServerRef.fromJson({'kind': 'inline', 'tag': 'x'}), isNull);
    });
    test('пустой/отсутствующий tag → null', () {
      expect(DnsServerRef.fromJson({'kind': 'preset', 'tag': ''}), isNull);
      expect(DnsServerRef.fromJson({'kind': 'preset'}), isNull);
    });
  });

  group('§294 DnsServerRef.fromJsonStrict (write-путь)', () {
    test('нет kind → бросает', () {
      expect(() => DnsServerRef.fromJsonStrict({'tag': 'x'}),
          throwsA(isA<DnsRefFormatException>()));
    });
    test('нет tag → бросает', () {
      expect(() => DnsServerRef.fromJsonStrict({'kind': 'preset'}),
          throwsA(isA<DnsRefFormatException>()));
    });
    test('inline без body → бросает', () {
      expect(() => DnsServerRef.fromJsonStrict({'kind': 'inline', 'tag': 'x'}),
          throwsA(isA<DnsRefFormatException>()));
    });
    test('unknown kind → бросает', () {
      expect(
          () => DnsServerRef.fromJsonStrict({'kind': 'weird', 'tag': 'x'}),
          throwsA(isA<DnsRefFormatException>()));
    });
    test('валидный preset → ок', () {
      expect(DnsServerRef.fromJsonStrict({'kind': 'preset', 'tag': 'x'}).kind,
          'preset');
    });
  });

  group('§294 DnsRuleRef round-trip (byte-compat)', () {
    test('inline', () {
      final j = {
        'kind': 'inline',
        'name': 'block-ads',
        'rule': {'domain_suffix': '.ads.com', 'server': 'block'},
      };
      expect(DnsRuleRef.fromJson(j)!.toJson(), j);
    });
    test('srs с body', () {
      final j = {
        'kind': 'srs',
        'name': 'geoip',
        'id': 'abc123',
        'body': {'url': 'https://srs'},
      };
      expect(DnsRuleRef.fromJson(j)!.toJson(), j);
    });
    test('srs без body', () {
      final j = {'kind': 'srs', 'name': 'geoip', 'id': 'abc123'};
      expect(DnsRuleRef.fromJson(j)!.toJson(), j);
    });
    test('preset (anchor + мёртвый enabled сохранён)', () {
      final j = {'kind': 'preset', 'presetId': 'p1', 'enabled': true};
      expect(DnsRuleRef.fromJson(j)!.toJson(), j);
    });
    test('template', () {
      final j = {'kind': 'template', 'name': 'ru-direct'};
      expect(DnsRuleRef.fromJson(j)!.toJson(), j);
    });
  });

  group('§294 DnsRuleRef read tolerance', () {
    test('legacy kind user/rule → null', () {
      expect(DnsRuleRef.fromJson({'kind': 'user', 'name': 'x'}), isNull);
      expect(DnsRuleRef.fromJson({'kind': 'rule', 'name': 'x'}), isNull);
    });
    test('inline без rule-Map → null', () {
      expect(DnsRuleRef.fromJson({'kind': 'inline', 'name': 'x'}), isNull);
    });
    test('srs без id → null', () {
      expect(DnsRuleRef.fromJson({'kind': 'srs', 'name': 'x'}), isNull);
    });
    test('preset без presetId → null', () {
      expect(DnsRuleRef.fromJson({'kind': 'preset'}), isNull);
    });
  });

  group('§294 DnsRuleRef.fromJsonStrict (write-путь)', () {
    test('нет kind → бросает', () {
      expect(() => DnsRuleRef.fromJsonStrict({'name': 'x'}),
          throwsA(isA<DnsRefFormatException>()));
    });
    test('inline без rule → бросает', () {
      expect(() => DnsRuleRef.fromJsonStrict({'kind': 'inline', 'name': 'x'}),
          throwsA(isA<DnsRefFormatException>()));
    });
    test('валидный template → ок', () {
      expect(
          DnsRuleRef.fromJsonStrict({'kind': 'template', 'name': 'x'}).kind,
          'template');
    });
  });
}
