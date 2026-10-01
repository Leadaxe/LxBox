// §567 — разбор ответа `getCurrentWifiInfo` (коды причин, поле `missing`)
// и выбор подсказки секции Wi-Fi по коду.
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lxbox/screens/custom_rule_edit/sections/wifi_section.dart';
import 'package:lxbox/services/platform_channels.dart';
import 'package:lxbox/services/url_launcher.dart';

const _fine = 'android.permission.ACCESS_FINE_LOCATION';
const _bg = 'android.permission.ACCESS_BACKGROUND_LOCATION';
const _nearby = 'android.permission.NEARBY_WIFI_DEVICES';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel(PlatformChannels.utils);

  void answer(Object? reply) {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
      expect(call.method, 'getCurrentWifiInfo');
      return reply;
    });
  }

  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null);
  });

  test('success keeps ssid and bssid', () async {
    answer({'ssid': 'Home', 'bssid': 'aa:bb:cc:dd:ee:ff'});
    final r = await UrlLauncher.getCurrentWifiInfo();
    expect(r, isA<WifiInfoSuccess>());
    r as WifiInfoSuccess;
    expect(r.ssid, 'Home');
    expect(r.bssid, 'aa:bb:cc:dd:ee:ff');
  });

  test('fine_location_missing carries the missing list in order', () async {
    answer({'error': 'fine_location_missing', 'missing': '$_fine,$_bg'});
    final r = await UrlLauncher.getCurrentWifiInfo() as WifiInfoError;
    expect(r.reason, 'fine_location_missing');
    expect(r.missing, [_fine, _bg]);
    expect(wifiHintFromError(r.reason, r.missing), WifiHint.preciseLocation);
  });

  test('permission_missing: hint follows the first missing permission',
      () async {
    answer({'error': 'permission_missing', 'missing': '$_nearby,$_fine'});
    final r = await UrlLauncher.getCurrentWifiInfo() as WifiInfoError;
    expect(r.missing, [_nearby, _fine]);
    expect(wifiHintFromError(r.reason, r.missing), WifiHint.nearbyWifi);
    expect(wifiHintFromError('permission_missing', const [_bg]),
        WifiHint.backgroundLocation);
  });

  test('location_disabled has no missing list', () async {
    answer({'error': 'location_disabled'});
    final r = await UrlLauncher.getCurrentWifiInfo() as WifiInfoError;
    expect(r.reason, 'location_disabled');
    expect(r.missing, isEmpty);
    expect(wifiHintFromError(r.reason, r.missing), WifiHint.locationOff);
  });

  test('empty missing string gives an empty list', () async {
    answer({'error': 'permission_missing', 'missing': ''});
    final r = await UrlLauncher.getCurrentWifiInfo() as WifiInfoError;
    expect(r.missing, isEmpty);
  });

  test('no_wifi, unknown_ssid and runtime_error show no hint', () async {
    for (final code in ['no_wifi', 'unknown_ssid', 'runtime_error']) {
      answer({'error': code});
      final r = await UrlLauncher.getCurrentWifiInfo() as WifiInfoError;
      expect(r.reason, code);
      expect(wifiHintFromError(r.reason, r.missing), isNull);
    }
  });

  test('channel failure maps to runtime_error', () async {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (_) async {
      throw PlatformException(code: 'boom');
    });
    final r = await UrlLauncher.getCurrentWifiInfo() as WifiInfoError;
    expect(r.reason, 'runtime_error');
  });
}
