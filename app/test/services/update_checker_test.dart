import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:lxbox/services/settings_storage.dart';
import 'package:lxbox/services/update_checker.dart';

void main() {
  group('isNewer — semver comparisons', () {
    test('strict newer patch', () {
      expect(isNewer('v1.4.3', '1.4.2'), isTrue);
    });

    test('strict newer minor', () {
      expect(isNewer('v1.5.0', '1.4.99'), isTrue);
    });

    test('strict newer major', () {
      expect(isNewer('v2.0.0', '1.99.99'), isTrue);
    });

    test('equal returns false', () {
      expect(isNewer('v1.4.2', '1.4.2'), isFalse);
      expect(isNewer('1.4.2', 'v1.4.2'), isFalse);
    });

    test('older returns false', () {
      expect(isNewer('v1.4.1', '1.4.2'), isFalse);
      expect(isNewer('v0.9.99', '1.0.0'), isFalse);
    });

    test('two-part vs three-part — pad with zero', () {
      expect(isNewer('v1.5', '1.4.99'), isTrue);
      expect(isNewer('v1.4', '1.4.0'), isFalse);
      expect(isNewer('v1.4.1', '1.4'), isTrue);
    });

    test('handles v / V / no prefix', () {
      expect(isNewer('1.4.3', '1.4.2'), isTrue);
      expect(isNewer('V1.4.3', 'v1.4.2'), isTrue);
    });

    test('strips suffix after first non-numeric', () {
      // local-build с "-dirty" не должен ложно быть newer
      expect(isNewer('v1.4.2-dirty', '1.4.2'), isFalse);
      expect(isNewer('v1.4.3-rc1', '1.4.2'), isTrue);
    });

    test('malformed input returns false (no false-positive notify)', () {
      expect(isNewer('', '1.4.2'), isFalse);
      expect(isNewer('not-a-version', '1.4.2'), isFalse);
      expect(isNewer('v1.4.2', ''), isFalse);
      expect(isNewer('v1.x.y', '1.4.2'), isFalse);
      expect(isNewer('v1', '1.4.2'), isFalse); // single component invalid
      expect(isNewer('v1.2.3.4', '1.4.2'), isFalse); // too many parts
    });

    test('whitespace tolerated', () {
      expect(isNewer(' v1.4.3 ', '1.4.2'), isTrue);
    });
  });

  // §090 G1 — dismissCurrent должен персистить dismissed-версию + чистить
  // notifier (read-guard'ы дальше не покажут этот релиз). Паттерн mock —
  // как в settings_storage_test (path_provider MethodChannel + temp dir).
  group('dismissCurrent (§090 G1)', () {
    late Directory tmp;
    const channel = MethodChannel('plugins.flutter.io/path_provider');

    setUp(() async {
      TestWidgetsFlutterBinding.ensureInitialized();
      tmp = await Directory.systemTemp.createTemp('lxbox_update_checker_');
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, (call) async {
        if (call.method == 'getApplicationDocumentsDirectory' ||
            call.method == 'getApplicationDocumentsPath') {
          return tmp.path;
        }
        return null;
      });
      SettingsStorage.resetCacheForTesting();
      UpdateChecker.I.latest.value = null;
    });

    tearDown(() async {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, null);
      UpdateChecker.I.latest.value = null;
      try {
        await tmp.delete(recursive: true);
      } catch (_) {}
    });

    test('персистит tag + чистит latest', () async {
      UpdateChecker.I.latest.value = const UpdateInfo(
        tag: 'v9.9.9',
        name: 'rel',
        htmlUrl: 'https://example.com/r',
      );
      await UpdateChecker.I.dismissCurrent();
      expect(UpdateChecker.I.latest.value, isNull);
      expect(await SettingsStorage.getDismissedUpdateVersion(), 'v9.9.9');
    });

    test('no-op если latest == null', () async {
      UpdateChecker.I.latest.value = null;
      await UpdateChecker.I.dismissCurrent();
      expect(await SettingsStorage.getDismissedUpdateVersion(), '');
    });
  });
}
