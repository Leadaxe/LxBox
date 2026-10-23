import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:lxbox/models/custom_rule.dart';
import 'package:lxbox/models/dns_ref.dart';
import 'package:lxbox/models/parser_config.dart' show SelectableRule;
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
  String exportedByApp = '',
}) =>
    applyDnsBackup(
      incoming: LxDns(servers: incomingServers, rules: incoming),
      servers: localServers,
      rules: local,
      dnsFinal: '',
      strategy: '',
      exportedByApp: exportedByApp,
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
        DnsRulePreset(presetId: 'ru-direct'),
        DnsRulePreset(presetId: 'ru-direct'),
        DnsRuleTemplate(name: 'Default', enabled: true),
        DnsRuleTemplate(name: 'Default', enabled: true),
      ]);
      expect(got.rules, const [
        DnsRulePreset(presetId: 'ru-direct'),
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
        const [DnsRulePreset(presetId: 'ru-direct')],
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

  group('§680 — шаблонные серверы: файл — полный список', () {
    const allTags = [
      'local_dns_resolver',
      'google_udp',
      'google_dot',
      'google_doh',
      'cloudflare_udp',
      'cloudflare_dot',
      'safe_dns_dot',
      'opendns_udp',
      'opendns_doh',
      'quad9_doh',
      'yandex_dot',
      'dns_shield',
    ];
    List<DnsServerRef> full({Set<String> without = const {}}) => [
          for (final t in allTags)
            if (!without.contains(t))
              DnsServerTemplate(enabled: t != 'safe_dns_dot', tag: t),
        ];
    const mine = DnsServerInline(
        enabled: true, tag: 'my-doh', body: {'type': 'https', 'server': 'x'});
    const preset = DnsServerPreset(
        enabled: true, tag: 'ru-direct:yandex_udp', presetId: 'ru-direct');

    test('шаблонная запись вне файла снимается; inline/preset — слияние', () {
      final got = _apply(
        const [],
        incomingServers: full(without: {'opendns_udp'}),
        localServers: [...full(), mine, preset],
        exportedByApp: kLxAppLxBox,
      );
      final tags = got.servers.map((s) => s.tag).toList();
      expect(tags, isNot(contains('opendns_udp')));
      expect(tags, containsAll(['my-doh', 'ru-direct:yandex_udp']));
      expect(tags.length, allTags.length - 1 + 2);
      expect(got.applied, 1);
    });

    test('старый бэкап со всеми 12 серверами ничего не теряет', () {
      final got = _apply(
        const [],
        incomingServers: full(),
        localServers: [...full(), mine],
        exportedByApp: kLxAppLxBox,
      );
      expect(got.servers, [...full(), mine]);
      expect(got.applied, 0);
    });

    test('удалённый у приёмника сервер из файла возвращается', () {
      final got = _apply(
        const [],
        incomingServers: full(),
        localServers: full(without: {'opendns_udp'}),
        exportedByApp: kLxAppLxBox,
      );
      expect(got.servers.map((s) => s.tag), contains('opendns_udp'));
      expect(got.servers.length, allTags.length);
    });

    test('файл без серверов список не трогает', () {
      final got = _apply(
        const [DnsRuleInline(name: 'corp', rule: _corp)],
        localServers: full(),
        exportedByApp: kLxAppLxBox,
      );
      expect(got.servers, full());
    });

    // Контракт 1.1.134 (BACKUP.md §9 п. 5, D-138): норма полного списка —
    // только у файла своего приложения. Каталог лаунчера без `opendns_doh` и
    // `yandex_dot`: его файл не может их назвать, и снимать их нельзя.
    test('файл лаунчера с неполным списком — шаблонные записи остаются', () {
      final got = _apply(
        const [],
        incomingServers: full(without: {'opendns_doh', 'yandex_dot'}),
        localServers: [...full(), mine],
        exportedByApp: kLxAppLauncher,
      );
      expect(got.servers, [...full(), mine]);
      expect(got.applied, 0);
    });

    test('файл без exported_by — слияние, шаблонные записи остаются', () {
      final got = _apply(
        const [],
        incomingServers: full(without: {'opendns_udp'}),
        localServers: [...full(), mine],
      );
      expect(got.servers, [...full(), mine]);
      expect(got.applied, 0);
    });
  });

  // ════════════════════════════════════════════════════════════════════════
  // §681 — каталог источника в файле (контракт 1.1.135, D-139, BACKUP.md §9
  // п. 5): снятие по трём условиям, удерживающие ссылки, переходная ветка,
  // висячие final/default resolver, пустая группа.
  // ════════════════════════════════════════════════════════════════════════
  group('§681 каталог источника', () {
    const allTags = [
      'local_dns_resolver',
      'google_udp',
      'google_doh',
      'cloudflare_udp',
      'opendns_udp',
      'opendns_doh',
      'quad9_doh',
      'yandex_dot',
    ];
    List<DnsServerRef> full({Set<String> without = const {}}) => [
          for (final t in allTags)
            if (!without.contains(t)) DnsServerTemplate(enabled: true, tag: t),
        ];
    Map<String, dynamic> wrapper(String tag, {Map<String, dynamic>? extra,
            bool required = false}) =>
        {
          'description': tag,
          'enabled': true,
          if (required) 'required': true,
          'server': {'type': 'udp', 'tag': tag, 'server': '1.1.1.1', ...?extra},
        };
    final templateServers = [for (final t in allTags) wrapper(t)];

    DnsBackupApply run({
      required List<DnsServerRef> fileServers,
      required List<DnsServerRef> local,
      List<String>? catalog,
      String exportedBy = kLxAppLxBox,
      String fileFinal = '',
      String localFinal = '',
      List<DnsRuleRef> localRules = const [],
      List<CustomRule> routing = const [],
      List<SelectableRule> presets = const [],
      List<Map<String, dynamic>>? template,
      List<LxBackupWarning>? warnings,
    }) =>
        applyDnsBackup(
          incoming: LxDns(
              servers: fileServers,
              finalServer: fileFinal,
              templateCatalog: catalog),
          servers: local,
          rules: localRules,
          dnsFinal: localFinal,
          strategy: '',
          exportedByApp: exportedBy,
          warnings: warnings,
          scene: DnsImportScene(
            templateServers: template ?? templateServers,
            routingRules: routing,
            presets: presets,
            finalDefault: 'google_udp',
          ),
        );

    List<String> codes(List<LxBackupWarning> w, String code) =>
        [for (final x in w) if (x.code == code) x.detail];

    test('тег из каталога, удалённый источником, снимается', () {
      final w = <LxBackupWarning>[];
      final got = run(
        fileServers: full(without: {'opendns_udp'}),
        local: full(),
        catalog: allTags,
        warnings: w,
      );
      expect(got.servers.map((s) => s.tag), isNot(contains('opendns_udp')));
      expect(got.servers.length, allTags.length - 1);
      expect(codes(w, kWarnDnsEntryKept), isEmpty);
    });

    test('тег вне каталога файла не трогается (другой каталог)', () {
      final launcherCatalog = [
        for (final t in allTags)
          if (t != 'opendns_doh' && t != 'yandex_dot') t,
      ];
      final got = run(
        fileServers: full(without: {'opendns_doh', 'yandex_dot', 'quad9_doh'}),
        local: full(),
        catalog: launcherCatalog,
        exportedBy: kLxAppLauncher,
      );
      final tags = got.servers.map((s) => s.tag).toList();
      expect(tags, containsAll(['opendns_doh', 'yandex_dot']));
      expect(tags, isNot(contains('quad9_doh')));
    });

    test('удерживаемые записи остаются с kept, used_by — первая по словарю',
        () {
      const group = DnsServerInline(
          enabled: true,
          tag: 'my-group',
          body: {
            'type': 'group',
            'servers': ['google_doh', 'cloudflare_udp'],
          });
      const resolverUser = DnsServerInline(
          enabled: true,
          tag: 'my-doh',
          body: {
            'type': 'https',
            'server': 'doh.example',
            'domain_resolver': 'opendns_udp',
          });
      final w = <LxBackupWarning>[];
      final got = run(
        fileServers: full(without: {
          'google_doh',
          'cloudflare_udp',
          'opendns_udp',
          'opendns_doh',
          'quad9_doh',
          'local_dns_resolver',
          'yandex_dot',
        }),
        local: [...full(), group, resolverUser],
        catalog: allTags,
        // final приёмника на cloudflare_udp: и группа, и final — пишется final
        localFinal: 'cloudflare_udp',
        localRules: const [
          DnsRuleInline(name: 'corp', rule: {
            'domain_suffix': ['.corp'],
            'server': 'opendns_doh',
          }),
        ],
        routing: [
          CustomRuleInline(
              name: 'Streaming',
              dns: const RuleDns(enabled: true, serverTag: 'quad9_doh')),
        ],
        template: [
          for (final t in allTags)
            wrapper(t, required: t == 'local_dns_resolver'),
        ],
        warnings: w,
      );
      final tags = got.servers.map((s) => s.tag).toSet();
      expect(tags, containsAll([
        'google_doh',
        'cloudflare_udp',
        'opendns_udp',
        'opendns_doh',
        'quad9_doh',
        'local_dns_resolver',
      ]));
      expect(tags, isNot(contains('yandex_dot')));
      expect(
          codes(w, kWarnDnsEntryKept).toSet(),
          {
            'template:google_doh used_by=group:my-group',
            'template:cloudflare_udp used_by=final',
            'template:opendns_udp used_by=server:my-doh',
            'template:opendns_doh used_by=dns_rule:opendns_doh',
            'template:quad9_doh used_by=rule:Streaming',
            'template:local_dns_resolver used_by=required',
          });
    });

    test('ссылка только от снимаемого сервера не держит (второй круг)', () {
      final template = [
        for (final t in allTags)
          wrapper(t,
              extra: t == 'quad9_doh' ? {'domain_resolver': 'opendns_udp'} : null),
      ];
      final w = <LxBackupWarning>[];
      final got = run(
        fileServers: full(without: {'quad9_doh', 'opendns_udp'}),
        local: full(),
        catalog: allTags,
        template: template,
        warnings: w,
      );
      final tags = got.servers.map((s) => s.tag);
      expect(tags, isNot(contains('quad9_doh')));
      expect(tags, isNot(contains('opendns_udp')));
      expect(codes(w, kWarnDnsEntryKept), isEmpty);
    });

    test('файл без каталога от lxbox — как 1.1.134: снятие по шаблону', () {
      final got = run(
        fileServers: full(without: {'opendns_udp'}),
        local: full(),
      );
      expect(got.servers.map((s) => s.tag), isNot(contains('opendns_udp')));
    });

    test('файл без каталога от launcher — слияние', () {
      final got = run(
        fileServers: full(without: {'opendns_doh', 'yandex_dot'}),
        local: full(),
        exportedBy: kLxAppLauncher,
      );
      expect(got.servers, full());
    });

    test('файл без серверов не трогает состав даже с каталогом', () {
      final got = run(fileServers: const [], local: full(), catalog: allTags);
      expect(got.servers, full());
    });

    test('final файла на чужой тег — сброс на умолчание шаблона', () {
      final w = <LxBackupWarning>[];
      final got = run(
        fileServers: full(),
        local: full(),
        catalog: allTags,
        fileFinal: 'direct_dns_resolver',
        localFinal: 'quad9_doh',
        warnings: w,
      );
      expect(got.dnsFinal, 'google_udp');
      expect(codes(w, kWarnDnsResolverReset), ['final=direct_dns_resolver']);
    });

    test('final файла на выключенный сервер — сброс', () {
      final w = <LxBackupWarning>[];
      final got = run(
        fileServers: full(),
        local: [
          for (final s in full())
            s.tag == 'quad9_doh' ? s.withEnabled(false) : s,
        ],
        catalog: allTags,
        fileFinal: 'quad9_doh',
        warnings: w,
      );
      expect(got.dnsFinal, 'google_udp');
      expect(codes(w, kWarnDnsResolverReset), ['final=quad9_doh']);
    });

    test('final файла на известный включённый — без сброса', () {
      final w = <LxBackupWarning>[];
      final got = run(
        fileServers: full(),
        local: full(),
        catalog: allTags,
        fileFinal: 'quad9_doh',
        warnings: w,
      );
      expect(got.dnsFinal, 'quad9_doh');
      expect(codes(w, kWarnDnsResolverReset), isEmpty);
    });

    test('final файла на сервер пресета, активного после импорта, — без сброса',
        () {
      // Записи сервера пресета у приёмника нет: её досеет шаг 2
      // resolveDnsServersList на следующей сборке.
      final preset = SelectableRule(
        label: 'Russian domains direct',
        presetId: 'ru-direct',
        rule: const {'domain_suffix': ['ru'], 'outbound': 'direct-out'},
        dnsRule: const {'domain_suffix': ['ru'], 'server': 'yandex_udp'},
        dnsServers: [
          {'type': 'udp', 'tag': 'yandex_udp', 'server': '77.88.8.8'},
        ],
      );
      final w = <LxBackupWarning>[];
      final got = run(
        fileServers: full(),
        local: full(),
        catalog: allTags,
        // тег сервера пресета в сборке — с неймспейсом `<preset_id>:`
        fileFinal: 'ru-direct:yandex_udp',
        routing: [CustomRulePreset(name: 'ru', presetId: 'ru-direct')],
        presets: [preset],
        warnings: w,
      );
      expect(got.servers.map((s) => s.tag),
          isNot(contains('ru-direct:yandex_udp')));
      expect(got.dnsFinal, 'ru-direct:yandex_udp');
      expect(codes(w, kWarnDnsResolverReset), isEmpty);
    });

    test('группа из одних чужих членов ввозится выключенной', () {
      const foreignGroup = DnsServerInline(
          enabled: true,
          tag: 'desk-group',
          body: {
            'type': 'group',
            'servers': ['direct_dns_resolver', 'adguard_doh'],
          });
      const okGroup = DnsServerInline(
          enabled: true,
          tag: 'ok-group',
          body: {
            'type': 'group',
            'servers': ['adguard_doh', 'google_udp'],
          });
      final w = <LxBackupWarning>[];
      final got = run(
        fileServers: [...full(), foreignGroup, okGroup],
        local: full(),
        catalog: allTags,
        warnings: w,
      );
      final byTag = {for (final s in got.servers) s.tag: s};
      expect(byTag['desk-group']!.enabled, isFalse);
      expect(byTag['ok-group']!.enabled, isTrue);
      expect(codes(w, kWarnDnsGroupEmpty), ['desk-group']);
    });
  });

  group('§681 экспорт template_catalog', () {
    test('каталог пишется всегда, когда известен; пустой — пустым', () {
      final withCatalog = dnsToBackup(
        servers: const [],
        rules: const [],
        dnsFinal: '',
        strategy: '',
        templateCatalog: const ['google_udp', 'quad9_doh'],
      );
      expect(withCatalog!['template_catalog'], ['google_udp', 'quad9_doh']);
      final empty = dnsToBackup(
        servers: const [],
        rules: const [],
        dnsFinal: '',
        strategy: '',
        templateCatalog: const [],
      );
      expect(empty!['template_catalog'], isEmpty);
      expect(
          dnsToBackup(
              servers: const [], rules: const [], dnsFinal: '', strategy: ''),
          isNull);
    });
  });
}
