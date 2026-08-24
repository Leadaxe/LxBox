import 'package:flutter_test/flutter_test.dart';
import 'package:lxbox/models/direction.dart';
import 'package:lxbox/models/parser_config.dart';

void main() {
  group('Direction JSON round-trip', () {
    test('full direction with auto → JSON → Direction', () {
      const original = Direction(
        tag: 'vpn-2',
        label: 'Стриминг',
        enabled: false,
        includeDirect: true,
        nodeFilter: '🇩🇪|🇳🇱',
        defaultFilter: 'Premium',
        interruptExistConnections: false,
        auto: DirectionAuto(
          url: 'https://example.com/generate_204',
          interval: '3m',
          tolerance: 30,
          idleTimeout: '20m',
          interruptExistConnections: true,
        ),
      );

      final restored = Direction.fromJson(original.toJson());

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
      const c = Direction(tag: 'vpn-2', label: 'x', includeBlock: true);
      final r = Direction.fromJson(c.toJson());
      expect(r.includeBlock, true);
      expect(c.toJson()['include_block'], true);
      // дефолт false для старых Направлений без ключа
      expect(Direction.fromJson({'tag': 'vpn-1'}).includeBlock, false);
    });

    test('§197 — nodeFilterInvert round-trip', () {
      const c = Direction(
          tag: 'vpn-2', label: 'x', nodeFilter: 'bypass', nodeFilterInvert: true);
      final r = Direction.fromJson(c.toJson());
      expect(r.nodeFilterInvert, true);
      expect(r.nodeFilter, 'bypass');
      expect(c.toJson()['node_filter_invert'], true);
    });

    test('§197 — nodeFilterInvert дефолт false для старых Направлений', () {
      final c = Direction.fromJson({'tag': 'vpn-1', 'node_filter': 'x'});
      expect(c.nodeFilterInvert, false);
    });

    test('auto == null survives round-trip (галка ВЫКЛ)', () {
      const original = Direction(tag: 'vpn-3', label: 'VPN ③');
      final json = original.toJson();
      expect(json['auto'], isNull);
      final restored = Direction.fromJson(json);
      expect(restored.auto, isNull);
    });

    test('defaults applied on missing keys', () {
      final c = Direction.fromJson({'tag': 'vpn-5'});
      expect(c.label, 'vpn-5'); // label fallback к tag
      expect(c.enabled, true);
      expect(c.includeDirect, false);
      expect(c.nodeFilter, '');
      expect(c.defaultFilter, '');
      expect(c.interruptExistConnections, true);
      expect(c.auto, isNull);
    });
  });

  group('§393 A3 — include[]', () {
    test('round-trip: список тегов переживает toJson/fromJson', () {
      const c = Direction(
          tag: 'vpn-3', label: 'x', include: ['vpn-1', 'vpn-2']);
      final json = c.toJson();
      expect(json['include'], ['vpn-1', 'vpn-2']);
      expect(Direction.fromJson(json).include, ['vpn-1', 'vpn-2']);
    });

    test('пустой include ключа НЕ пишет (байт-совместимость §221)', () {
      const c = Direction(tag: 'vpn-1', label: 'x');
      expect(c.toJson().containsKey('include'), false);
    });

    test('отсутствие ключа на чтении = пустой список', () {
      expect(Direction.fromJson({'tag': 'vpn-1'}).include, isEmpty);
      // Не-список тоже: мусор не должен доезжать до билдера.
      expect(Direction.fromJson({'tag': 'vpn-1', 'include': 'vpn-2'}).include,
          isEmpty);
    });

    test('чтение нормализует: trim, без пустых, без дублей, без не-строк', () {
      final c = Direction.fromJson({
        'tag': 'vpn-3',
        'include': [' vpn-1 ', '', 'vpn-1', 42, 'vpn-2'],
      });
      expect(c.include, ['vpn-1', 'vpn-2']);
    });

    test('include ортогонален includeDirect/includeBlock', () {
      const c = Direction(
          tag: 'vpn-2',
          label: 'x',
          include: ['vpn-1'],
          includeDirect: true,
          includeBlock: true);
      final r = Direction.fromJson(c.toJson());
      expect(r.include, ['vpn-1']);
      expect(r.includeDirect, true);
      expect(r.includeBlock, true);
      // Служебные теги в include не дублируются.
      expect(r.include, isNot(contains('direct-out')));
      expect(r.include, isNot(contains('block')));
    });

    test('copyWith меняет include, не трогая прочее', () {
      const c = Direction(tag: 'vpn-2', label: 'x', includeDirect: true);
      final r = c.copyWith(include: ['vpn-1']);
      expect(r.include, ['vpn-1']);
      expect(r.includeDirect, true);
      expect(c.include, isEmpty); // исходный не мутирован
    });
  });

  group('§393 A3 — nextDirectionTag', () {
    test('пусто → vpn-1', () {
      expect(nextDirectionTag(const []), 'vpn-1');
    });

    test('первый свободный, а не «максимум + 1» (дыра в нумерации)', () {
      expect(nextDirectionTag(const ['vpn-1', 'vpn-3']), 'vpn-2');
      expect(nextDirectionTag(const ['vpn-2', 'vpn-3']), 'vpn-1');
    });

    test('произвольные теги нумерацию не занимают', () {
      expect(nextDirectionTag(const ['ru-exit', 'proxy-out']), 'vpn-1');
      expect(nextDirectionTag(const ['vpn-1', 'ru-exit']), 'vpn-2');
    });

    test('потолка нет: >10 выдаётся штатно', () {
      final used = [for (var i = 1; i <= 10; i++) 'vpn-$i'];
      expect(nextDirectionTag(used), 'vpn-11');
      expect(nextDirectionTag([...used, 'vpn-11', 'vpn-12']), 'vpn-13');
    });

    test('auto-двойники нумерацию не занимают (vpn-1-auto ≠ vpn-N)', () {
      expect(nextDirectionTag(const ['vpn-1-auto']), 'vpn-1');
    });
  });

  group('§393 A3 — directionTagConflict', () {
    test('свободный тег → null', () {
      expect(directionTagConflict('ru-exit', const ['vpn-1']), isNull);
      expect(directionTagConflict('vpn-2', const ['vpn-1']), isNull);
    });

    test('пустой / только пробелы → empty', () {
      expect(directionTagConflict('', const []), 'empty');
      expect(directionTagConflict('   ', const []), 'empty');
    });

    test('служебные теги конфига и псевдо-цели правил → reserved', () {
      for (final t in ['direct-out', 'block', 'block-out', 'dns-out', 'direct',
        'reject', 'drop']) {
        expect(directionTagConflict(t, const []), 'reserved', reason: t);
      }
    });

    test('дубль существующего → duplicate', () {
      expect(directionTagConflict('vpn-1', const ['vpn-1']), 'duplicate');
      // trim применяется до сравнения.
      expect(directionTagConflict(' vpn-1 ', const ['vpn-1']), 'duplicate');
    });

    test('коллизия с auto-двойником в обе стороны → auto_twin', () {
      expect(directionTagConflict('vpn-1-auto', const ['vpn-1']), 'auto_twin');
      expect(directionTagConflict('exit', const ['exit-auto']), 'auto_twin');
      // Без родителя `vpn-9` тег `vpn-9-auto` свободен.
      expect(directionTagConflict('vpn-9-auto', const ['vpn-1']), isNull);
    });
  });

  group('§393 A3 — defaultLabelForTag', () {
    test('vpn-N → «VPN ⓝ», выше 10 — числом', () {
      expect(defaultLabelForTag('vpn-1'), 'VPN ①');
      expect(defaultLabelForTag('vpn-10'), 'VPN ⑩');
      expect(defaultLabelForTag('vpn-11'), 'VPN 11');
    });

    test('произвольный тег → сам тег', () {
      expect(defaultLabelForTag('ru-exit'), 'ru-exit');
      expect(defaultLabelForTag('vpn-1-auto'), 'vpn-1-auto');
    });
  });

  group('§198 — defaultDirectionLabel (цифра в кружке)', () {
    test('1..10 → VPN ①..VPN ⑩', () {
      expect(defaultDirectionLabel(1), 'VPN ①');
      expect(defaultDirectionLabel(2), 'VPN ②');
      expect(defaultDirectionLabel(5), 'VPN ⑤');
      expect(defaultDirectionLabel(10), 'VPN ⑩');
    });

    test('вне 1..10 → без кружка', () {
      expect(defaultDirectionLabel(0), 'VPN 0');
      expect(defaultDirectionLabel(11), 'VPN 11');
    });

    test('directionNumberOf парсит vpn-N', () {
      expect(directionNumberOf('vpn-1'), 1);
      expect(directionNumberOf('vpn-7'), 7);
      expect(directionNumberOf('vpn-1-auto'), isNull);
      expect(directionNumberOf('direct-out'), isNull);
    });
  });

  group('Direction computed', () {
    test('autoTag производный, не из storage', () {
      const c = Direction(tag: 'vpn-4', label: 'x');
      expect(c.autoTag, 'vpn-4-auto');
      expect(c.toJson().containsKey('auto_tag'), false);
    });

    test('isRequired только для vpn-1', () {
      expect(const Direction(tag: 'vpn-1', label: 'x').isRequired, true);
      expect(const Direction(tag: 'vpn-2', label: 'x').isRequired, false);
    });
  });

  group('DirectionAuto tolerance clamp (§161 uint16)', () {
    test('из JSON выше 65535 → clamp', () {
      final a = DirectionAuto.fromJson({'tolerance': 999999});
      expect(a.tolerance, 65535);
    });

    test('отрицательный → 0', () {
      final a = DirectionAuto.fromJson({'tolerance': -5});
      expect(a.tolerance, 0);
    });

    test('copyWith тоже clamp', () {
      const a = DirectionAuto();
      expect(a.copyWith(tolerance: 70000).tolerance, 65535);
      expect(a.copyWith(tolerance: 100).tolerance, 100);
    });

    test('toJson переклампливает на всякий случай', () {
      // конструктор не клампит (const), но toJson — да
      const a = DirectionAuto(tolerance: 80000);
      expect(a.toJson()['tolerance'], 65535);
    });
  });

  group('§208 — DirectionAuto balancer (round_robin)', () {
    test('дефолты: leastTest, pool 3, poolTolerance 0, sticky process+domain', () {
      const a = DirectionAuto();
      expect(a.mode, UrltestMode.leastTest);
      expect(a.pool, 3);
      expect(a.poolTolerance, 0);
      expect(a.stickyHash, [StickyHashKey.process, StickyHashKey.domain]);
    });

    test('старый JSON без mode/balancer → дефолты (обратная совместимость)', () {
      final a = DirectionAuto.fromJson({
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
      const a = DirectionAuto(
        mode: UrltestMode.roundRobin,
        pool: 5,
        poolTolerance: 80,
        stickyHash: [StickyHashKey.domain, StickyHashKey.destIp],
      );
      final r = DirectionAuto.fromJson(a.toJson());
      expect(r.mode, UrltestMode.roundRobin);
      expect(r.pool, 5);
      expect(r.poolTolerance, 80);
      expect(r.stickyHash, [StickyHashKey.domain, StickyHashKey.destIp]);
    });

    test('toJson — mode в корне, balancer вложен', () {
      const a = DirectionAuto(
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
      const a = DirectionAuto(
          mode: UrltestMode.roundRobin, stickyHash: <StickyHashKey>[]);
      final r = DirectionAuto.fromJson(a.toJson());
      expect(r.stickyHash, isEmpty);
      expect((a.toJson()['balancer'] as Map)['sticky_hash'], isEmpty);
    });

    test('pool clamp: 0/отриц → 1', () {
      expect(DirectionAuto.fromJson({
        'balancer': {'pool': 0}
      }).pool, 1);
      expect(DirectionAuto.fromJson({
        'balancer': {'pool': -3}
      }).pool, 1);
      expect(const DirectionAuto().copyWith(pool: 0).pool, 1);
    });

    test('poolTolerance clamp как tolerance (uint16)', () {
      expect(DirectionAuto.fromJson({
        'balancer': {'pool_tolerance': 999999}
      }).poolTolerance, 65535);
      expect(DirectionAuto.fromJson({
        'balancer': {'pool_tolerance': -5}
      }).poolTolerance, 0);
    });

    test('неизвестный sticky-компонент отбрасывается', () {
      final a = DirectionAuto.fromJson({
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
      const a = DirectionAuto();
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

  group('Direction.copyWith', () {
    test('tag immutable, меняем только label', () {
      const c = Direction(tag: 'vpn-2', label: 'old');
      final n = c.copyWith(label: 'new');
      expect(n.tag, 'vpn-2');
      expect(n.label, 'new');
    });

    test('clearAuto убирает auto', () {
      const c = Direction(tag: 'vpn-2', label: 'x', auto: DirectionAuto());
      expect(c.copyWith(clearAuto: true).auto, isNull);
    });

    test('auto сохраняется если не трогали', () {
      const c = Direction(tag: 'vpn-2', label: 'x', auto: DirectionAuto());
      expect(c.copyWith(label: 'y').auto, isNotNull);
    });
  });

  group('Direction.seedFromDefault (миграция §267)', () {
    test('структурные поля из default_directions + шаблона direction', () {
      final dc =
          DefaultDirection(tag: 'vpn-1', label: 'Главный', defaultEnabled: true);
      final tpl = DirectionTemplate(
        include: const ['direct'],
        options: const {'interrupt_exist_connections': true},
      );
      final c = Direction.seedFromDefault(dc, tpl, enabled: true);
      expect(c.tag, 'vpn-1');
      expect(c.label, 'Главный');
      expect(c.includeDirect, true); // include ∋ direct
      expect(c.interruptExistConnections, true);
      expect(c.nodeFilter, '');
      expect(c.defaultFilter, ''); // Решение 6
      expect(c.auto, isNull); // auto передаётся снаружи; здесь не задан
    });

    test('label fallback к tag когда пусто; include пуст → без direct', () {
      final dc = DefaultDirection(tag: 'vpn-3');
      final c = Direction.seedFromDefault(dc, DirectionTemplate(), enabled: false);
      expect(c.label, 'vpn-3');
      expect(c.includeDirect, false); // include пуст
    });
  });
}
