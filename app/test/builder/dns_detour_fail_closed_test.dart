import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:lxbox/models/custom_rule.dart';
import 'package:lxbox/models/dns_ref.dart';
import 'package:lxbox/services/builder/post_steps.dart';
import 'package:lxbox/services/direction_mutations.dart';
import 'package:lxbox/services/settings_storage.dart';

import '../storage_migration/golden_harness.dart';

// §441 (SPEC 128 Н10) — вторая линия fail-closed на сборке: DNS-сервер,
// чей `detour` после подстановки висит, не эмитится; правила на него
// становятся отказом, `dns.final` и резолверы лечатся одним местом
// ([healDetourDroppedDnsRefs]); `detour: direct-out` снимается, как раньше.

void main() {
  group('healDetourDroppedDnsRefs', () {
    Map<String, dynamic> config() => {
          'dns': {
            'servers': [
              {'type': 'udp', 'tag': 'google_udp', 'server': '8.8.8.8'},
              {'type': 'fakeip', 'tag': 'fakeip'},
              {'type': 'group', 'tag': 'dns_shield', 'servers': ['google_udp']},
              {
                'type': 'tls',
                'tag': 'safe_dns_dot',
                'server': 'dns.adguard-dns.com',
                'domain_resolver': 'google_dot',
              },
            ],
            'rules': [
              {
                'domain_suffix': ['.dot'],
                'server': 'google_dot',
                'strategy': 'ipv4_only',
                'disable_cache': true,
              },
              {
                'type': 'logical',
                'mode': 'and',
                'rules': [
                  {'domain_suffix': ['.x']},
                ],
                'action': 'evaluate',
                'server': 'google_dot',
              },
              {'query_type': ['AAAA'], 'action': 'predefined', 'rcode': 'NOERROR'},
              {'domain_suffix': ['.udp'], 'server': 'google_udp'},
            ],
            'final': 'google_dot',
          },
          'route': {'default_domain_resolver': 'google_dot'},
        };

    test('правила → reject, final и резолверы — замена умолчанием шаблона', () {
      final c = config();
      final warnings = healDetourDroppedDnsRefs(
        c,
        detourDropped: {'google_dot'},
        defaults: const {
          'dns_final': 'dns_shield',
          'dns_default_domain_resolver': 'dns_shield',
        },
      );
      final dns = c['dns'] as Map<String, dynamic>;
      final rules = dns['rules'] as List;
      expect(rules[0], {'domain_suffix': ['.dot'], 'action': 'reject'},
          reason: 'поля маршрута сняты, сопоставители целы');
      expect(rules[1], {
        'type': 'logical',
        'mode': 'and',
        'rules': [
          {'domain_suffix': ['.x']},
        ],
        'action': 'reject',
      });
      expect(rules[2]['action'], 'predefined');
      expect(rules[3]['server'], 'google_udp');
      expect(dns['final'], 'dns_shield');
      expect((c['route'] as Map)['default_domain_resolver'], 'dns_shield');
      expect((dns['servers'] as List)[3]['domain_resolver'], 'dns_shield');
      expect(warnings, hasLength(5));
    });

    test('умолчания нет — первый пригодный (не fakeip, не сам сервер)', () {
      final c = config();
      healDetourDroppedDnsRefs(c, detourDropped: {'google_dot'});
      final dns = c['dns'] as Map<String, dynamic>;
      expect(dns['final'], 'google_udp');
    });

    test('пустой набор выпавших — no-op', () {
      final c = config();
      expect(healDetourDroppedDnsRefs(c, detourDropped: const {}), isEmpty);
      expect((c['dns'] as Map)['final'], 'google_dot');
    });
  });

  group('resolveTemplateDnsServerBody', () {
    test('@name, которого сервер не объявил, — ключ выпадает и назван', () {
      final unknown = <String>[];
      final body = resolveTemplateDnsServerBody(
        {
          'vars': [
            {'name': 'outbound', 'default_value': 'direct-out'},
          ],
          'server': {
            'type': 'udp',
            'tag': 'x',
            'server': '@dns_ip',
            'detour': '@outbound',
          },
        },
        varValues: const {'outbound': ' vpn-1 '},
        unknownVarsOut: unknown,
      );
      expect(body, {'type': 'udp', 'tag': 'x', 'detour': 'vpn-1'});
      expect(unknown, ['dns_ip']);
    });
  });

  group('сборка из хранения', () {
    test('rich_v0: висячий detour — сервер выпал, правило отказ, final и резолвер вылечены',
        () async {
      final box = await StorageSandbox.create();
      addTearDown(box.dispose);
      await box.seed('rich_v0');

      // my-doh (inline, `dns.final`) и google_dot (template) — на
      // Направление, которого нет. google_udp — `direct-out`.
      final servers = [
        for (final s in await SettingsStorage.getDnsServers())
          switch (s) {
            DnsServerInline(tag: 'my-doh') =>
              s.copyWith(body: {...s.body, 'detour': 'vpn-ghost'}),
            DnsServerTemplate(tag: 'google_dot') =>
              s.copyWith(varValues: {'outbound': 'vpn-ghost'}),
            _ => s,
          },
      ];
      await SettingsStorage.saveDnsServers(servers);
      await SettingsStorage.saveDnsRulesList([
        const DnsRuleInline(
          name: 'Dot',
          rule: {
            'domain_suffix': ['.dot.example'],
            'server': 'google_dot',
            'strategy': 'ipv4_only',
          },
        ),
        ...await SettingsStorage.getDnsRulesList(),
      ]);
      await SettingsStorage.setVar('dns_default_domain_resolver', 'google_dot');

      final build = await buildGoldenConfig(box);
      final config = build.config;
      final dns = config['dns'] as Map<String, dynamic>;
      final byTag = {
        for (final s in (dns['servers'] as List).cast<Map<String, dynamic>>())
          s['tag']: s,
      };
      expect(byTag.containsKey('my-doh'), isFalse);
      expect(byTag.containsKey('google_dot'), isFalse);
      expect(byTag['google_udp']!.containsKey('detour'), isFalse,
          reason: 'direct-out снимается, как раньше');
      expect(byTag['dns-group']!['servers'], ['google_udp']);
      expect(byTag['dns_shield']!['servers'], isNot(contains('google_dot')));

      final rules = (dns['rules'] as List).cast<Map<String, dynamic>>();
      expect(rules.first, {
        'domain_suffix': ['.dot.example'],
        'action': 'reject',
      });
      expect(
          rules.where((r) => r['domain_suffix'] is List &&
              (r['domain_suffix'] as List).contains('.lan')),
          [
            {
              'domain_suffix': ['.lan'],
              'action': 'reject',
            },
          ]);
      expect(dns['final'], 'dns_shield');
      expect((config['route'] as Map)['default_domain_resolver'], 'dns_shield');

      expect(build.warnings,
          contains('DNS server "my-doh" dropped: its detour "vpn-ghost" is not in the config.'));
      expect(build.warnings,
          contains('DNS server "google_dot" dropped: its detour "vpn-ghost" is not in the config.'));
      // Выбор пользователя не переписан: сервер вернётся вместе с Направлением.
      final vars = await SettingsStorage.getAllVars();
      expect(vars['dns_final'], 'my-doh');
      expect(vars['dns_default_domain_resolver'], 'google_dot');
    });

    // SPEC 128 §6 (D-114): переменная типа `outbound` template-сервера —
    // одиночная цель по имени, как цель правила. Удаление Направления лечит
    // её в хранении, и сервер не выпадает на сборке.
    test('rich_v0: удаление vpn-3 — vars.outbound google_dot → vpn-1, как у правила; сервер в конфиге',
        () async {
      final box = await StorageSandbox.create();
      addTearDown(box.dispose);
      await box.seed('rich_v0');

      await SettingsStorage.saveDnsServers([
        for (final s in await SettingsStorage.getDnsServers())
          if (s is DnsServerTemplate && s.tag == 'google_dot')
            s.copyWith(varValues: {'outbound': 'vpn-3'})
          else
            s,
      ]);
      await SettingsStorage.saveCustomRules([
        CustomRuleInline(
            name: 'to-vpn-3', domains: const ['x.example'], outbound: 'vpn-3'),
        ...await SettingsStorage.getCustomRules(),
      ]);

      final healed = await DirectionMutations.delete('vpn-3', null);

      expect(healed.dnsServers, 1);
      expect(healed.rules, greaterThanOrEqualTo(1));
      final rule = (await SettingsStorage.getCustomRules())
          .firstWhere((r) => r.name == 'to-vpn-3');
      expect(rule.outbound, 'vpn-1');
      final dot = (await SettingsStorage.getDnsServers())
          .whereType<DnsServerTemplate>()
          .firstWhere((s) => s.tag == 'google_dot');
      expect(dot.varValues, isEmpty,
          reason: 'vpn-1 — умолчание шаблона: ключ снят (Н4)');
      expect(DirectionMutations.healMessageParts(healed),
          contains('1 DNS server(s) switched to vpn-1'));

      final build = await buildGoldenConfig(box);
      final dns = build.config['dns'] as Map<String, dynamic>;
      final byTag = {
        for (final s in (dns['servers'] as List).cast<Map<String, dynamic>>())
          s['tag']: s,
      };
      expect(byTag['google_dot']?['detour'], 'vpn-1');
      expect(build.warnings.where((w) => w.contains('"google_dot" dropped')),
          isEmpty);
    });

    // Снимок AVD: ключи узлов той же формы, что у настоящих, — конфиг
    // проходит `sing-box check`. Проверка ядром — вручную:
    // LX441_CONFIG_OUT=<путь> кладёт конфиг для `sing-box check -c <путь>`.
    test('avd_v0: domain_resolver серверов на выпавший google_udp вылечен', () async {
      final box = await StorageSandbox.create();
      addTearDown(box.dispose);
      await box.seed('avd_v0');

      await SettingsStorage.saveDnsServers([
        for (final s in await SettingsStorage.getDnsServers())
          if (s is DnsServerTemplate && s.tag == 'google_udp')
            s.copyWith(varValues: {'outbound': 'vpn-ghost'})
          else
            s,
      ]);
      await SettingsStorage.saveDnsRulesList([
        const DnsRuleInline(
          name: 'Udp',
          rule: {
            'domain_suffix': ['.udp.example'],
            'server': 'google_udp',
            'strategy': 'ipv4_only',
          },
        ),
        ...await SettingsStorage.getDnsRulesList(),
      ]);
      await SettingsStorage.setVar('dns_final', 'google_udp');

      final build = await buildGoldenConfig(box);
      final dns = build.config['dns'] as Map<String, dynamic>;
      final servers = (dns['servers'] as List).cast<Map<String, dynamic>>();
      expect(servers.map((s) => s['tag']), isNot(contains('google_udp')));
      for (final s in servers) {
        expect(s['domain_resolver'], isNot('google_udp'), reason: '${s['tag']}');
      }
      expect(dns['final'], 'dns_shield');
      expect((dns['rules'] as List).first, {
        'domain_suffix': ['.udp.example'],
        'action': 'reject',
      });

      final out = Platform.environment['LX441_CONFIG_OUT'];
      if (out != null && out.isNotEmpty) {
        File(out).writeAsStringSync(build.configJson);
      }
    });
  });
}
