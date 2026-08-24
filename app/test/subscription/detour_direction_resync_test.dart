import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:lxbox/controllers/subscription_controller.dart';
import 'package:lxbox/models/channel.dart';
import 'package:lxbox/models/server_list.dart';
import 'package:lxbox/services/settings_storage.dart';

/// §248 — зеркальный ресинк in-memory `_entries` контроллера после
/// storage-heal detour-ссылок (`syncDetourChannelRefsCleared`): без него
/// следующий `_persist()` (rename/toggle/refresh) воскресил бы вылеченную
/// ссылку на диске. Harness path_provider-мока — как в
/// detour_channel_heal_test.dart. Плюс unit-тесты общего pure-ядра
/// [clearDetourChannelRefs] (им обязаны сбрасывать одинаково storage-heal
/// и ресинк контроллера).
void main() {
  late Directory tmp;
  const channel = MethodChannel('plugins.flutter.io/path_provider');

  String mainPath() => '${tmp.path}/lxbox_settings.json';

  setUp(() async {
    TestWidgetsFlutterBinding.ensureInitialized();
    tmp = await Directory.systemTemp.createTemp('lxbox_detour_resync_');
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

  String memberRaw(String name) =>
      'vless://u-$name@h.com:443?type=ws&security=tls#$name';

  UserServer soloWithDetour(String overrideDetour) => UserServer(
        id: 'u1',
        name: 'Solo',
        enabled: true,
        tagPrefix: '',
        detourPolicy: DetourPolicy(overrideDetour: overrideDetour),
        origin: UserSource.paste,
        createdAt: DateTime.now(),
        rawBody: memberRaw('solo-node'),
      );

  group('§248 — syncDetourChannelRefsCleared (контроллер)', () {
    /// Storage: detour-канал vpn-2 + одиночка с overrideDetour на него.
    Future<void> seed() async {
      final data = {
        'channels_migrated': true,
        'channels': [
          const Channel(tag: 'vpn-1', label: 'Main').toJson(),
          const Channel(tag: 'vpn-2', label: 'Relay', isDetour: true).toJson(),
        ],
        'server_lists': [soloWithDetour('vpn-2').toJson()],
      };
      await File(mainPath()).writeAsString(jsonEncode(data));
      SettingsStorage.resetCacheForTesting();
    }

    test('ресинк зеркалит storage-heal; _persist не воскрешает ссылку',
        () async {
      await seed();
      final c = SubscriptionController();
      await c.init();
      expect(c.entries.single.list.detourPolicy.overrideDetour, 'vpn-2');

      // Storage-heal (то, что делают UI/Debug API перед ресинком).
      final vpn2 = (await SettingsStorage.getChannels())
          .firstWhere((ch) => ch.tag == 'vpn-2');
      final res =
          await SettingsStorage.updateChannel(vpn2.copyWith(isDetour: false));
      expect(res.detours, 1);

      // (а) in-memory entries вылечены зеркально.
      c.syncDetourChannelRefsCleared('vpn-2');
      expect(c.entries.single.list.detourPolicy.overrideDetour, '');

      // (б) контроллерная мутация с _persist (rename) НЕ воскрешает
      // 'vpn-2' на диске — иначе heal был бы показан юзеру, но отменён.
      await c.renameAt(0, 'Solo Renamed');
      SettingsStorage.resetCacheForTesting(); // читаем реально с диска
      final saved = (await SettingsStorage.getServerLists()).single;
      expect(saved.name, 'Solo Renamed');
      expect(saved.detourPolicy.overrideDetour, '',
          reason: '_persist после ресинка не должен воскрешать ссылку');
    });

    test('без совпадающих ссылок ресинк — no-op (entries не пересозданы)',
        () async {
      await seed();
      final c = SubscriptionController();
      await c.init();
      final before = c.entries.single.list;

      c.syncDetourChannelRefsCleared('vpn-9');
      expect(identical(c.entries.single.list, before), isTrue);
      expect(c.entries.single.list.detourPolicy.overrideDetour, 'vpn-2');
    });
  });

  group('§248 — clearDetourChannelRefs (pure-ядро)', () {
    test('tag-матч: overrideDetour одиночки → \'\', count 1', () {
      final r = clearDetourChannelRefs(soloWithDetour('vpn-2'), 'vpn-2');
      expect(r.count, 1);
      expect(r.healed!.detourPolicy.overrideDetour, '');
    });

    test('autoTag-матч: ссылка на urltest-двойник тоже канал', () {
      final r = clearDetourChannelRefs(soloWithDetour('vpn-2-auto'), 'vpn-2');
      expect(r.count, 1);
      expect(r.healed!.detourPolicy.overrideDetour, '');
    });

    test('не-матч → healed null, count 0', () {
      final r = clearDetourChannelRefs(soloWithDetour('vpn-9'), 'vpn-2');
      expect(r.count, 0);
      expect(r.healed, isNull);
    });

    test('омоним-пропуск: bare-тег члена той же папки означает члена', () {
      // policy и member.detour = 'vpn-2', но 'vpn-2' — bare-тег члена ТОЙ ЖЕ
      // папки (приоритет bareIndex FolderDetourPlan) → канал ни при чём.
      final folder = FolderServers(
        id: 'f1',
        name: 'Homonym',
        enabled: true,
        tagPrefix: 'hm-',
        detourPolicy: const DetourPolicy(overrideDetour: 'vpn-2'),
        members: [
          FolderMember(raw: memberRaw('vpn-2')),
          FolderMember(raw: memberRaw('node-b'), detour: 'vpn-2'),
        ],
      );
      final r = clearDetourChannelRefs(folder, 'vpn-2');
      expect(r.count, 0);
      expect(r.healed, isNull);
    });

    test('папка без омонима: policy + оба member.detour → count 3', () {
      final folder = FolderServers(
        id: 'f1',
        name: 'F',
        enabled: true,
        tagPrefix: '',
        detourPolicy: const DetourPolicy(overrideDetour: 'vpn-2'),
        members: [
          FolderMember(raw: memberRaw('node-a'), detour: 'vpn-2'),
          FolderMember(raw: memberRaw('node-b'), detour: 'vpn-2-auto'),
          FolderMember(raw: memberRaw('node-c'), detour: 'Jump'),
        ],
      );
      final r = clearDetourChannelRefs(folder, 'vpn-2');
      expect(r.count, 3);
      final healed = r.healed as FolderServers;
      expect(healed.detourPolicy.overrideDetour, '');
      expect(healed.members.map((m) => m.detour), ['', '', 'Jump']);
    });
  });
}
