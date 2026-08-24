import 'package:flutter_test/flutter_test.dart';
import 'package:lxbox/screens/home/direction_filters.dart';

/// §083 — unit tests для `DirectionFilters` snapshot class.
void main() {
  group('DirectionFilters — defaults', () {
    test('конструктор без аргументов = все дефолты', () {
      const f = DirectionFilters();
      expect(f.regexPattern, '');
      expect(f.regexInvert, false);
      expect(f.protocols, isEmpty);
      expect(f.protocolsInvert, false);
      expect(f.subscriptions, isEmpty);
      expect(f.subscriptionsInvert, false);
      expect(f.pingText, '');
      expect(f.pingEnabled, false);
    });

    test('empty constant == дефолтный конструктор', () {
      expect(DirectionFilters.empty.isEmpty, true);
    });
  });

  group('DirectionFilters — isEmpty', () {
    test('всё дефолт → isEmpty true', () {
      expect(const DirectionFilters().isEmpty, true);
    });

    test('regexPattern непустой → isEmpty false', () {
      expect(const DirectionFilters(regexPattern: '🇷🇺').isEmpty, false);
    });

    test('regexInvert → isEmpty false', () {
      expect(const DirectionFilters(regexInvert: true).isEmpty, false);
    });

    test('protocols непустой → isEmpty false', () {
      expect(const DirectionFilters(protocols: {'vless'}).isEmpty, false);
    });

    test('protocolsInvert → isEmpty false', () {
      expect(const DirectionFilters(protocolsInvert: true).isEmpty, false);
    });

    test('§103 variants непустой → isEmpty false', () {
      expect(const DirectionFilters(variants: {'xhttp'}).isEmpty, false);
    });

    test('§103 variantsInvert → isEmpty false', () {
      expect(const DirectionFilters(variantsInvert: true).isEmpty, false);
    });

    test('subscriptions непустой → isEmpty false', () {
      expect(const DirectionFilters(subscriptions: {'sub-1'}).isEmpty, false);
    });

    test('subscriptionsInvert → isEmpty false', () {
      expect(const DirectionFilters(subscriptionsInvert: true).isEmpty, false);
    });

    test('pingText непустой → isEmpty false', () {
      expect(const DirectionFilters(pingText: '200').isEmpty, false);
    });

    test('pingEnabled → isEmpty false', () {
      expect(const DirectionFilters(pingEnabled: true).isEmpty, false);
    });
  });

  group('DirectionFilters — хранит переданные значения', () {
    test('round-trip всех полей', () {
      const f = DirectionFilters(
        regexPattern: 'Moscow',
        regexInvert: true,
        protocols: {'vless', 'vmess'},
        protocolsInvert: true,
        subscriptions: {'sub-1', 'custom'},
        subscriptionsInvert: true,
        pingText: '150',
        pingEnabled: true,
      );
      expect(f.regexPattern, 'Moscow');
      expect(f.regexInvert, true);
      expect(f.protocols, {'vless', 'vmess'});
      expect(f.protocolsInvert, true);
      expect(f.subscriptions, {'sub-1', 'custom'});
      expect(f.subscriptionsInvert, true);
      expect(f.pingText, '150');
      expect(f.pingEnabled, true);
      expect(f.isEmpty, false);
    });

    test('Set передаётся копией из caller — снимок не мутируется '
        'извне (Set.of в _captureFilters)', () {
      // DirectionFilters сам не копирует (immutable contract). Гарантия копии
      // — на стороне _captureFilters (Set.of). Здесь проверяем что
      // переданный Set хранится как есть.
      final protos = {'vless'};
      final f = DirectionFilters(protocols: protos);
      protos.add('vmess');
      // Без Set.of снимок видит мутацию — это ожидаемо для immutable-by-
      // contract класса; защита на стороне caller (_captureFilters).
      expect(f.protocols.contains('vmess'), true,
          reason: 'класс хранит ссылку; копию делает caller через Set.of');
    });
  });
}
