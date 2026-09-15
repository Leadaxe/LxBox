import 'package:flutter_test/flutter_test.dart';
import 'package:lxbox/models/dns_ref.dart';
import 'package:lxbox/services/storage_migration/legacy_form_v0.dart';

/// §294 → §439 — чтение DNS-записей формы хранения 2.23.2 (`dns_options`)
/// замороженными читателями `legacy_form_v0.dart`: миграция формы и файл
/// правил `format: 1`. Своей сериализации у моделей больше нет, круг хранения
/// проверяет `record_codec_test.dart`; здесь — что форма 2.23.2 даёт ту же
/// модель, что давал `fromJson` 2.23.2, и терпимость чтения (null, не бросает).
void main() {
  group('readLegacyDnsServer — виды', () {
    test('inline с body + description', () {
      expect(
        readLegacyDnsServer({
          'enabled': true,
          'kind': 'inline',
          'tag': 'my_udp',
          'body': {'type': 'udp', 'server': '1.1.1.1'},
          'description': 'Custom',
        }),
        const DnsServerInline(
          enabled: true,
          tag: 'my_udp',
          body: {'type': 'udp', 'server': '1.1.1.1'},
          description: 'Custom',
        ),
      );
    });

    test('preset bare — presetId формой 2.23.2 не несётся', () {
      expect(
        readLegacyDnsServer(
            {'enabled': true, 'kind': 'preset', 'tag': 'yandex_udp'}),
        const DnsServerPreset(enabled: true, tag: 'yandex_udp'),
      );
    });

    test('template без varValues, выключенный', () {
      expect(
        readLegacyDnsServer(
            {'enabled': false, 'kind': 'template', 'tag': 'google_udp'}),
        const DnsServerTemplate(enabled: false, tag: 'google_udp'),
      );
    });

    test('template с varValues; null-значение — не задано', () {
      expect(
        readLegacyDnsServer({
          'enabled': true,
          'kind': 'template',
          'tag': 'doh',
          'varValues': {'url': 'https://x', 'detour': null},
        }),
        const DnsServerTemplate(
            enabled: true, tag: 'doh', varValues: {'url': 'https://x'}),
      );
    });

    test('без enabled — включён', () {
      expect(readLegacyDnsServer({'kind': 'preset', 'tag': 'x'})!.enabled,
          isTrue);
    });
  });

  group('readLegacyDnsServer — терпимость', () {
    test('legacy full-body (нет kind) → null, не бросает', () {
      expect(
          readLegacyDnsServer({'type': 'udp', 'tag': 'x', 'server': '1.1.1.1'}),
          isNull);
    });
    test('unknown kind → null', () {
      expect(readLegacyDnsServer({'kind': 'weird', 'tag': 'x'}), isNull);
    });
    test('inline без Map-body → null', () {
      expect(readLegacyDnsServer({'kind': 'inline', 'tag': 'x'}), isNull);
    });
    test('пустой/отсутствующий tag → null', () {
      expect(readLegacyDnsServer({'kind': 'preset', 'tag': ''}), isNull);
      expect(readLegacyDnsServer({'kind': 'preset'}), isNull);
    });
  });

  group('readLegacyDnsRule — виды', () {
    test('inline', () {
      expect(
        readLegacyDnsRule({
          'kind': 'inline',
          'name': 'block-ads',
          'rule': {'domain_suffix': '.ads.com', 'server': 'block'},
        }),
        const DnsRuleInline(
          name: 'block-ads',
          rule: {'domain_suffix': '.ads.com', 'server': 'block'},
        ),
      );
    });
    test('srs с body', () {
      expect(
        readLegacyDnsRule({
          'kind': 'srs',
          'name': 'geoip',
          'id': 'abc123',
          'body': {'url': 'https://srs'},
        }),
        const DnsRuleSrs(
            name: 'geoip', id: 'abc123', body: {'url': 'https://srs'}),
      );
    });
    test('srs без body', () {
      expect(readLegacyDnsRule({'kind': 'srs', 'name': 'geoip', 'id': 'abc123'}),
          const DnsRuleSrs(name: 'geoip', id: 'abc123'));
    });
    test('srs формы §033 (server/rule/srsUrl верхнего уровня)', () {
      expect(
        readLegacyDnsRule({
          'kind': 'srs',
          'name': 'cn',
          'id': 'ds_1',
          'srsUrl': 'https://e/cn.srs',
          'server': 'cf_doh',
          'rule': {
            'query_type': ['A'],
          },
          'enabled': false,
        }),
        const DnsRuleSrs(
          name: 'cn',
          id: 'ds_1',
          srsUrl: 'https://e/cn.srs',
          server: 'cf_doh',
          rule: {
            'query_type': ['A'],
          },
          enabled: false,
        ),
      );
    });
    test('preset и template с enabled: true', () {
      expect(readLegacyDnsRule({'kind': 'preset', 'presetId': 'p1', 'enabled': true}),
          const DnsRulePreset(presetId: 'p1', enabled: true));
      expect(
          readLegacyDnsRule(
              {'kind': 'template', 'name': 'ru-direct', 'enabled': true}),
          const DnsRuleTemplate(name: 'ru-direct', enabled: true));
    });
  });

  // §439 A1 — отсутствие ключа `enabled`: inline/srs — включено,
  // template/preset — выключено (как читала сборка 2.23.2).
  group('readLegacyDnsRule — enabled без ключа', () {
    test('inline и srs → включено', () {
      expect(
          readLegacyDnsRule(
                  {'kind': 'inline', 'name': 'x', 'rule': {'server': 's'}})!
              .enabled,
          isTrue);
      expect(readLegacyDnsRule({'kind': 'srs', 'name': 'x', 'id': 'i'})!.enabled,
          isTrue);
    });
    test('template и preset → выключено', () {
      expect(readLegacyDnsRule({'kind': 'template', 'name': 'x'})!.enabled,
          isFalse);
      expect(readLegacyDnsRule({'kind': 'preset', 'presetId': 'p'})!.enabled,
          isFalse);
    });
    test('inline с enabled: false → выключено', () {
      expect(
          readLegacyDnsRule({
            'kind': 'inline',
            'name': 'x',
            'rule': {'server': 's'},
            'enabled': false,
          })!
              .enabled,
          isFalse);
    });
  });

  group('readLegacyDnsRule — терпимость', () {
    test('legacy kind user/rule → null', () {
      expect(readLegacyDnsRule({'kind': 'user', 'name': 'x'}), isNull);
      expect(readLegacyDnsRule({'kind': 'rule', 'name': 'x'}), isNull);
    });
    test('inline без rule-Map → null', () {
      expect(readLegacyDnsRule({'kind': 'inline', 'name': 'x'}), isNull);
    });
    test('srs без id → null', () {
      expect(readLegacyDnsRule({'kind': 'srs', 'name': 'x'}), isNull);
    });
    test('preset без presetId → null', () {
      expect(readLegacyDnsRule({'kind': 'preset'}), isNull);
    });
  });
}
