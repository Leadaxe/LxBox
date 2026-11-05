import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:lxbox/models/custom_rule.dart';
import 'package:lxbox/models/parser_config.dart';
import 'package:lxbox/services/builder/preset_expand.dart';
import 'package:lxbox/services/builder/preset_node_loop.dart';

/// Пресет `tunnel-routes` шаблона: в клиентский туннель с полем записи
/// `own_routes` идут только его собственные сети (`preferred_by`); у
/// OpenVPN/OpenConnect ещё resolve-правило, DNS-сервер туннеля и DNS-правило.
void main() {
  late SelectableRule preset;

  setUpAll(() {
    final doc = jsonDecode(File('assets/wizard_template.json').readAsStringSync())
        as Map<String, dynamic>;
    final json = (doc['selectable_rules'] as List)
        .cast<Map<String, dynamic>>()
        .singleWhere((p) => p['preset_id'] == 'tunnel-routes');
    preset = SelectableRule.fromJson(json);
  });

  PresetFragments run(List<PresetNode> nodes, {bool dns = true}) =>
      expandPreset(
        CustomRulePreset(
          name: 'Tunnel routes',
          presetId: 'tunnel-routes',
          varsValues: {'dns_enable': '$dns'},
        ),
        preset,
        nodes: nodes,
      );

  const wg = PresetNode(
    tag: 'lab-wg',
    body: {'type': 'wireguard'},
    ownRoutes: true,
  );
  const ovpn = PresetNode(
    tag: 'office-ovpn',
    body: {'type': 'openvpn-client'},
    ownRoutes: true,
  );

  test('поле в закрытом перечне полей записи', () {
    expect(kPresetNodeRecordFieldNames, contains('own_routes'));
    expect(wg.recordField('own_routes'), isTrue);
  });

  test('WireGuard с флагом: одно правило preferred_by → узел', () {
    final f = run([wg]);
    expect(f.routingRules, [
      {
        'preferred_by': ['lab-wg'],
        'outbound': 'lab-wg',
      },
    ]);
    expect(f.dnsServers, isEmpty);
    expect(f.dnsRules, isEmpty);
  });

  test('OpenVPN с флагом: resolve, маршрут, DNS-сервер openvpn, DNS-правило',
      () {
    final f = run([ovpn, wg]);
    expect(f.routingRules, [
      {
        'preferred_by': ['office-ovpn'],
        'action': 'resolve',
        'server': 'office-ovpn-dns',
      },
      {
        'preferred_by': ['office-ovpn'],
        'outbound': 'office-ovpn',
      },
      {
        'preferred_by': ['lab-wg'],
        'outbound': 'lab-wg',
      },
    ]);
    expect(f.dnsServers, [
      {
        'type': 'openvpn',
        'tag': 'office-ovpn-dns',
        'endpoint': 'office-ovpn',
        'description': 'DNS announced by the tunnel',
      },
    ]);
    expect(f.dnsRules, [
      {
        'preferred_by': ['office-ovpn-dns'],
        'server': 'office-ovpn-dns',
      },
    ]);
  });

  test('флаг выключен — пресет ничего не выдаёт', () {
    final f = run(const [
      PresetNode(tag: 'lab-wg', body: {'type': 'wireguard'}),
      PresetNode(tag: 'office-ovpn', body: {'type': 'openvpn-client'}),
    ]);
    expect(f.routingRules, isEmpty);
    expect(f.dnsServers, isEmpty);
    expect(f.dnsRules, isEmpty);
  });

  test('dns_enable выключен — только правила маршрута', () {
    final f = run([ovpn], dns: false);
    expect(f.routingRules, [
      {
        'preferred_by': ['office-ovpn'],
        'outbound': 'office-ovpn',
      },
    ]);
    expect(f.dnsServers, isEmpty);
    expect(f.dnsRules, isEmpty);
  });
}
