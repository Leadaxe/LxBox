import 'package:flutter_test/flutter_test.dart';
import 'package:lxbox/models/channel.dart';
import 'package:lxbox/models/parser_config.dart';

void main() {
  group('Channel JSON round-trip', () {
    test('full channel with auto → JSON → Channel', () {
      const original = Channel(
        tag: 'vpn-2',
        label: 'Стриминг',
        enabled: false,
        includeDirect: true,
        nodeFilter: '🇩🇪|🇳🇱',
        defaultFilter: 'Premium',
        interruptExistConnections: false,
        auto: ChannelAuto(
          url: 'https://example.com/generate_204',
          interval: '3m',
          tolerance: 30,
          idleTimeout: '20m',
          interruptExistConnections: true,
        ),
      );

      final restored = Channel.fromJson(original.toJson());

      expect(restored.tag, 'vpn-2');
      expect(restored.label, 'Стриминг');
      expect(restored.enabled, false);
      expect(restored.includeDirect, true);
      expect(restored.nodeFilter, '🇩🇪|🇳🇱');
      expect(restored.defaultFilter, 'Premium');
      expect(restored.interruptExistConnections, false);
      expect(restored.auto, isNotNull);
      expect(restored.auto!.url, 'https://example.com/generate_204');
      expect(restored.auto!.interval, '3m');
      expect(restored.auto!.tolerance, 30);
      expect(restored.auto!.idleTimeout, '20m');
      expect(restored.auto!.interruptExistConnections, true);
    });

    test('§197 — nodeFilterInvert round-trip', () {
      const c = Channel(
          tag: 'vpn-2', label: 'x', nodeFilter: 'bypass', nodeFilterInvert: true);
      final r = Channel.fromJson(c.toJson());
      expect(r.nodeFilterInvert, true);
      expect(r.nodeFilter, 'bypass');
      expect(c.toJson()['node_filter_invert'], true);
    });

    test('§197 — nodeFilterInvert дефолт false для старых каналов', () {
      final c = Channel.fromJson({'tag': 'vpn-1', 'node_filter': 'x'});
      expect(c.nodeFilterInvert, false);
    });

    test('auto == null survives round-trip (галка ВЫКЛ)', () {
      const original = Channel(tag: 'vpn-3', label: 'VPN ③');
      final json = original.toJson();
      expect(json['auto'], isNull);
      final restored = Channel.fromJson(json);
      expect(restored.auto, isNull);
    });

    test('defaults applied on missing keys', () {
      final c = Channel.fromJson({'tag': 'vpn-5'});
      expect(c.label, 'vpn-5'); // label fallback к tag
      expect(c.enabled, true);
      expect(c.includeDirect, false);
      expect(c.nodeFilter, '');
      expect(c.defaultFilter, '');
      expect(c.interruptExistConnections, true);
      expect(c.auto, isNull);
    });
  });

  group('Channel computed', () {
    test('autoTag производный, не из storage', () {
      const c = Channel(tag: 'vpn-4', label: 'x');
      expect(c.autoTag, 'vpn-4-auto');
      expect(c.toJson().containsKey('auto_tag'), false);
    });

    test('isRequired только для vpn-1', () {
      expect(const Channel(tag: 'vpn-1', label: 'x').isRequired, true);
      expect(const Channel(tag: 'vpn-2', label: 'x').isRequired, false);
    });
  });

  group('ChannelAuto tolerance clamp (§161 uint16)', () {
    test('из JSON выше 65535 → clamp', () {
      final a = ChannelAuto.fromJson({'tolerance': 999999});
      expect(a.tolerance, 65535);
    });

    test('отрицательный → 0', () {
      final a = ChannelAuto.fromJson({'tolerance': -5});
      expect(a.tolerance, 0);
    });

    test('copyWith тоже clamp', () {
      const a = ChannelAuto();
      expect(a.copyWith(tolerance: 70000).tolerance, 65535);
      expect(a.copyWith(tolerance: 100).tolerance, 100);
    });

    test('toJson переклампливает на всякий случай', () {
      // конструктор не клампит (const), но toJson — да
      const a = ChannelAuto(tolerance: 80000);
      expect(a.toJson()['tolerance'], 65535);
    });
  });

  group('Channel.copyWith', () {
    test('tag immutable, меняем только label', () {
      const c = Channel(tag: 'vpn-2', label: 'old');
      final n = c.copyWith(label: 'new');
      expect(n.tag, 'vpn-2');
      expect(n.label, 'new');
    });

    test('clearAuto убирает auto', () {
      const c = Channel(tag: 'vpn-2', label: 'x', auto: ChannelAuto());
      expect(c.copyWith(clearAuto: true).auto, isNull);
    });

    test('auto сохраняется если не трогали', () {
      const c = Channel(tag: 'vpn-2', label: 'x', auto: ChannelAuto());
      expect(c.copyWith(label: 'y').auto, isNotNull);
    });
  });

  group('Channel.seedFromPreset (миграция)', () {
    test('структурные поля из пресета', () {
      final p = PresetGroup(
        tag: 'vpn-1',
        type: 'selector',
        label: 'Главный',
        addOutbounds: const ['direct-out'],
        options: const {'interrupt_exist_connections': true},
      );
      final c = Channel.seedFromPreset(p, enabled: true);
      expect(c.tag, 'vpn-1');
      expect(c.label, 'Главный');
      expect(c.includeDirect, true);
      expect(c.interruptExistConnections, true);
      expect(c.nodeFilter, '');
      expect(c.defaultFilter, ''); // Решение 6
      expect(c.auto, isNull);
    });

    test('label fallback к tag когда пусто', () {
      final p = PresetGroup(tag: 'vpn-3', type: 'selector');
      final c = Channel.seedFromPreset(p, enabled: false);
      expect(c.label, 'vpn-3');
      expect(c.includeDirect, false);
    });
  });
}
