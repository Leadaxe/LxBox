import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:lxbox/models/dns_ref.dart';
import 'package:lxbox/services/dns/dns_backup.dart';
import 'package:lxbox/services/lx_backup.dart';

/// §439 §6.5 п. 12 — слияние DNS-правил секции `dns` (BACKUP.md §9 п. 5):
/// файл — сериализация состояния, и одинаковые пользовательские правила в нём
/// — разные правила состояния. Дубль ищется только среди правил, стоявших у
/// приёмника ДО импорта (ключ — вид и тело); ссылки (`preset`, `template`)
/// дублем не заводятся.

const _corp = {
  'domain_suffix': ['.corp'],
  'server': 'my-doh',
};
const _lan = {
  'domain_suffix': ['.lan'],
  'server': 'my-doh',
};

DnsBackupApply _apply(
  List<DnsRuleRef> incoming, {
  List<DnsRuleRef> local = const [],
  List<DnsServerRef> incomingServers = const [],
  List<DnsServerRef> localServers = const [],
}) =>
    applyDnsBackup(
      incoming: LxDns(servers: incomingServers, rules: incoming),
      servers: localServers,
      rules: local,
      dnsFinal: '',
      strategy: '',
    );

String _file(List<Map<String, dynamic>> rules) => jsonEncode({
      'lx_backup': 2,
      'exported_by': {'app': 'lxbox', 'version': 'test'},
      'exported_at': '2026-09-15T00:00:00Z',
      'dns': {
        'servers': [
          {
            'kind': 'user',
            'tag': 'my-doh',
            'enabled': true,
            'body': {'type': 'https', 'server': 'example-1.com'},
          },
        ],
        'rules': rules,
      },
    });

void main() {
  group('одинаковые правила внутри файла', () {
    test('ввозятся все, в порядке файла', () {
      const rule = DnsRuleInline(name: 'corp', rule: _corp);
      final got = _apply(const [rule, rule, DnsRuleInline(name: 'lan', rule: _lan)]);
      expect(got.rules, const [rule, rule, DnsRuleInline(name: 'lan', rule: _lan)]);
      expect(got.applied, 3);
    });

    test('безымянные получают имена из тела с уникализацией', () {
      final got = _apply(const [
        DnsRuleInline(name: '', rule: _corp),
        DnsRuleInline(name: '', rule: _corp),
      ]);
      expect([for (final r in got.rules) (r as DnsRuleInline).name],
          ['.corp', '.corp-2']);
      expect([for (final r in got.rules) (r as DnsRuleInline).rule], [_corp, _corp]);
    });

    test('через файл 1.0: два одинаковых правила — два правила состояния', () {
      final file = parseLxBackup(_file([
        for (var i = 0; i < 2; i++)
          {'kind': 'user', 'name': 'corp', 'enabled': true, 'body': _corp},
      ]));
      expect(file.warnings, isEmpty);
      final got = _apply(file.dns!.rules, incomingServers: file.dns!.servers);
      expect(got.rules, hasLength(2));
      expect(got.servers.single.tag, 'my-doh');
    });

    test('ссылки preset/template внутри файла дублем не заводятся', () {
      final got = _apply(const [
        DnsRulePreset(presetId: 'ru-direct', enabled: true),
        DnsRulePreset(presetId: 'ru-direct', enabled: true),
        DnsRuleTemplate(name: 'Default', enabled: true),
        DnsRuleTemplate(name: 'Default', enabled: true),
      ]);
      expect(got.rules, const [
        DnsRulePreset(presetId: 'ru-direct', enabled: true),
        DnsRuleTemplate(name: 'Default', enabled: true),
      ]);
    });
  });

  group('дубль против приёмника', () {
    test('правило с тем же телом, что у приёмника, не ввозится — все копии', () {
      const local = DnsRuleInline(name: 'corp', rule: _corp);
      final got = _apply(
        const [local, local, DnsRuleInline(name: 'lan', rule: _lan)],
        local: const [local],
      );
      expect(got.rules, const [local, DnsRuleInline(name: 'lan', rule: _lan)]);
      expect(got.applied, 1);
    });

    test('ключ — тело, а не имя: то же тело под другим именем — дубль', () {
      final got = _apply(
        const [DnsRuleInline(name: 'renamed', rule: _corp)],
        local: const [DnsRuleInline(name: 'corp', rule: _corp)],
      );
      expect(got.rules, const [DnsRuleInline(name: 'corp', rule: _corp)]);
      expect(got.applied, 0);
    });

    test('порядок ключей тела не делает правило новым', () {
      final got = _apply(
        const [
          DnsRuleInline(name: 'corp', rule: {
            'server': 'my-doh',
            'domain_suffix': ['.corp'],
          }),
        ],
        local: const [DnsRuleInline(name: 'corp', rule: _corp)],
      );
      expect(got.rules, hasLength(1));
    });

    test('ссылка, которая у приёмника есть, не ввозится', () {
      final got = _apply(
        const [DnsRulePreset(presetId: 'ru-direct', enabled: true)],
        local: const [DnsRulePreset(presetId: 'ru-direct')],
      );
      expect(got.rules, const [DnsRulePreset(presetId: 'ru-direct')],
          reason: 'своё сильнее, тумблер приёмника не перетирается');
    });

    test('повторный импорт того же файла ничего не добавляет', () {
      const rules = [
        DnsRuleInline(name: 'corp', rule: _corp),
        DnsRuleInline(name: 'corp', rule: _corp),
      ];
      final first = _apply(rules);
      final again = _apply(rules, local: first.rules);
      expect(again.rules, first.rules);
      expect(again.applied, 0);
    });
  });

  test('серверы: тег — имя outbound, второй с тем же тегом в файле не ввозится',
      () {
    final got = _apply(
      const [],
      incomingServers: const [
        DnsServerInline(enabled: true, tag: 'my-doh', body: {'server': '1.1.1.1'}),
        DnsServerInline(enabled: true, tag: 'my-doh', body: {'server': '9.9.9.9'}),
      ],
    );
    expect(got.servers, const [
      DnsServerInline(enabled: true, tag: 'my-doh', body: {'server': '1.1.1.1'}),
    ]);
  });
}
