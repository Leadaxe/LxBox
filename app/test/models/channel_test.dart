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

    test('§201 — includeBlock round-trip + дефолт false', () {
      const c = Channel(tag: 'vpn-2', label: 'x', includeBlock: true);
      final r = Channel.fromJson(c.toJson());
      expect(r.includeBlock, true);
      expect(c.toJson()['include_block'], true);
      // дефолт false для старых каналов без ключа
      expect(Channel.fromJson({'tag': 'vpn-1'}).includeBlock, false);
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

  group('§198 — defaultChannelLabel (цифра в кружке)', () {
    test('1..10 → VPN ①..VPN ⑩', () {
      expect(defaultChannelLabel(1), 'VPN ①');
      expect(defaultChannelLabel(2), 'VPN ②');
      expect(defaultChannelLabel(5), 'VPN ⑤');
      expect(defaultChannelLabel(10), 'VPN ⑩');
    });

    test('вне 1..10 → без кружка', () {
      expect(defaultChannelLabel(0), 'VPN 0');
      expect(defaultChannelLabel(11), 'VPN 11');
    });

    test('channelNumberOf парсит vpn-N', () {
      expect(channelNumberOf('vpn-1'), 1);
      expect(channelNumberOf('vpn-7'), 7);
      expect(channelNumberOf('vpn-1-auto'), isNull);
      expect(channelNumberOf('direct-out'), isNull);
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

  group('§208 — ChannelAuto balancer (round_robin)', () {
    test('дефолты: leastTest, pool 3, poolTolerance 0, sticky process+domain', () {
      const a = ChannelAuto();
      expect(a.mode, UrltestMode.leastTest);
      expect(a.pool, 3);
      expect(a.poolTolerance, 0);
      expect(a.stickyHash, [StickyHashKey.process, StickyHashKey.domain]);
    });

    test('старый JSON без mode/balancer → дефолты (обратная совместимость)', () {
      final a = ChannelAuto.fromJson({
        'url': 'https://x/204',
        'interval': '5m',
        'tolerance': 50,
        'idle_timeout': '30m',
        'interrupt_exist_connections': false,
      });
      expect(a.mode, UrltestMode.leastTest);
      expect(a.pool, 3);
      expect(a.poolTolerance, 0);
      expect(a.stickyHash, kDefaultStickyHash);
    });

    test('round_robin полный round-trip через JSON', () {
      const a = ChannelAuto(
        mode: UrltestMode.roundRobin,
        pool: 5,
        poolTolerance: 80,
        stickyHash: [StickyHashKey.domain, StickyHashKey.destIp],
      );
      final r = ChannelAuto.fromJson(a.toJson());
      expect(r.mode, UrltestMode.roundRobin);
      expect(r.pool, 5);
      expect(r.poolTolerance, 80);
      expect(r.stickyHash, [StickyHashKey.domain, StickyHashKey.destIp]);
    });

    test('toJson — mode в корне, balancer вложен', () {
      const a = ChannelAuto(
        mode: UrltestMode.roundRobin,
        pool: 4,
        poolTolerance: 10,
        stickyHash: [StickyHashKey.process],
      );
      final j = a.toJson();
      expect(j['mode'], 'round_robin');
      final bal = j['balancer'] as Map<String, dynamic>;
      expect(bal['pool'], 4);
      expect(bal['pool_tolerance'], 10);
      expect(bal['sticky_hash'], ['process']);
    });

    test('явный sticky_hash [] → пустой список (липкость выкл)', () {
      // round-trip пустого набора: [] остаётся [], НЕ дефолтится.
      const a = ChannelAuto(
          mode: UrltestMode.roundRobin, stickyHash: <StickyHashKey>[]);
      final r = ChannelAuto.fromJson(a.toJson());
      expect(r.stickyHash, isEmpty);
      expect((a.toJson()['balancer'] as Map)['sticky_hash'], isEmpty);
    });

    test('pool clamp: 0/отриц → 1', () {
      expect(ChannelAuto.fromJson({
        'balancer': {'pool': 0}
      }).pool, 1);
      expect(ChannelAuto.fromJson({
        'balancer': {'pool': -3}
      }).pool, 1);
      expect(const ChannelAuto().copyWith(pool: 0).pool, 1);
    });

    test('poolTolerance clamp как tolerance (uint16)', () {
      expect(ChannelAuto.fromJson({
        'balancer': {'pool_tolerance': 999999}
      }).poolTolerance, 65535);
      expect(ChannelAuto.fromJson({
        'balancer': {'pool_tolerance': -5}
      }).poolTolerance, 0);
    });

    test('неизвестный sticky-компонент отбрасывается', () {
      final a = ChannelAuto.fromJson({
        'balancer': {
          'sticky_hash': ['process', 'bogus', 'dest_port']
        }
      });
      expect(a.stickyHash, [StickyHashKey.process, StickyHashKey.destPort]);
    });

    test('enum wire-мэппинг обе стороны', () {
      expect(UrltestMode.leastTest.wire, 'least_test');
      expect(UrltestMode.roundRobin.wire, 'round_robin');
      expect(UrltestMode.fromWire('round_robin'), UrltestMode.roundRobin);
      expect(UrltestMode.fromWire('garbage'), UrltestMode.leastTest); // дефолт
      expect(StickyHashKey.sourceIp.wire, 'source_ip');
      expect(StickyHashKey.fromWire('dest_port'), StickyHashKey.destPort);
      expect(StickyHashKey.fromWire('nope'), isNull);
    });

    test('copyWith балансер-поля', () {
      const a = ChannelAuto();
      final n = a.copyWith(
        mode: UrltestMode.roundRobin,
        pool: 7,
        poolTolerance: 25,
        stickyHash: [StickyHashKey.destPort],
      );
      expect(n.mode, UrltestMode.roundRobin);
      expect(n.pool, 7);
      expect(n.poolTolerance, 25);
      expect(n.stickyHash, [StickyHashKey.destPort]);
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
