// §679 — на TV ориентация не фиксируется; на телефоне — §220 без изменений.

import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lxbox/main.dart';
import 'package:lxbox/services/settings_storage.dart';
import 'package:lxbox/services/url_launcher.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const utils = MethodChannel('com.leadaxe.lxbox/utils');
  const paths = MethodChannel('plugins.flutter.io/path_provider');
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  late Directory tmp;
  late List<Object?> applied;

  void device({required bool tv}) {
    UrlLauncher.resetTelevisionCacheForTesting();
    messenger.setMockMethodCallHandler(utils, (call) async {
      return call.method == 'isTelevision' ? tv : null;
    });
  }

  Map<String, String> snapshot() => {
        for (final f in tmp.listSync(recursive: true).whereType<File>())
          f.path: f.readAsStringSync(),
      };

  setUp(() async {
    tmp = await Directory.systemTemp.createTemp('lxbox_rotation_tv_');
    messenger.setMockMethodCallHandler(paths, (call) async => tmp.path);
    SettingsStorage.resetCacheForTesting();
    applied = [];
    messenger.setMockMethodCallHandler(SystemChannels.platform, (call) async {
      if (call.method == 'SystemChrome.setPreferredOrientations') {
        applied.add(call.arguments);
      }
      return null;
    });
  });

  tearDown(() async {
    messenger.setMockMethodCallHandler(paths, null);
    messenger.setMockMethodCallHandler(utils, null);
    messenger.setMockMethodCallHandler(SystemChannels.platform, null);
    UrlLauncher.resetTelevisionCacheForTesting();
    SettingsStorage.resetCacheForTesting();
    if (tmp.existsSync()) await tmp.delete(recursive: true);
  });

  group('preferredOrientationsFor', () {
    test('TV + allow_rotation=false → no preference', () {
      expect(
        preferredOrientationsFor(allowRotation: false, isTelevision: true),
        isEmpty,
      );
    });

    test('phone + allow_rotation=false → portraitUp', () {
      expect(
        preferredOrientationsFor(allowRotation: false, isTelevision: false),
        [DeviceOrientation.portraitUp],
      );
    });

    test('phone + allow_rotation=true → no preference', () {
      expect(
        preferredOrientationsFor(allowRotation: true, isTelevision: false),
        isEmpty,
      );
    });
  });

  group('applyAllowRotationSetting', () {
    test('TV: no lock, stored allow_rotation untouched', () async {
      await SettingsStorage.setAllowRotation(false);
      final before = snapshot();
      expect(before, isNotEmpty, reason: 'settings file not in the temp dir');
      device(tv: true);

      await applyAllowRotationSetting();

      expect(applied, [<Object?>[]]);
      expect(snapshot(), before);
      expect(await SettingsStorage.getAllowRotation(), isFalse);
    });

    test('phone + allow_rotation=false → portraitUp', () async {
      await SettingsStorage.setAllowRotation(false);
      device(tv: false);

      await applyAllowRotationSetting();

      expect(applied, [
        ['DeviceOrientation.portraitUp'],
      ]);
    });

    test('phone + allow_rotation=true → no preference', () async {
      await SettingsStorage.setAllowRotation(true);
      device(tv: false);

      await applyAllowRotationSetting();

      expect(applied, [<Object?>[]]);
    });
  });
}
