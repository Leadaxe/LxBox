import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:lxbox/models/custom_rule.dart';
import 'package:lxbox/models/parser_config.dart';
import 'package:lxbox/services/builder/post_steps.dart';
import 'package:lxbox/services/builder/rule_set_registry.dart';
import 'package:lxbox/services/settings_storage.dart';

/// §117 задача 3 — «Опция DNS у правила (DNS follows the rule)».
///
/// - модель: `RuleDns` сериализация + backward-compat (нет `dns` → null);
/// - гейт `dnsMirrorActive` (ports/protocols → mirror не эмитится);
/// - applyAllCustomRules: сбор mirror-группы (inline+dns / srs+dns,
///   порядок = routing-правила);
/// - applyCustomDns: эмиссия группы у якоря, подстановка server, пропавший
///   сервер → тихо (решение №3), force-include реферимого сервера (locked №7);
/// - resolveDnsRulesList: компакция kind:preset блока (решение №6).
void main() {
  late Directory tmp;
  const channel = MethodChannel('plugins.flutter.io/path_provider');

  setUp(() async {
    TestWidgetsFlutterBinding.ensureInitialized();
    tmp = await Directory.systemTemp.createTemp('lxbox_rule_dns_test_');
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
      if (call.method == 'getApplicationDocumentsDirectory' ||
          call.method == 'getApplicationDocumentsPath') {
        return tmp.path;
      }
      return null;
    });
    SettingsStorage.resetCacheForTesting();
  });

  tearDown(() async {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null);
    if (tmp.existsSync()) await tmp.delete(recursive: true);
  });

  group('RuleDns model (§117 задача 3)', () {
    test('toJson/fromJson roundtrip с dns', () {
      final rule = CustomRuleInline(
        name: 'r1',
        domains: ['example.com'],
        outbound: 'vpn-1',
        dns: const RuleDns(enabled: true, serverTag: 'google_udp'),
      );
      final restored = CustomRule.fromJson(rule.toJson());
      expect(restored.dns, isNotNull);
      expect(restored.dns!.enabled, true);
      expect(restored.dns!.serverTag, 'google_udp');
    });

    test('backward-compat: нет dns в JSON → null, mirror неактивен', () {
      final restored = CustomRule.fromJson({
        'name': 'old',
        'enabled': true,
        'kind': 'inline',
        'domains': ['a.com'],
        'outbound': 'direct-out',
      });
      expect(restored.dns, null);
      expect(restored.dnsMirrorActive, false);
    });

    test('dns с enabled:false сохраняет serverTag (выбор не теряется)', () {
      final rule = CustomRuleSrs(
        name: 's1',
        srsUrl: 'https://e/x.srs',
        dns: const RuleDns(enabled: false, serverTag: 'cloudflare_udp'),
      );
      final restored = CustomRule.fromJson(rule.toJson());
      expect(restored.dns!.enabled, false);
      expect(restored.dns!.serverTag, 'cloudflare_udp');
      expect(restored.dnsMirrorActive, false);
    });

    test('гейт dnsMirrorActive: ports / protocols / disabled / пустой tag', () {
      const dnsOn = RuleDns(enabled: true, serverTag: 'google_udp');
      expect(
        CustomRuleInline(name: 'ok', domains: ['a.com'], dns: dnsOn)
            .dnsMirrorActive,
        true,
      );
      expect(
        CustomRuleInline(
                name: 'p', domains: ['a.com'], ports: ['443'], dns: dnsOn)
            .dnsMirrorActive,
        false,
        reason: 'ports — headless-гейт',
      );
      expect(
        CustomRuleInline(
                name: 'pr', domains: ['a.com'], portRanges: ['1:99'], dns: dnsOn)
            .dnsMirrorActive,
        false,
      );
      expect(
        CustomRuleInline(
                name: 'proto',
                domains: ['a.com'],
                protocols: ['quic'],
                dns: dnsOn)
            .dnsMirrorActive,
        false,
        reason: 'protocols — headless-гейт',
      );
      expect(
        CustomRuleInline(
                name: 'net',
                domains: ['a.com'],
                network: ['udp'],
                dns: dnsOn)
            .dnsMirrorActive,
        false,
        reason: '§240 network — headless-гейт',
      );
      expect(
        CustomRuleInline(
                name: 'off', enabled: false, domains: ['a.com'], dns: dnsOn)
            .dnsMirrorActive,
        false,
      );
      expect(
        CustomRuleInline(
                name: 'no-srv',
                domains: ['a.com'],
                dns: const RuleDns(enabled: true, serverTag: ''))
            .dnsMirrorActive,
        false,
      );
    });

    // §256 — Force IPv4 (AAAA-глушилка).
    test('forceIpv4 roundtrip + скрыт когда false', () {
      final on = CustomRuleInline(
        name: 'f',
        domains: ['a.com'],
        dns: const RuleDns(forceIpv4: true),
      );
      expect(on.toJson()['dns'], containsPair('forceIpv4', true));
      final r = CustomRule.fromJson(on.toJson());
      expect(r.dns!.forceIpv4, true);

      // false → ключ не пишется (симметрия с resolve-опциями).
      final off = CustomRuleInline(
        name: 'f2',
        domains: ['a.com'],
        dns: const RuleDns(enabled: true, serverTag: 'google_udp'),
      );
      expect(
          (off.toJson()['dns'] as Map).containsKey('forceIpv4'), false);
    });

    test('гейт forceIpv4Active: НЕ требует serverTag; режется port/protocol',
        () {
      const force = RuleDns(forceIpv4: true);
      // Домены + галка, без сервера → активна (глушилка серверу не нужна).
      expect(
        CustomRuleInline(name: 'd', domains: ['a.com'], dns: force)
            .forceIpv4Active,
        true,
        reason: 'serverTag не требуется',
      );
      // Только приложение (package_name), без доменов → активна (кейс
      // «глючному приложению v4»).
      expect(
        CustomRuleInline(
                name: 'app', packages: ['com.x'], dns: force)
            .forceIpv4Active,
        true,
      );
      // ports / protocols → DNS-слеп → неактивна.
      expect(
        CustomRuleInline(
                name: 'p', domains: ['a.com'], ports: ['443'], dns: force)
            .forceIpv4Active,
        false,
      );
      expect(
        CustomRuleInline(
                name: 'pr',
                domains: ['a.com'],
                protocols: ['quic'],
                dns: force)
            .forceIpv4Active,
        false,
      );
      // disabled правило → неактивна.
      expect(
        CustomRuleInline(
                name: 'off',
                enabled: false,
                domains: ['a.com'],
                dns: force)
            .forceIpv4Active,
        false,
      );
      // галка выкл → неактивна.
      expect(
        CustomRuleInline(
                name: 'g',
                domains: ['a.com'],
                dns: const RuleDns(enabled: true, serverTag: 'google_udp'))
            .forceIpv4Active,
        false,
      );
    });
  });

  group('applyAllCustomRules — сбор mirror-группы', () {
    test('inline+dns: mirror шарит headless rule_set (wifi внутри rule_set)',
        () {
      final reg = RuleSetRegistry();
      final result = applyAllCustomRules(
        reg,
        [
          CustomRuleInline(
            name: 'tg-via-vpn',
            domainSuffixes: ['telegram.org'],
            packages: ['org.telegram.messenger'],
            wifiSsids: ['HomeWifi'],
            outbound: 'vpn-1',
            dns: const RuleDns(enabled: true, serverTag: 'google_udp'),
          ),
        ],
        const [],
      );

      expect(result.dnsMirrors, hasLength(1));
      final m = result.dnsMirrors.single;
      expect(m.ruleId, isNotEmpty);
      expect(m.presetId, null);
      expect(m.serverTag, 'google_udp');
      expect(m.body['rule_set'], 'tg-via-vpn');
      // §030/new_fields: wifi_* теперь ВНУТРИ shared headless rule_set
      // (sing-box 1.14) — в DNS-mirror body не дублируется.
      expect(m.body.containsKey('wifi_ssid'), false);
      expect(reg.getRuleSets().single['rules'], [
        {
          'domain_suffix': ['telegram.org'],
          'package_name': ['org.telegram.messenger'],
          'wifi_ssid': ['HomeWifi'],
        },
      ]);
      expect(m.body.containsKey('server'), false,
          reason: 'server подставляет applyCustomDns (фильтр пропавших)');
      // Routing-сторона не изменилась: rule_set один, route-rule с outbound.
      expect(reg.getRuleSets(), hasLength(1));
      expect(reg.getRules().single['outbound'], 'vpn-1');
    });

    test('srs+dns: rule_set не генерится, mirror ссылается на .srs-тег', () {
      final reg = RuleSetRegistry();
      final srs = CustomRuleSrs(
        name: 'cn-list',
        srsUrl: 'https://e/cn.srs',
        packages: ['com.app'],
        outbound: 'vpn-2',
        dns: const RuleDns(enabled: true, serverTag: 'cloudflare_udp'),
      );
      final result = applyAllCustomRules(
        reg,
        [srs],
        const [],
        srsPaths: {srs.id: '/tmp/cn.srs'},
      );

      expect(reg.getRuleSets(), hasLength(1),
          reason: 'no split — только .srs rule_set, без дополнительного');
      final m = result.dnsMirrors.single;
      expect(m.body['rule_set'], 'cn-list');
      expect(m.body['package_name'], ['com.app']);
      expect(m.serverTag, 'cloudflare_udp');
    });

    // §256 — srs + Force IPv4: serverless-mirror с .srs-тегом.
    test('srs+forceIpv4 → serverless-mirror ссылается на .srs-тег', () {
      final reg = RuleSetRegistry();
      final srs = CustomRuleSrs(
        name: 'cn-list',
        srsUrl: 'https://e/cn.srs',
        outbound: 'vpn-2',
        dns: const RuleDns(forceIpv4: true),
      );
      final result = applyAllCustomRules(
        reg,
        [srs],
        const [],
        srsPaths: {srs.id: '/tmp/cn.srs'},
      );
      final m = result.dnsMirrors.single;
      expect(m.serverless, true);
      expect(m.serverTag, '');
      expect(m.body, {
        'rule_set': 'cn-list',
        'ip_version': 6,
        'action': 'predefined',
        'rcode': 'NOERROR',
      });
    });

    test('гейт в build: ports → mirror не собирается (defensive к UI)', () {
      final reg = RuleSetRegistry();
      final result = applyAllCustomRules(
        reg,
        [
          CustomRuleInline(
            name: 'gated',
            domains: ['a.com'],
            ports: ['443'],
            outbound: 'vpn-1',
            dns: const RuleDns(enabled: true, serverTag: 'google_udp'),
          ),
        ],
        const [],
      );
      expect(result.dnsMirrors, isEmpty);
      expect(reg.getRules(), hasLength(1), reason: 'routing-сторона живёт');
    });

    // §256 — Force IPv4: serverless AAAA-глушилка.
    test('forceIpv4 inline → serverless-mirror {ip_version:6, predefined}',
        () {
      final reg = RuleSetRegistry();
      final result = applyAllCustomRules(
        reg,
        [
          CustomRuleInline(
            name: 'ru',
            domainSuffixes: ['ru'],
            outbound: 'direct-out',
            dns: const RuleDns(forceIpv4: true),
          ),
        ],
        const [],
      );
      final m = result.dnsMirrors.single;
      expect(m.serverless, true);
      expect(m.serverTag, '');
      expect(m.body, {
        'rule_set': 'ru',
        'ip_version': 6,
        'action': 'predefined',
        'rcode': 'NOERROR',
      });
      expect(reg.getRules().single['outbound'], 'direct-out',
          reason: 'routing-сторона живёт независимо');
    });

    test('forceIpv4 + dedicated server → ДВА mirror\'а, глушилка ПЕРВОЙ', () {
      final reg = RuleSetRegistry();
      final result = applyAllCustomRules(
        reg,
        [
          CustomRuleInline(
            name: 'ru',
            domainSuffixes: ['ru'],
            outbound: 'direct-out',
            dns: const RuleDns(
                enabled: true, serverTag: 'google_udp', forceIpv4: true),
          ),
        ],
        const [],
      );
      expect(result.dnsMirrors, hasLength(2));
      // Порядок §253: AAAA-гейт первым, server-mirror вторым.
      expect(result.dnsMirrors[0].serverless, true);
      expect(result.dnsMirrors[0].body['ip_version'], 6);
      expect(result.dnsMirrors[1].serverless, false);
      expect(result.dnsMirrors[1].serverTag, 'google_udp');
      expect(result.dnsMirrors[1].body.containsKey('ip_version'), false);
    });

    test('forceIpv4 только приложение (без доменов) → serverless-mirror '
        'с package_name', () {
      final reg = RuleSetRegistry();
      final result = applyAllCustomRules(
        reg,
        [
          CustomRuleInline(
            name: 'glitchy',
            packages: ['com.buggy.ipv6'],
            outbound: 'direct-out',
            dns: const RuleDns(forceIpv4: true),
          ),
        ],
        const [],
      );
      final m = result.dnsMirrors.single;
      expect(m.serverless, true);
      expect(m.body['ip_version'], 6);
      expect(m.body['action'], 'predefined');
      // rule_set — headless-тег правила (package_name внутри него).
      expect(m.body['rule_set'], 'glitchy');
    });

    test('forceIpv4 + ports → serverless-mirror не собирается (DNS-слеп)', () {
      final reg = RuleSetRegistry();
      final result = applyAllCustomRules(
        reg,
        [
          CustomRuleInline(
            name: 'p',
            domains: ['a.com'],
            ports: ['443'],
            outbound: 'vpn-1',
            dns: const RuleDns(forceIpv4: true),
          ),
        ],
        const [],
      );
      expect(result.dnsMirrors, isEmpty);
    });

    test('порядок группы = порядок routing-правил (preset + rule)', () {
      final reg = RuleSetRegistry();
      final result = applyAllCustomRules(
        reg,
        [
          CustomRuleInline(
            name: 'first-rule',
            domains: ['a.com'],
            outbound: 'vpn-1',
            dns: const RuleDns(enabled: true, serverTag: 'google_udp'),
          ),
          CustomRulePreset(
            name: 'ru',
            presetId: 'ru-direct',
            varsValues: {'outbound': 'direct-out'},
          ),
          CustomRuleInline(
            name: 'last-rule',
            domains: ['b.com'],
            outbound: 'vpn-2',
            dns: const RuleDns(enabled: true, serverTag: 'cloudflare_udp'),
          ),
        ],
        [_ruDirect()],
      );

      expect(result.dnsMirrors, hasLength(3));
      expect(result.dnsMirrors[0].ruleName, 'first-rule');
      expect(result.dnsMirrors[1].presetId, 'ru-direct');
      expect(result.dnsMirrors[2].ruleName, 'last-rule');
    });

    // §253 — пресет с dns_rules-массивом: mirror на КАЖДОЕ правило, подряд,
    // в порядке шаблона; dnsRulesByPresetId несёт весь список.
    test('dns_rules-массив пресета → mirror на каждое правило, порядок шаблона',
        () {
      final reg = RuleSetRegistry();
      final result = applyAllCustomRules(
        reg,
        [
          CustomRulePreset(
            name: 'ru',
            presetId: 'ru-direct',
            varsValues: {'outbound': 'direct-out'},
          ),
        ],
        [_ruDirectDnsPair()],
      );

      expect(result.dnsMirrors, hasLength(2));
      expect(result.dnsMirrors[0].presetId, 'ru-direct');
      expect(result.dnsMirrors[0].body['action'], 'predefined');
      expect(result.dnsMirrors[0].body.containsKey('server'), isFalse);
      expect(result.dnsMirrors[1].presetId, 'ru-direct');
      expect(result.dnsMirrors[1].body['server'], 'yandex_udp');
      expect(result.dnsRulesByPresetId['ru-direct'], hasLength(2));
    });
  });

  group('applyCustomDns — эмиссия mirror-группы', () {
    // §117-обёртка template-сервера (минимальная).
    Map<String, dynamic> tplServer(String tag, String ip,
            {bool enabled = true}) =>
        {
          'description': tag,
          'enabled': enabled,
          'server': {'type': 'udp', 'tag': tag, 'server': ip, 'server_port': 53},
        };

    test('rule-mirror эмитится с server; кейс «правило → свой DNS»', () async {
      final config = <String, dynamic>{};
      await applyCustomDns(
        config,
        {
          'servers': [tplServer('google_udp', '8.8.8.8')],
          'rules': [],
        },
        dnsMirrors: const [
          DnsMirrorEntry(
            ruleId: 'r1',
            ruleName: 'tg',
            serverTag: 'google_udp',
            body: {'rule_set': 'tg'},
          ),
        ],
      );

      final dns = config['dns'] as Map<String, dynamic>;
      expect(dns['rules'], [
        {'rule_set': 'tg', 'server': 'google_udp'},
      ]);
    });

    // §256 — serverless rule-mirror (Force IPv4 predefined): server НЕ
    // подставляется, запись НЕ режется отсутствием сервера в dns.servers.
    test('serverless rule-mirror эмитится как есть (без server-подстановки)',
        () async {
      final config = <String, dynamic>{};
      await applyCustomDns(
        config,
        {'servers': [], 'rules': []},
        dnsMirrors: const [
          DnsMirrorEntry(
            ruleId: 'r1',
            ruleName: 'ru',
            serverless: true,
            body: {
              'rule_set': 'ru',
              'ip_version': 6,
              'action': 'predefined',
              'rcode': 'NOERROR',
            },
          ),
        ],
      );
      final dns = config['dns'] as Map<String, dynamic>;
      expect(dns['rules'], [
        {
          'rule_set': 'ru',
          'ip_version': 6,
          'action': 'predefined',
          'rcode': 'NOERROR',
        },
      ]);
    });

    // §253 — serverless-тело пресета (predefined, без ключа `server`)
    // проходит defensive-гейт эмиссии (гейт только для String-server).
    test('serverless preset-mirror (predefined) эмитится; route-тело — '
        'с server-гейтом', () async {
      await SettingsStorage.saveDnsRulesList([
        {'enabled': true, 'kind': 'preset', 'presetId': 'ru-direct'},
      ]);

      final config = <String, dynamic>{};
      await applyCustomDns(
        config,
        {'servers': [], 'rules': []},
        extraServers: const [
          {'type': 'udp', 'tag': 'yandex_udp', 'server': '77.88.8.8'},
        ],
        activePresetIdsWithDnsRule: const {'ru-direct'},
        dnsMirrors: const [
          DnsMirrorEntry(
            presetId: 'ru-direct',
            ruleName: 'ru',
            body: {
              'rule_set': ['ru-domains'],
              'ip_version': 6,
              'action': 'predefined',
              'rcode': 'NOERROR',
            },
          ),
          DnsMirrorEntry(
            presetId: 'ru-direct',
            ruleName: 'ru',
            body: {
              'rule_set': ['ru-domains'],
              'server': 'yandex_udp',
            },
          ),
        ],
      );

      final dns = config['dns'] as Map<String, dynamic>;
      expect(dns['rules'], [
        {
          'rule_set': ['ru-domains'],
          'ip_version': 6,
          'action': 'predefined',
          'rcode': 'NOERROR',
        },
        {
          'rule_set': ['ru-domains'],
          'server': 'yandex_udp',
        },
      ]);
    });

    test('пропавший сервер → DNS-rule тихо не эмитится (решение №3)', () async {
      final config = <String, dynamic>{};
      await applyCustomDns(
        config,
        {
          'servers': [tplServer('google_udp', '8.8.8.8')],
          'rules': [],
        },
        dnsMirrors: const [
          DnsMirrorEntry(
            ruleId: 'r1',
            ruleName: 'tg',
            serverTag: 'deleted_server',
            body: {'rule_set': 'tg'},
          ),
        ],
      );

      final dns = config['dns'] as Map<String, dynamic>;
      expect(dns.containsKey('rules'), false,
          reason: 'mirror с висящим serverTag молча пропущен, без warning');
    });

    test(
        'якорь группы — первая kind:preset запись; порядок внутри = '
        'routing-правила', () async {
      await SettingsStorage.saveDnsRulesList([
        {
          'enabled': true,
          'kind': 'inline',
          'name': 'user-first',
          'rule': {'domain': ['x.com'], 'server': 'google_udp'},
        },
        {'enabled': true, 'kind': 'preset', 'presetId': 'ru-direct'},
      ]);

      final config = <String, dynamic>{};
      await applyCustomDns(
        config,
        {
          'servers': [tplServer('google_udp', '8.8.8.8')],
          'rules': [],
        },
        extraServers: const [
          {'type': 'udp', 'tag': 'yandex_udp', 'server': '77.88.8.8'},
        ],
        activePresetIdsWithDnsRule: const {'ru-direct'},
        dnsMirrors: const [
          // routing order: сначала rule-mirror, потом preset
          DnsMirrorEntry(
            ruleId: 'r1',
            ruleName: 'tg',
            serverTag: 'google_udp',
            body: {'rule_set': 'tg'},
          ),
          DnsMirrorEntry(
            presetId: 'ru-direct',
            ruleName: 'ru',
            body: {'rule_set': 'ru-domains', 'server': 'yandex_udp'},
          ),
        ],
      );

      final dns = config['dns'] as Map<String, dynamic>;
      expect(dns['rules'], [
        {'domain': ['x.com'], 'server': 'google_udp'}, // standalone выше якоря
        {'rule_set': 'tg', 'server': 'google_udp'}, // группа: routing order
        {'rule_set': 'ru-domains', 'server': 'yandex_udp'},
      ]);
    });

    test(
        'lifecycle (locked №7): выключенный сервер, реферимый правилом — '
        'force-include в dns.servers', () async {
      await SettingsStorage.saveDnsServers([
        {'enabled': false, 'kind': 'template', 'tag': 'google_udp'},
      ]);

      final config = <String, dynamic>{};
      await applyCustomDns(
        config,
        {
          'servers': [tplServer('google_udp', '8.8.8.8')],
          'rules': [],
        },
        dnsMirrors: const [
          DnsMirrorEntry(
            ruleId: 'r1',
            ruleName: 'tg',
            serverTag: 'google_udp',
            body: {'rule_set': 'tg'},
          ),
        ],
      );

      final dns = config['dns'] as Map<String, dynamic>;
      final tags = [for (final s in dns['servers'] as List) s['tag']];
      expect(tags, contains('google_udp'),
          reason: 'сервер реферится активным правилом — не выпадает');
      expect(dns['rules'], [
        {'rule_set': 'tg', 'server': 'google_udp'},
      ]);
    });
  });

  group('resolveDnsRulesList — атомарность mirror-группы (решение №6)', () {
    test('kind:preset записи компактятся к позиции первой', () async {
      await SettingsStorage.saveDnsRulesList([
        {'enabled': true, 'kind': 'preset', 'presetId': 'p1'},
        {
          'enabled': true,
          'kind': 'inline',
          'name': 'user-mid',
          'rule': {'domain': ['x.com'], 'server': 's'},
        },
        {'enabled': true, 'kind': 'preset', 'presetId': 'p2'},
      ]);

      final resolved = await resolveDnsRulesList(
        templateRules: const [],
        activePresetIdsWithDnsRule: const {'p1', 'p2'},
      );

      expect(
        [for (final e in resolved) e['kind']],
        ['preset', 'preset', 'inline'],
        reason: 'standalone-запись не может стоять внутри группы',
      );
      expect(resolved[0]['presetId'], 'p1');
      expect(resolved[1]['presetId'], 'p2');
    });
  });
}

SelectableRule _ruDirect() => SelectableRule(
      label: 'Russian domains direct',
      defaultEnabled: true,
      presetId: 'ru-direct',
      vars: [
        WizardVar(
          name: 'outbound',
          type: 'outbound',
          defaultValue: 'direct-out',
        ),
        WizardVar(
          name: 'dns_server',
          type: 'dns_servers',
          defaultValue: 'yandex_udp',
          required: false,
        ),
      ],
      ruleSets: [
        {
          'tag': 'ru-domains',
          'type': 'inline',
          'format': 'domain_suffix',
          'rules': [
            {
              'domain_suffix': ['ru']
            }
          ]
        }
      ],
      dnsRule: const {'rule_set': 'ru-domains', 'server': '@dns_server'},
      rule: const {'rule_set': 'ru-domains', 'outbound': '@outbound'},
      dnsServers: [
        {
          'type': 'udp',
          'tag': 'yandex_udp',
          'server': '77.88.8.8',
          'detour': '@outbound',
        }
      ],
    );

/// §253 — реплика ru-direct с ПАРОЙ DNS-правил (AAAA-гейт + маршрут).
SelectableRule _ruDirectDnsPair() => SelectableRule(
      label: 'Russian domains direct',
      presetId: 'ru-direct',
      vars: [
        WizardVar(
          name: 'outbound',
          type: 'outbound',
          defaultValue: 'direct-out',
        ),
        WizardVar(
          name: 'dns_server',
          type: 'dns_servers',
          defaultValue: 'yandex_udp',
          required: false,
        ),
      ],
      ruleSets: [
        {
          'tag': 'ru-domains',
          'type': 'inline',
          'format': 'domain_suffix',
          'rules': [
            {
              'domain_suffix': ['ru']
            }
          ]
        }
      ],
      dnsRule: const [
        {
          'rule_set': 'ru-domains',
          'ip_version': 6,
          'action': 'predefined',
          'rcode': 'NOERROR',
        },
        {'rule_set': 'ru-domains', 'server': '@dns_server'},
      ],
      rule: const {'rule_set': 'ru-domains', 'outbound': '@outbound'},
      dnsServers: [
        {
          'type': 'udp',
          'tag': 'yandex_udp',
          'server': '77.88.8.8',
          'detour': '@outbound',
        }
      ],
    );
