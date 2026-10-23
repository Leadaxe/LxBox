import 'package:flutter_test/flutter_test.dart';

import 'package:lxbox/screens/dns_settings_screen/dns_server_resolver.dart';
import 'package:lxbox/screens/dns_settings_screen/resolved_server.dart';

/// §682 — предупреждение у Default Domain Resolver: резолвер через туннель.
void main() {
  ResolvedServer s(
    String tag,
    Map<String, dynamic> body, {
    bool enabled = true,
  }) => ResolvedServer(
    kind: ServerKind.inline,
    tag: tag,
    description: '',
    enabled: enabled,
    body: {...body, 'tag': tag},
  );

  final direct = s('direct', {'type': 'udp', 'server': '1.1.1.1'});
  final directOut = s('direct_out', {
    'type': 'udp',
    'server': '1.1.1.1',
    'detour': 'direct-out',
  });
  final vpn1 = s('vpn1', {
    'type': 'tls',
    'server': '9.9.9.9',
    'detour': 'vpn-1',
  });
  final vpn2 = s('vpn2', {
    'type': 'tls',
    'server': '8.8.8.8',
    'detour': 'vpn-2',
  });
  final vpnOff = s('vpn_off', {
    'type': 'tls',
    'detour': 'vpn-3',
  }, enabled: false);
  final directOff = s('direct_off', {'type': 'udp'}, enabled: false);
  ResolvedServer group(String tag, List<String> members) =>
      s(tag, {'type': 'group', 'servers': members, 'mode': 'fastest'});

  final all = [direct, directOut, vpn1, vpn2, vpnOff, directOff];

  test('одиночный: прямой и direct-out — нет, с detour — тег', () {
    expect(defaultResolverTunnelDetour('direct', all), isNull);
    expect(defaultResolverTunnelDetour('direct_out', all), isNull);
    expect(defaultResolverTunnelDetour('vpn1', all), 'vpn-1');
  });

  test('неизвестный тег — нет', () {
    expect(defaultResolverTunnelDetour('missing', all), isNull);
  });

  test('группа: все эмитируемые с detour — тег первого', () {
    final g = group('g', ['vpn2', 'vpn1', 'direct_off', 'missing']);
    expect(defaultResolverTunnelDetour('g', [...all, g]), 'vpn-2');
  });

  test('группа: хоть один прямой эмитируемый член — нет', () {
    final g = group('g', ['vpn1', 'direct_out']);
    expect(defaultResolverTunnelDetour('g', [...all, g]), isNull);
  });

  test('группа: выключенный член не считается', () {
    final g = group('g', ['vpn_off', 'direct']);
    expect(defaultResolverTunnelDetour('g', [...all, g]), isNull);
    final g2 = group('g2', ['vpn_off']);
    expect(defaultResolverTunnelDetour('g2', [...all, g2]), isNull);
  });
}
