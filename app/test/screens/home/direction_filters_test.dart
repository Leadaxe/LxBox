import 'package:flutter_test/flutter_test.dart';
import 'package:lxbox/screens/home/direction_filters.dart';

/// §083 — unit tests для `DirectionFilters` snapshot class.
void main() {
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
}
