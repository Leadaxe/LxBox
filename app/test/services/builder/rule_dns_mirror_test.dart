import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:lxbox/models/codec/dns_record.dart';
import 'package:lxbox/models/codec/rule_record.dart';
import 'package:lxbox/models/custom_rule.dart';
import 'package:lxbox/models/dns_ref.dart';
import 'package:lxbox/models/parser_config.dart';
import 'package:lxbox/services/builder/post_steps.dart';
import 'package:lxbox/services/builder/rule_set_registry.dart';
import 'package:lxbox/services/settings_storage.dart';
import 'package:lxbox/services/storage_migration/legacy_form_v0.dart';

/// Правило через запись `rules[]` и обратно — путь хранения (§439).
CustomRule _storageRoundTrip(CustomRule r) =>
    ruleFromRecord(ruleToRecord(r), unknownAsVerbatim: true).value!;

/// §117 задача 3 — «Опция DNS у правила (DNS follows the rule)».
///
/// - модель: `RuleDns` сериализация + backward-compat (нет `dns` → null);
/// - гейт `dnsMirrorActive` (§755: ports/protocols больше не гейтят);
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
    test('round-trip записи rules[] с dns', () {
      final rule = CustomRuleTree.flat(
        name: 'r1',
        domains: ['example.com'],
        outbound: 'vpn-1',
        dns: const RuleDns(enabled: true, serverTag: 'google_udp'),
      );
      final restored = _storageRoundTrip(rule);
      expect(restored.dns, isNotNull);
      expect(restored.dns!.enabled, true);
      expect(restored.dns!.serverTag, 'google_udp');
    });

    test('backward-compat: нет dns в форме 2.23.2 → null, mirror неактивен', () {
      final restored = readLegacyCustomRule({
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
      final rule = CustomRuleTree.flat(
        name: 's1',
        srsUrl: 'https://e/x.srs',
        dns: const RuleDns(enabled: false, serverTag: 'cloudflare_udp'),
      );
      final restored = _storageRoundTrip(rule);
      expect(restored.dns!.enabled, false);
      expect(restored.dns!.serverTag, 'cloudflare_udp');
      expect(restored.dnsMirrorActive, false);
    });

    test('гейт dnsMirrorActive: §755 ports/protocols не гейтят; disabled / пустой tag', () {
      const dnsOn = RuleDns(enabled: true, serverTag: 'google_udp');
      expect(
        CustomRuleTree.flat(name: 'ok', domains: ['a.com'], dns: dnsOn)
            .dnsMirrorActive,
        true,
      );
      expect(
        CustomRuleTree.flat(
                name: 'p', domains: ['a.com'], ports: ['443'], dns: dnsOn)
            .dnsMirrorActive,
        true,
        reason: 'ports — §755 гейт снят',
      );
      expect(
        CustomRuleTree.flat(
                name: 'pr', domains: ['a.com'], portRanges: ['1:99'], dns: dnsOn)
            .dnsMirrorActive,
        true,
      );
      expect(
        CustomRuleTree.flat(
                name: 'proto',
                domains: ['a.com'],
                protocols: ['quic'],
                dns: dnsOn)
            .dnsMirrorActive,
        true,
        reason: 'protocols — §755 гейт снят',
      );
      expect(
        CustomRuleTree.flat(
                name: 'net',
                domains: ['a.com'],
                network: ['udp'],
                dns: dnsOn)
            .dnsMirrorActive,
        true,
        reason: '§240 network — §755 гейт снят',
      );
      expect(
        CustomRuleTree.flat(
                name: 'off', enabled: false, domains: ['a.com'], dns: dnsOn)
            .dnsMirrorActive,
        false,
      );
      expect(
        CustomRuleTree.flat(
                name: 'no-srv',
                domains: ['a.com'],
                dns: const RuleDns(enabled: true, serverTag: ''))
            .dnsMirrorActive,
        false,
      );
    });

    // §256 — Force IPv4 (AAAA-глушилка).
    test('forceIpv4 roundtrip + скрыт когда false', () {
      final on = CustomRuleTree.flat(
        name: 'f',
        domains: ['a.com'],
        dns: const RuleDns(forceIpv4: true),
      );
      expect(ruleToRecord(on)['dns'], containsPair('forceIpv4', true));
      final r = _storageRoundTrip(on);
      expect(r.dns!.forceIpv4, true);

      // false → ключ не пишется (симметрия с resolve-опциями).
      final off = CustomRuleTree.flat(
        name: 'f2',
        domains: ['a.com'],
        dns: const RuleDns(enabled: true, serverTag: 'google_udp'),
      );
      expect(
          (ruleToRecord(off)['dns'] as Map).containsKey('forceIpv4'), false);
    });

    test('гейт forceIpv4Active: НЕ требует serverTag; §755 port/protocol не режут',
        () {
      const force = RuleDns(forceIpv4: true);
      // Домены + галка, без сервера → активна (глушилка серверу не нужна).
      expect(
        CustomRuleTree.flat(name: 'd', domains: ['a.com'], dns: force)
            .forceIpv4Active,
        true,
        reason: 'serverTag не требуется',
      );
      // Только приложение (package_name), без доменов → активна (кейс
      // «глючному приложению v4»).
      expect(
        CustomRuleTree.flat(
                name: 'app', packages: ['com.x'], dns: force)
            .forceIpv4Active,
        true,
      );
      // §755: ports / protocols больше не гейтят.
      expect(
        CustomRuleTree.flat(
                name: 'p', domains: ['a.com'], ports: ['443'], dns: force)
            .forceIpv4Active,
        true,
      );
      expect(
        CustomRuleTree.flat(
                name: 'pr',
                domains: ['a.com'],
                protocols: ['quic'],
                dns: force)
            .forceIpv4Active,
        true,
      );
      // disabled правило → неактивна.
      expect(
        CustomRuleTree.flat(
                name: 'off',
                enabled: false,
                domains: ['a.com'],
                dns: force)
            .forceIpv4Active,
        false,
      );
      // галка выкл → неактивна.
      expect(
        CustomRuleTree.flat(
                name: 'g',
                domains: ['a.com'],
                dns: const RuleDns(enabled: true, serverTag: 'google_udp'))
            .forceIpv4Active,
        false,
      );
    });
  });

  group('§692 — DNS-опция только при условии, видимом DNS-слою', () {
    const dnsOn = RuleDns(enabled: true, serverTag: 'google_udp');
    const force = RuleDns(forceIpv4: true);
    const fixed = RuleDns(fixedIps: ['10.1.1.1']);

    test('ip_cidr-only: ни зеркало, ни Force IPv4, ни Fixed IP', () {
      final r = CustomRuleTree.flat(
          name: 'lan', ipCidrs: ['10.0.0.0/8'], outbound: 'vpn-1', dns: dnsOn);
      expect(r.dnsLayerEligible, false);
      expect(r.dnsMirrorActive, false, reason: 'набор «только IP»');
      expect(
        CustomRuleTree.flat(name: 'f', ipCidrs: ['10.0.0.0/8'], dns: force)
            .forceIpv4Active,
        false,
      );
      expect(
        CustomRuleTree.flat(name: 'x', ipCidrs: ['10.0.0.0/8'], dns: fixed)
            .dnsFixedActive,
        false,
      );
      // routing-level поле `ip_is_private` не делает правило DNS-способным.
      expect(
        CustomRuleTree.flat(
                name: 'priv',
                ipCidrs: ['10.0.0.0/8'],
                ipIsPrivate: true,
                dns: dnsOn)
            .dnsMirrorActive,
        false,
      );
      // §757 — `source_ip_is_private` в таблице условий `dns: true`: идёт в
      // зеркало, правило DNS-способно.
      expect(
        CustomRuleTree.flat(
                name: 'priv-src',
                ipCidrs: ['10.0.0.0/8'],
                sourceIpIsPrivate: true,
                dns: dnsOn)
            .dnsMirrorActive,
        true,
      );
    });

    // §757 — гейт `ip_cidr + inbound` снят (TASKS_LXBOX §182 п. 2.4, кейс
    // корпуса `ip_cidr_inbound_mirror`): зеркало по `inbound`.
    test('ip_cidr + inbound: зеркало по inbound → DNS-способно (§757)', () {
      final r = CustomRuleTree.flat(
          name: 'i',
          ipCidrs: ['10.0.0.0/8'],
          inbounds: ['tun-in'],
          outbound: 'vpn-1',
          dns: dnsOn);
      expect(r.dnsMirrorActive, true);
      final m = applyAllCustomRules(RuleSetRegistry(), [r], const [])
          .dnsMirrors
          .single;
      expect(m.body, {'inbound': ['tun-in']});
    });

    test('inbound-only / package / source_ip / wifi / домен — DNS-способно',
        () {
      expect(
        CustomRuleTree.flat(name: 'in', inbounds: ['tun-in'], dns: dnsOn)
            .dnsMirrorActive,
        true,
      );
      expect(
        CustomRuleTree.flat(
                name: 'pkg',
                ipCidrs: ['10.0.0.0/8'],
                packages: ['com.x'],
                dns: dnsOn)
            .dnsMirrorActive,
        true,
        reason: 'package_name — не-IP item, ядро принимает',
      );
      expect(
        CustomRuleTree.flat(
                name: 'src', sourceIpCidrs: ['192.168.1.0/24'], dns: dnsOn)
            .dnsMirrorActive,
        true,
      );
      expect(
        CustomRuleTree.flat(name: 'wifi', wifiSsids: ['Home'], dns: dnsOn)
            .dnsMirrorActive,
        true,
      );
      expect(
        CustomRuleTree.flat(
                name: 'dom',
                ipCidrs: ['10.0.0.0/8'],
                domainKeywords: ['nas'],
                dns: dnsOn)
            .dnsMirrorActive,
        true,
      );
    });

    test('srs — всегда DNS-способно (содержимое файла не разбирается)', () {
      expect(
        CustomRuleTree.flat(name: 's', srsUrl: 'https://e/geoip.srs', dns: dnsOn)
            .dnsLayerEligible,
        true,
      );
    });

    test('сборка: ip_cidr-only + dns → зеркала нет, route-правило есть', () {
      final reg = RuleSetRegistry();
      final result = applyAllCustomRules(
        reg,
        [
          CustomRuleTree.flat(
            name: 'lan',
            ipCidrs: ['10.0.0.0/8'],
            outbound: 'vpn-1',
            dns: const RuleDns(
                enabled: true, serverTag: 'google_udp', forceIpv4: true),
          ),
        ],
        const [],
      );
      expect(result.dnsMirrors, isEmpty);
      expect(reg.getRuleSets(), hasLength(1));
      expect(reg.getRules().any((r) => r['outbound'] == 'vpn-1'), true);
    });
  });

  group('§694 — тип/лимитность сети видны DNS-слою', () {
    const dnsOn = RuleDns(enabled: true, serverTag: 'google_udp');

    test('только network_type или network_is_expensive → DNS-способно', () {
      expect(
        CustomRuleTree.flat(name: 'c', networkTypes: ['cellular'], dns: dnsOn)
            .dnsMirrorActive,
        true,
      );
      expect(
        CustomRuleTree.flat(name: 'm', networkIsExpensive: true, dns: dnsOn)
            .dnsLayerEligible,
        true,
      );
      expect(
        CustomRuleTree.flat(
                name: 'ip+c',
                ipCidrs: ['10.0.0.0/8'],
                networkTypes: ['cellular'],
                dns: dnsOn)
            .dnsLayerEligible,
        true,
        reason: 'набор с network_type ядро не считает «только IP»',
      );
    });

    test('srs-зеркало несёт network_type / network_is_expensive', () {
      final reg = RuleSetRegistry();
      final srs = CustomRuleTree.flat(
        name: 'cn-list',
        srsUrl: 'https://e/cn.srs',
        networkTypes: ['cellular'],
        networkIsExpensive: true,
        outbound: 'vpn-2',
        dns: dnsOn,
      );
      final result = applyAllCustomRules(reg, [srs], const [],
          srsPaths: {CustomRuleTree.cacheIdFor(srs.id, srs.srsUrl): '/tmp/cn.srs'});
      final m = result.dnsMirrors.single;
      expect(m.body['network_type'], ['cellular']);
      expect(m.body['network_is_expensive'], true);
    });
  });

  group('applyAllCustomRules — сбор mirror-группы', () {
    test('inline+dns: mirror шарит inline-набор, wifi/приложение ключами (§757)',
        () {
      final reg = RuleSetRegistry();
      final result = applyAllCustomRules(
        reg,
        [
          CustomRuleTree.flat(
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
      // §757 — в наборе только домен; приложение и Wi-Fi — на маршрутном
      // правиле и ключами в зеркале.
      expect(m.body, {
        'rule_set': 'tg-via-vpn',
        'package_name': ['org.telegram.messenger'],
        'wifi_ssid': ['HomeWifi'],
      });
      expect(reg.getRuleSets().single['rules'], [
        {
          'domain_suffix': ['telegram.org'],
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
      final srs = CustomRuleTree.flat(
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
        srsPaths: {CustomRuleTree.cacheIdFor(srs.id, srs.srsUrl): '/tmp/cn.srs'},
      );

      expect(reg.getRuleSets(), hasLength(1),
          reason: 'no split — только .srs rule_set, без дополнительного');
      final m = result.dnsMirrors.single;
      expect(m.body['rule_set'], 'cn-list:cn');
      expect(m.body['package_name'], ['com.app']);
      expect(m.serverTag, 'cloudflare_udp');
    });

    // §256 — srs + Force IPv4: serverless-mirror с .srs-тегом.
    test('srs+forceIpv4 → serverless-mirror ссылается на .srs-тег', () {
      final reg = RuleSetRegistry();
      final srs = CustomRuleTree.flat(
        name: 'cn-list',
        srsUrl: 'https://e/cn.srs',
        outbound: 'vpn-2',
        dns: const RuleDns(forceIpv4: true),
      );
      final result = applyAllCustomRules(
        reg,
        [srs],
        const [],
        srsPaths: {CustomRuleTree.cacheIdFor(srs.id, srs.srsUrl): '/tmp/cn.srs'},
      );
      final m = result.dnsMirrors.single;
      expect(m.serverless, true);
      expect(m.serverTag, '');
      expect(m.body, {
        'rule_set': 'cn-list:cn',
        'ip_version': 6,
        'action': 'predefined',
        'rcode': 'NOERROR',
      });
    });

    test('§755: ports — порт на маршрутном правиле, набор без порта, mirror собирается',
        () {
      final reg = RuleSetRegistry();
      final result = applyAllCustomRules(
        reg,
        [
          CustomRuleTree.flat(
            name: 'gated',
            domains: ['a.com'],
            ports: ['443'],
            portRanges: ['8000:8100'],
            outbound: 'vpn-1',
            dns: const RuleDns(enabled: true, serverTag: 'google_udp'),
          ),
        ],
        const [],
      );
      expect(result.dnsMirrors.single.body, {'rule_set': 'gated'});
      final route = reg.getRules().single;
      expect(route['rule_set'], 'gated');
      expect(route['port'], [443]);
      expect(route['port_range'], ['8000:8100']);
      final set = reg.getRuleSets().single;
      expect(set['rules'], [
        {'domain': ['a.com']},
      ], reason: 'порты не в наборе');
    });

    test('§755: правило только с портами — маршрут без rule_set, DNS не трогает',
        () {
      final reg = RuleSetRegistry();
      final result = applyAllCustomRules(
        reg,
        [
          CustomRuleTree.flat(
            name: 'ports-only',
            ports: ['22'],
            outbound: 'direct-out',
            dns: const RuleDns(blockHttps: true, forceIpv4: true),
          ),
        ],
        const [],
      );
      expect(reg.getRuleSets(), isEmpty);
      expect(reg.getRules().single, {'port': [22], 'outbound': 'direct-out'});
      expect(result.dnsMirrors, isEmpty);
    });

    // §755 — Block HTTPS/SVCB records.
    test('blockHttps inline: Block HTTPS → Force IPv4 → сервер, network не гейтит',
        () {
      final reg = RuleSetRegistry();
      final result = applyAllCustomRules(
        reg,
        [
          CustomRuleTree.flat(
            name: 'rt',
            domainSuffixes: ['rutracker.org'],
            network: ['tcp', 'udp'],
            outbound: 'vpn-1',
            dns: const RuleDns(
                enabled: true,
                serverTag: 'google_udp',
                forceIpv4: true,
                blockHttps: true),
          ),
        ],
        const [],
      );
      final ms = result.dnsMirrors;
      expect(ms, hasLength(3));
      expect(ms[0].blockHttps, true);
      expect(ms[0].serverless, true);
      expect(ms[0].body, {
        'rule_set': 'rt',
        'query_type': ['HTTPS', 'SVCB'],
        'action': 'predefined',
        'rcode': 'NOERROR',
      });
      expect(ms[1].body['ip_version'], 6);
      expect(ms[1].blockHttps, false);
      expect(ms[2].serverTag, 'google_udp');
    });

    test('blockHttps без доменов не эмитится (значение в хранилище остаётся)',
        () {
      final rule = CustomRuleTree.flat(
        name: 'apps',
        packages: ['com.android.chrome'],
        outbound: 'vpn-1',
        dns: const RuleDns(blockHttps: true),
      );
      expect(rule.blockHttpsActive, false);
      final result =
          applyAllCustomRules(RuleSetRegistry(), [rule], const []);
      expect(result.dnsMirrors, isEmpty);
      expect(_storageRoundTrip(rule).dns!.blockHttps, true);
    });

    test('blockHttps srs и Fixed IP: глушилка первой, Fixed IP следом', () {
      final srs = CustomRuleTree.flat(
        name: 'cf',
        srsUrl: 'https://e/cf.srs',
        outbound: 'vpn-1',
        dns: const RuleDns(blockHttps: true, fixedIps: ['10.0.0.1']),
      );
      final result = applyAllCustomRules(
        RuleSetRegistry(),
        [srs],
        const [],
        srsPaths: {CustomRuleTree.cacheIdFor(srs.id, srs.srsUrl): '/tmp/cf.srs'},
      );
      final ms = result.dnsMirrors;
      expect(ms.first.blockHttps, true);
      expect(ms.first.body['rule_set'], 'cf:cf');
      expect(ms.first.body['query_type'], ['HTTPS', 'SVCB']);
      expect(ms.skip(1).every((m) => m.fixedAnswer), true);
    });

    test('blockHttps round-trip записи rules[]; нет ключа → false', () {
      final rule = CustomRuleTree.flat(
        name: 'b',
        domains: ['a.com'],
        outbound: 'vpn-1',
        dns: const RuleDns(blockHttps: true),
      );
      expect(_storageRoundTrip(rule).dns!.blockHttps, true);
      expect(RuleDns.fromJson({'enabled': false})!.blockHttps, false);
      expect(const RuleDns(blockHttps: true).toJson()['blockHttps'], true);
      expect(const RuleDns().toJson().containsKey('blockHttps'), false);
    });

    // §256 — Force IPv4: serverless AAAA-глушилка.
    test('forceIpv4 inline → serverless-mirror {ip_version:6, predefined}',
        () {
      final reg = RuleSetRegistry();
      final result = applyAllCustomRules(
        reg,
        [
          CustomRuleTree.flat(
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
          CustomRuleTree.flat(
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
          CustomRuleTree.flat(
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
      // §757 — набора нет; приложение — ключом зеркала.
      expect(m.body['package_name'], ['com.buggy.ipv6']);
      expect(m.body.containsKey('rule_set'), false);
    });

    test('§755: forceIpv4 + ports → serverless-mirror собирается, набор без порта', () {
      final reg = RuleSetRegistry();
      final result = applyAllCustomRules(
        reg,
        [
          CustomRuleTree.flat(
            name: 'p',
            domains: ['a.com'],
            ports: ['443'],
            outbound: 'vpn-1',
            dns: const RuleDns(forceIpv4: true),
          ),
        ],
        const [],
      );
      expect(result.dnsMirrors.single.body['ip_version'], 6);
    });

    test('порядок группы = порядок routing-правил (preset + rule)', () {
      final reg = RuleSetRegistry();
      final result = applyAllCustomRules(
        reg,
        [
          CustomRuleTree.flat(
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
          CustomRuleTree.flat(
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
      expect(result.dnsMirrors[1].body['server'], 'ru-direct:yandex_udp');
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

    // §593 — запись пресета с `enabled: false` из старого хранения не гасит
    // DNS пресета: им управляет `dns_enable` (через наличие mirror-записей).
    test('старая запись пресета с enabled:false — группа эмитится', () async {
      final legacy = dnsRuleFromRecord(
          {'kind': 'preset', 'ref': 'ru-direct', 'enabled': false}).value!;
      await SettingsStorage.saveDnsRulesList([legacy]);

      final config = <String, dynamic>{};
      await applyCustomDns(
        config,
        {'servers': [], 'rules': []},
        activePresetIdsWithDnsRule: const {'ru-direct'},
        dnsMirrors: const [
          DnsMirrorEntry(
            presetId: 'ru-direct',
            ruleName: 'ru',
            body: {
              'rule_set': ['ru-domains'],
              'action': 'predefined',
              'rcode': 'NOERROR',
            },
          ),
        ],
      );

      final dns = config['dns'] as Map<String, dynamic>;
      expect(dns['rules'], [
        {
          'rule_set': ['ru-domains'],
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
        const DnsRulePreset(presetId: 'ru-direct'),
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
        const DnsRuleInline(
          name: 'user-first',
          rule: {'domain': ['x.com'], 'server': 'google_udp'},
        ),
        const DnsRulePreset(presetId: 'ru-direct'),
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
        const DnsServerTemplate(enabled: false, tag: 'google_udp'),
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
        const DnsRulePreset(presetId: 'p1'),
        const DnsRuleInline(
          name: 'user-mid',
          rule: {'domain': ['x.com'], 'server': 's'},
        ),
        const DnsRulePreset(presetId: 'p2'),
      ]);

      final resolved = await resolveDnsRulesList(
        templateRules: const [],
        activePresetIdsWithDnsRule: const {'p1', 'p2'},
      );

      expect(
        [for (final e in resolved) e.kind],
        ['preset', 'preset', 'inline'],
        reason: 'standalone-запись не может стоять внутри группы',
      );
      expect((resolved[0] as DnsRulePreset).presetId, 'p1');
      expect((resolved[1] as DnsRulePreset).presetId, 'p2');
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
