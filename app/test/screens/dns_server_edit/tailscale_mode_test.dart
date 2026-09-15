import 'package:flutter_test/flutter_test.dart';

import 'package:lxbox/models/dns_ref.dart';
import 'package:lxbox/screens/dns_server_edit/edit_controller.dart';
import 'package:lxbox/services/dns/node_dns_records.dart';

/// §435 — `DnsServerEditController` в режиме `tailscale` (спека §9.4,
/// NODE_SECTIONS.md §6): тело `{type: tailscale, endpoint, accept_default_
/// resolvers?}` без `server`/`detour`; переходы udp↔tailscale↔group чистят
/// чужие поля; JSON-вкладка отражается в геттерах формы.
/// Тело inline-сервера снимка контроллера (модель, не форма хранения).
Map<String, dynamic> bodyOf(DnsServerEditController c) =>
    (c.snapshot() as DnsServerInline).body;

void main() {
  DnsServerEditController makeUdp() => DnsServerEditController(
        initialRef: const DnsServerInline(
          enabled: true,
          tag: 'dns_new',
          body: {
            'type': 'udp',
            'server': '1.1.1.1',
            'server_port': 5353,
            'detour': 'vpn-1',
            'domain_resolver': 'google_udp',
          },
        ),
        tailscaleEndpoints: const [
          TailscaleEndpointOption(tag: 'home-ts', enabled: true),
          TailscaleEndpointOption(tag: 'P off-ts', enabled: false),
        ],
      );

  test('tailscale входит в kDnsServerModes и в безадресные режимы', () {
    expect(kDnsServerModes, contains('tailscale'));
    expect(kDnsAddresslessModes, containsAll(['group', 'tailscale']));
  });

  test('udp → tailscale: транспорт/detour/domain_resolver чистятся', () {
    final c = makeUdp();
    c.setServerMode('tailscale');
    expect(c.serverMode, 'tailscale');
    expect(c.isTailscale, isTrue);
    expect(c.isGroup, isFalse);
    expect(bodyOf(c), {'type': 'tailscale'});
    expect(c.addressCtrl.text, '');
    expect(c.portCtrl.text, '');
    expect(c.tailscaleEndpoint, '');
    expect(c.acceptDefaultResolvers, isFalse);
    // JSON-вкладка синхронизирована.
    expect(c.bodyCtrl.text, contains('"type": "tailscale"'));
    expect(c.bodyCtrl.text, isNot(contains('detour')));
    c.dispose();
  });

  test('endpoint / accept_default_resolvers пишутся в body и в JSON', () {
    final c = makeUdp();
    c.setServerMode('tailscale');
    c.setTailscaleEndpoint('home-ts');
    expect(c.tailscaleEndpoint, 'home-ts');
    expect(bodyOf(c), {'type': 'tailscale', 'endpoint': 'home-ts'});

    c.setAcceptDefaultResolvers(true);
    expect(c.acceptDefaultResolvers, isTrue);
    expect(bodyOf(c), {
      'type': 'tailscale',
      'endpoint': 'home-ts',
      'accept_default_resolvers': true,
    });
    expect(c.bodyCtrl.text, contains('"accept_default_resolvers": true'));

    // false → ключ уходит (дефолт ядра), пустой endpoint → ключ уходит.
    c.setAcceptDefaultResolvers(false);
    c.setTailscaleEndpoint('  ');
    expect(bodyOf(c), {'type': 'tailscale'});
    expect(c.isDirty(), isTrue);
    c.dispose();
  });

  test('tailscale → udp: endpoint/accept_default_resolvers чистятся', () {
    final c = makeUdp();
    c.setServerMode('tailscale');
    c.setTailscaleEndpoint('home-ts');
    c.setAcceptDefaultResolvers(true);
    c.setServerMode('udp');
    expect(c.serverMode, 'udp');
    expect(c.isTailscale, isFalse);
    expect(bodyOf(c), {'type': 'udp'});
    expect(c.tailscaleEndpoint, '');
    expect(c.acceptDefaultResolvers, isFalse);
    c.dispose();
  });

  test('tailscale ↔ group: чужие ключи не переезжают', () {
    final c = makeUdp();
    c.setServerMode('tailscale');
    c.setTailscaleEndpoint('home-ts');
    c.setAcceptDefaultResolvers(true);

    c.setServerMode('group');
    expect(c.isGroup, isTrue);
    expect(bodyOf(c), {'type': 'group', 'servers': <String>[]});

    c.toggleGroupMember('cloudflare_udp', true);
    c.setGroupMode('fastest');
    c.onErrorTtlChanged('2m');
    c.setServerMode('tailscale');
    expect(c.isTailscale, isTrue);
    expect(bodyOf(c), {'type': 'tailscale'});
    expect(c.errorTtlCtrl.text, '');
    expect(c.groupMembers, isEmpty);
    c.dispose();
  });

  test('JSON-edit → геттеры формы (endpoint, accept_default_resolvers)', () {
    final c = makeUdp();
    c.onBodyTextChanged(
        '{"type":"tailscale","endpoint":"P off-ts","accept_default_resolvers":true,"tag":"ts_dns"}');
    expect(c.jsonError, isNull);
    expect(c.serverMode, 'tailscale');
    expect(c.isTailscale, isTrue);
    expect(c.tailscaleEndpoint, 'P off-ts');
    expect(c.acceptDefaultResolvers, isTrue);
    expect(c.tagCtrl.text, 'ts_dns');
    // Транспортные контроллеры пусты — форма tailscale их не показывает.
    expect(c.addressCtrl.text, '');
    expect(bodyOf(c), {
      'type': 'tailscale',
      'endpoint': 'P off-ts',
      'accept_default_resolvers': true,
    });
    c.dispose();
  });

  test('существующий tailscale-сервер: не dirty при открытии, опции переданы',
      () {
    final c = DnsServerEditController(
      initialRef: const DnsServerInline(
        enabled: true,
        tag: 'ts_dns',
        body: {'type': 'tailscale', 'endpoint': 'home-ts'},
      ),
      tailscaleEndpoints: const [
        TailscaleEndpointOption(tag: 'home-ts', enabled: true),
      ],
    );
    expect(c.isTailscale, isTrue);
    expect(c.tailscaleEndpoint, 'home-ts');
    expect(c.isDirty(), isFalse);
    expect(c.tailscaleEndpoints.single.tag, 'home-ts');
    // Смена endpoint — dirty; snapshot без server/detour.
    c.setTailscaleEndpoint('other-ts');
    expect(c.isDirty(), isTrue);
    final body = bodyOf(c);
    expect(body.containsKey('server'), isFalse);
    expect(body.containsKey('detour'), isFalse);
    c.dispose();
  });

  test('в режиме tailscale detour отсутствует (пикер формой не рисуется)', () {
    // Контракт формы: пикер detour у tailscale скрыт (params_tab); вход в
    // режим снял `detour` из body, геттер отдаёт дефолт direct-out.
    final c = makeUdp();
    c.setServerMode('tailscale');
    c.setTailscaleEndpoint('home-ts');
    expect(c.inlineDetour, 'direct-out');
    expect(bodyOf(c).containsKey('detour'), isFalse);
    c.dispose();
  });
}
