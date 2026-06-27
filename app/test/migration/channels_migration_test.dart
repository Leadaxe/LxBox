import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:lxbox/models/channel.dart';
import 'package:lxbox/models/parser_config.dart';
import 'package:lxbox/services/settings_storage.dart';

/// §125 F0.3 — миграция enabled_groups[] → channels[] (one-shot seed из template).
///
/// Harness идентичен settings_storage_test.dart: mock path_provider + изоляция
/// tmp-dir + resetCacheForTesting между прогонами.
void main() {
  late Directory tmp;
  const channel = MethodChannel('plugins.flutter.io/path_provider');

  String mainPath() => '${tmp.path}/lxbox_settings.json';

  // template: vpn-1 (direct+auto), vpn-2 (direct), vpn-3, ✨auto (глобальный).
  List<PresetGroup> template() => [
        PresetGroup(
          tag: 'vpn-1',
          type: 'selector',
          label: 'Главный',
          addOutbounds: const ['direct-out', '✨auto'],
          options: const {'interrupt_exist_connections': true},
        ),
        PresetGroup(
          tag: 'vpn-2',
          type: 'selector',
          label: 'Стриминг',
          defaultEnabled: false,
          addOutbounds: const ['direct-out'],
        ),
        PresetGroup(tag: 'vpn-3', type: 'selector', defaultEnabled: false),
        PresetGroup(
          tag: '✨auto',
          type: 'urltest',
          options: const {
            'url': 'https://cp.cloudflare.com/generate_204',
            'interval': '5m',
            'tolerance': 50,
          },
        ),
      ];

  setUp(() async {
    TestWidgetsFlutterBinding.ensureInitialized();
    tmp = await Directory.systemTemp.createTemp('lxbox_channels_mig_');
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
      if (call.method == 'getApplicationDocumentsDirectory' ||
          call.method == 'getApplicationDocumentsPath') {
        return tmp.path;
      }
      return null;
    });
    SettingsStorage.resetCacheForTesting();
  });

  tearDown(() async {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null);
    try {
      if (tmp.existsSync()) await tmp.delete(recursive: true);
    } catch (_) {}
  });

  Future<void> seedFile(Map<String, dynamic> data) async {
    await File(mainPath()).writeAsString(jsonEncode(data));
    SettingsStorage.resetCacheForTesting();
  }

  test('fresh install: seed из template, enabled_groups пуст', () async {
    await seedFile({});
    await SettingsStorage.migrateChannelsIfNeeded(template());

    final channels = await SettingsStorage.getChannels();
    // ✨auto НЕ канал → 3 канала (vpn-1/2/3)
    expect(channels.map((c) => c.tag), ['vpn-1', 'vpn-2', 'vpn-3']);

    final vpn1 = channels.firstWhere((c) => c.tag == 'vpn-1');
    expect(vpn1.enabled, true); // vpn-1 форсим
    expect(vpn1.includeDirect, true); // add_outbounds ∋ direct-out
    expect(vpn1.auto, isNotNull); // add_outbounds ∋ ✨auto → двойник
    expect(vpn1.auto!.url, 'https://cp.cloudflare.com/generate_204');
    expect(vpn1.auto!.idleTimeout, '30m');
    expect(vpn1.auto!.interruptExistConnections, false);
    expect(vpn1.interruptExistConnections, true);

    final vpn2 = channels.firstWhere((c) => c.tag == 'vpn-2');
    expect(vpn2.enabled, false); // defaultEnabled false
    expect(vpn2.includeDirect, true);
    expect(vpn2.auto, isNull); // нет ✨auto в add_outbounds

    final vpn3 = channels.firstWhere((c) => c.tag == 'vpn-3');
    expect(vpn3.includeDirect, false);
    expect(vpn3.defaultFilter, ''); // Решение 6
    expect(vpn3.nodeFilter, '');
  });

  test('enabled_groups задаёт enabled (не defaultEnabled)', () async {
    // юзер выключил vpn-1 (но миграция всё равно форсит), включил vpn-3
    await seedFile({
      'enabled_groups': ['vpn-3'],
    });
    await SettingsStorage.migrateChannelsIfNeeded(template());

    final channels = await SettingsStorage.getChannels();
    expect(channels.firstWhere((c) => c.tag == 'vpn-1').enabled, true); // форс
    expect(channels.firstWhere((c) => c.tag == 'vpn-2').enabled, false);
    expect(channels.firstWhere((c) => c.tag == 'vpn-3').enabled, true);
  });

  test('идемпотентность: повторный вызов — no-op', () async {
    await seedFile({});
    await SettingsStorage.migrateChannelsIfNeeded(template());
    final first = await SettingsStorage.getChannels();

    // юзер удалил канал после миграции
    await SettingsStorage.setChannels(
        first.where((c) => c.tag != 'vpn-2').toList());
    // повторная миграция НЕ должна пересеять vpn-2
    await SettingsStorage.migrateChannelsIfNeeded(template());

    final after = await SettingsStorage.getChannels();
    expect(after.map((c) => c.tag), ['vpn-1', 'vpn-3']);
  });

  test('channels уже есть → миграция no-op', () async {
    await seedFile({
      'channels': [
        {'tag': 'vpn-1', 'label': 'Custom', 'enabled': true},
      ],
    });
    await SettingsStorage.migrateChannelsIfNeeded(template());

    final channels = await SettingsStorage.getChannels();
    expect(channels.length, 1);
    expect(channels.first.label, 'Custom'); // не перезаписано template'ом
  });

  group('CRUD после миграции', () {
    setUp(() async {
      await seedFile({});
      await SettingsStorage.migrateChannelsIfNeeded(template());
    });

    test('addChannel — первый свободный vpn-N', () async {
      // vpn-1/2/3 заняты → vpn-4
      final ch = await SettingsStorage.addChannel(label: 'Новый');
      expect(ch.tag, 'vpn-4');
      expect(ch.label, 'Новый');
      expect((await SettingsStorage.getChannels()).length, 4);
    });

    test('addChannel — лимит 10 throws', () async {
      for (var i = 4; i <= 10; i++) {
        await SettingsStorage.addChannel();
      }
      expect((await SettingsStorage.getChannels()).length, 10);
      expect(() => SettingsStorage.addChannel(), throwsStateError);
    });

    test('deleteChannel vpn-1 throws', () async {
      expect(() => SettingsStorage.deleteChannel('vpn-1'), throwsStateError);
    });

    test('deleteChannel переводит route_final → vpn-1', () async {
      await SettingsStorage.saveRouteFinal('vpn-2');
      await SettingsStorage.deleteChannel('vpn-2');
      expect(await SettingsStorage.getRouteFinal(), 'vpn-1');
      expect((await SettingsStorage.getChannels()).map((c) => c.tag),
          ['vpn-1', 'vpn-3']);
    });

    test('route_final на другой канал не трогается', () async {
      await SettingsStorage.saveRouteFinal('vpn-3');
      await SettingsStorage.deleteChannel('vpn-2');
      expect(await SettingsStorage.getRouteFinal(), 'vpn-3');
    });

    test('updateChannel — несуществующий tag throws', () async {
      const ghost = Channel(tag: 'vpn-9', label: 'ghost');
      expect(() => SettingsStorage.updateChannel(ghost), throwsStateError);
    });
  });
}
