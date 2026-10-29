import 'package:flutter_test/flutter_test.dart';
import 'package:lxbox/screens/custom_rule_edit/network_choice.dart';

// §694 — сегмент NETWORK: загрузка и сохранение.
void main() {
  group('networkChoiceFor', () {
    test('пусто → Any, пусто + SSID → Wi-Fi', () {
      expect(networkChoiceFor(const [], hasWifi: false), NetworkChoice.any);
      expect(networkChoiceFor(const [], hasWifi: true), NetworkChoice.wifi);
    });

    test('один тип → свой сегмент', () {
      expect(networkChoiceFor(const ['wifi'], hasWifi: false),
          NetworkChoice.wifi);
      expect(networkChoiceFor(const ['cellular'], hasWifi: false),
          NetworkChoice.cellular);
      expect(networkChoiceFor(const ['ethernet'], hasWifi: false),
          NetworkChoice.ethernet);
    });

    test('other / несколько типов → custom', () {
      expect(networkChoiceFor(const ['other'], hasWifi: false),
          NetworkChoice.custom);
      expect(networkChoiceFor(const ['wifi', 'ethernet'], hasWifi: false),
          NetworkChoice.custom);
    });
  });

  group('networkTypesFor', () {
    test('старое wifi-правило (SSID без network_type) — байт в байт', () {
      final t = networkTypesFor(NetworkChoice.wifi,
          loaded: const [], hasWifi: true);
      expect(t.types, isEmpty);
      expect(t.keepWifi, true);
    });

    test('Wi-Fi без SSID → [wifi]; загруженный [wifi] со SSID остаётся', () {
      expect(
          networkTypesFor(NetworkChoice.wifi, loaded: const [], hasWifi: false)
              .types,
          ['wifi']);
      expect(
          networkTypesFor(NetworkChoice.wifi,
                  loaded: const ['wifi'], hasWifi: true)
              .types,
          ['wifi']);
    });

    test('Any / Cellular / Ethernet снимают SSID', () {
      final any = networkTypesFor(NetworkChoice.any,
          loaded: const ['wifi'], hasWifi: true);
      expect(any.types, isEmpty);
      expect(any.keepWifi, false);
      final cell = networkTypesFor(NetworkChoice.cellular,
          loaded: const [], hasWifi: true);
      expect(cell.types, ['cellular']);
      expect(cell.keepWifi, false);
      expect(
          networkTypesFor(NetworkChoice.ethernet,
                  loaded: const [], hasWifi: false)
              .types,
          ['ethernet']);
    });

    test('custom — значение как было загружено', () {
      final t = networkTypesFor(NetworkChoice.custom,
          loaded: const ['wifi', 'other'], hasWifi: false);
      expect(t.types, ['wifi', 'other']);
    });
  });
}
