import 'package:flutter_test/flutter_test.dart';
import 'package:lxbox/models/channel.dart';
import 'package:lxbox/screens/routing_screen/routing_screen_helpers.dart';

/// §248 — outbound-опции экрана Routing ([RoutingHelpers.outboundOptions]):
/// detour-канал исключён из целей правил/route final, direct первый,
/// block последний (§201, danger).
void main() {
  test('detour-канал не попадает в опции, обычный попадает', () {
    final opts = RoutingHelpers.outboundOptions(const [
      Channel(tag: 'vpn-1', label: 'Main'),
      Channel(tag: 'vpn-2', label: 'Relay', isDetour: true),
      Channel(tag: 'vpn-3', label: 'Plain'),
    ]);
    expect(opts.map((o) => o.tag), ['direct-out', 'vpn-1', 'vpn-3', 'block']);
    // Label канала показывается как есть.
    expect(opts.firstWhere((o) => o.tag == 'vpn-3').label, 'Plain');
  });

  test('direct-out первый, block последний и danger', () {
    final opts = RoutingHelpers.outboundOptions(const [
      Channel(tag: 'vpn-1', label: 'Main'),
    ]);
    expect(opts.first.tag, 'direct-out');
    expect(opts.last.tag, 'block');
    expect(opts.last.danger, isTrue);
    expect(opts.first.danger, isFalse);
  });

  test('выключенный канал скрыт, vpn-1 присутствует всегда (required)', () {
    final opts = RoutingHelpers.outboundOptions(const [
      // Гипотетический битый storage: даже с enabled=false vpn-1 остаётся
      // опцией (required-инвариант — резервная мишень heal-путей).
      Channel(tag: 'vpn-1', label: 'Main', enabled: false),
      Channel(tag: 'vpn-2', label: 'Off', enabled: false),
    ]);
    expect(opts.map((o) => o.tag), ['direct-out', 'vpn-1', 'block']);
  });

  test('пустой label канала → tag вместо label', () {
    final opts = RoutingHelpers.outboundOptions(const [
      Channel(tag: 'vpn-1', label: ''),
    ]);
    expect(opts.firstWhere((o) => o.tag == 'vpn-1').label, 'vpn-1');
  });
}
