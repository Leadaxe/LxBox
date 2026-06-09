import 'package:flutter_test/flutter_test.dart';
import 'package:lxbox/screens/home/channel_filters.dart';

/// §083 — unit tests для `ChannelFilters` snapshot class.
void main() {
  group('ChannelFilters — defaults', () {
    test('конструктор без аргументов = все дефолты', () {
      const f = ChannelFilters();
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
      expect(ChannelFilters.empty.isEmpty, true);
    });
  });

  group('ChannelFilters — isEmpty', () {
    test('всё дефолт → isEmpty true', () {
      expect(const ChannelFilters().isEmpty, true);
    });

    test('regexPattern непустой → isEmpty false', () {
      expect(const ChannelFilters(regexPattern: '🇷🇺').isEmpty, false);
    });

    test('regexInvert → isEmpty false', () {
      expect(const ChannelFilters(regexInvert: true).isEmpty, false);
    });

    test('protocols непустой → isEmpty false', () {
      expect(const ChannelFilters(protocols: {'vless'}).isEmpty, false);
    });

    test('protocolsInvert → isEmpty false', () {
      expect(const ChannelFilters(protocolsInvert: true).isEmpty, false);
    });

    test('subscriptions непустой → isEmpty false', () {
      expect(const ChannelFilters(subscriptions: {'sub-1'}).isEmpty, false);
    });

    test('subscriptionsInvert → isEmpty false', () {
      expect(const ChannelFilters(subscriptionsInvert: true).isEmpty, false);
    });

    test('pingText непустой → isEmpty false', () {
      expect(const ChannelFilters(pingText: '200').isEmpty, false);
    });

    test('pingEnabled → isEmpty false', () {
      expect(const ChannelFilters(pingEnabled: true).isEmpty, false);
    });
  });

  group('ChannelFilters — хранит переданные значения', () {
    test('round-trip всех полей', () {
      const f = ChannelFilters(
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
      // ChannelFilters сам не копирует (immutable contract). Гарантия копии
      // — на стороне _captureFilters (Set.of). Здесь проверяем что
      // переданный Set хранится как есть.
      final protos = {'vless'};
      final f = ChannelFilters(protocols: protos);
      protos.add('vmess');
      // Без Set.of снимок видит мутацию — это ожидаемо для immutable-by-
      // contract класса; защита на стороне caller (_captureFilters).
      expect(f.protocols.contains('vmess'), true,
          reason: 'класс хранит ссылку; копию делает caller через Set.of');
    });
  });
}
