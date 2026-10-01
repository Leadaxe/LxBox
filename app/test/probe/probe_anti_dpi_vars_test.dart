import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:lxbox/models/node_spec.dart';
import 'package:lxbox/models/template_vars.dart';
import 'package:lxbox/models/tls_spec.dart';
import 'package:lxbox/services/builder/post_steps.dart';
import 'package:lxbox/services/probe/probe_config.dart';

import '../parser/engine_test_setup.dart';

/// §606 (решение владельца) — probe-конфиг применяет те же anti-DPI-шаги,
/// что туннель: фрагментацию TLS и mixed-case SNI. Иначе «пинг есть, VPN нет»
/// (§363). Уступка fragment перед detour (§574) сохраняется.
void main() {
  setUpAll(loadEngineSections);

  const uuid = '11111111-2222-3333-4444-555555555555';
  const vars = {
    'tls_fragment': 'true',
    'tls_record_fragment': 'true',
    'tls_fragment_fallback_delay': '700ms',
    'tls_mixed_case_sni': 'true',
  };

  VlessSpec vless(String tag, {NodeSpec? chained}) => VlessSpec(
        id: tag,
        tag: tag,
        label: tag,
        server: 'h.example',
        port: 443,
        rawSource: '',
        uuid: uuid,
        tls: const TlsSpec(
            enabled: true, serverName: 'www.long-server-name.example'),
        chained: chained,
      );

  Map<String, dynamic> outboundOf(ProbeConfig cfg, String tag) =>
      ((jsonDecode(cfg.configJson!) as Map)['outbounds'] as List)
          .cast<Map<String, dynamic>>()
          .firstWhere((o) => o['tag'] == tag);

  /// Туннельные post-steps над тем же телом узла.
  Map<String, dynamic> tunnelTls(NodeSpec node) {
    final ob = jsonDecode(jsonEncode(node.emit(TemplateVars.empty).map))
        as Map<String, dynamic>;
    final config = <String, dynamic>{
      'outbounds': [ob],
    };
    applyTlsFragment(config, vars);
    applyMixedCaseSni(config, vars);
    return ob['tls'] as Map<String, dynamic>;
  }

  test('probe несёт те же поля tls, что туннель', () {
    final node = vless('Main');
    final cfg = buildProbeConfig([node], vars: vars);
    final probeTls = Map<String, dynamic>.of(
        outboundOf(cfg, cfg.tagByIndex[0]!)['tls'] as Map<String, dynamic>);
    final tunnel = Map<String, dynamic>.of(tunnelTls(node));

    expect(probeTls['fragment'], true);
    expect(probeTls['record_fragment'], true);
    expect(probeTls['fragment_fallback_delay'], '700ms');
    // Регистр SNI случаен у каждой сборки — сравниваем без регистра.
    final sni = probeTls.remove('server_name') as String;
    expect(sni.toLowerCase(), 'www.long-server-name.example');
    expect((tunnel.remove('server_name') as String).toLowerCase(),
        sni.toLowerCase());
    expect(probeTls, tunnel);
  });

  test('mixed-case SNI в пробе действительно меняет регистр', () {
    // ~24 буквы × 20 прогонов: шанс, что регистр ни разу не сменится, ничтожен.
    final changed = List.generate(20, (_) {
      final cfg = buildProbeConfig([vless('Main')], vars: vars);
      final tls = outboundOf(cfg, cfg.tagByIndex[0]!)['tls'] as Map;
      return tls['server_name'] != 'www.long-server-name.example';
    }).any((c) => c);
    expect(changed, isTrue);
  });

  test('без переменных — как до §606', () {
    final cfg = buildProbeConfig([vless('Main')]);
    final tls = outboundOf(cfg, cfg.tagByIndex[0]!)['tls'] as Map;
    expect(tls.containsKey('fragment'), isFalse);
    expect(tls['server_name'], 'www.long-server-name.example');
  });

  test('§574: у узла с detour fragment нет, у первого хопа есть', () {
    final cfg = buildProbeConfig([vless('Main', chained: vless('Hop'))],
        vars: vars);
    final main = outboundOf(cfg, cfg.tagByIndex[0]!);
    expect(main['detour'], isNotNull);
    expect((main['tls'] as Map).containsKey('fragment'), isFalse);
    final hop = outboundOf(cfg, main['detour'] as String);
    expect((hop['tls'] as Map)['fragment'], true);
  });
}
