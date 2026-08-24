import 'package:flutter_test/flutter_test.dart';
import 'package:lxbox/models/direction.dart';
import 'package:lxbox/screens/routing_screen/routing_screen_helpers.dart';

/// §248/§274 — outbound-опции экрана Routing
/// ([RoutingHelpers.outboundOptions]): detour-Направление — валидная цель
/// правил/route final (§274 снял исключение §248), label = displayLabel
/// (⚙-префикс у detour); direct первый, block последний (§201, danger).
void main() {
  test('§274 — detour-Направление попадает в опции с ⚙-префиксом, порядок сохранён',
      () {
    final opts = RoutingHelpers.outboundOptions(const [
      Direction(tag: 'vpn-1', label: 'Main'),
      Direction(tag: 'vpn-2', label: 'Relay', isDetour: true),
      Direction(tag: 'vpn-3', label: 'Plain'),
    ]);
    expect(opts.map((o) => o.tag),
        ['direct-out', 'vpn-1', 'vpn-2', 'vpn-3', 'block']);
    // Label detour-Направления — displayLabel с ⚙-префиксом.
    expect(opts.firstWhere((o) => o.tag == 'vpn-2').label, '⚙ Relay');
    // Label обычного Направления показывается как есть.
    expect(opts.firstWhere((o) => o.tag == 'vpn-3').label, 'Plain');
  });

  test('direct-out первый, block последний и danger', () {
    final opts = RoutingHelpers.outboundOptions(const [
      Direction(tag: 'vpn-1', label: 'Main'),
    ]);
    expect(opts.first.tag, 'direct-out');
    expect(opts.last.tag, 'block');
    expect(opts.last.danger, isTrue);
    expect(opts.first.danger, isFalse);
  });

  test('выключенное Направление скрыто, vpn-1 присутствует всегда (required)', () {
    final opts = RoutingHelpers.outboundOptions(const [
      // Гипотетический битый storage: даже с enabled=false vpn-1 остаётся
      // опцией (required-инвариант — резервная мишень heal-путей).
      Direction(tag: 'vpn-1', label: 'Main', enabled: false),
      Direction(tag: 'vpn-2', label: 'Off', enabled: false),
    ]);
    expect(opts.map((o) => o.tag), ['direct-out', 'vpn-1', 'block']);
  });

  test('пустой label Направления → tag вместо label', () {
    final opts = RoutingHelpers.outboundOptions(const [
      Direction(tag: 'vpn-1', label: ''),
    ]);
    expect(opts.firstWhere((o) => o.tag == 'vpn-1').label, 'vpn-1');
  });
}
