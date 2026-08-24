import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:lxbox/models/direction.dart';
import 'package:lxbox/models/custom_rule.dart';
import 'package:lxbox/models/server_list.dart';
import 'package:lxbox/services/settings_storage.dart';

/// §248/§274 — storage-heal ссылок при смене detour-роли Направления (Решение B
/// §202, необратимо): flag-unset/disable/delete → detour-ссылки
/// (overrideDetour одиночки/подписки/папки + FolderMember.detour) → '';
/// disable/delete дополнительно лечат rules-ссылки (route_final/правила) →
/// vpn-1. Flag-SET ничего НЕ лечит (§274: флаг — разрешение, Направление остаётся
/// целью правил). Ссылка «на Направление» = tag ИЛИ `<tag>-auto`. Интра-омонимы
/// (значение = bare-тег члена той же папки) пропускаются. Harness — как
/// direction_heal_refs_test.dart.
void main() {
  late Directory tmp;
  const channel = MethodChannel('plugins.flutter.io/path_provider');

  String mainPath() => '${tmp.path}/lxbox_settings.json';

  setUp(() async {
    TestWidgetsFlutterBinding.ensureInitialized();
    tmp = await Directory.systemTemp.createTemp('lxbox_detour_heal_');
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

  /// Storage: detour-Направление vpn-3 + detour-ссылки на него всех четырёх видов
  /// (одиночка tag, подписка autoTag, папка policy+member) + папка-омоним
  /// (член с bare-тегом 'vpn-3': её ссылки — интра, heal их не трогает).
  Future<void> seedDetourRefsOnVpn3({bool vpn3Detour = true}) async {
    final data = {
      'channels_migrated': true,
      'channels': [
        const Direction(tag: 'vpn-1', label: 'Main').toJson(),
        Direction(tag: 'vpn-3', label: 'Relay', isDetour: vpn3Detour).toJson(),
      ],
      'server_lists': [
        UserServer(
          id: 'u1',
          name: 'Solo',
          enabled: true,
          tagPrefix: '',
          detourPolicy: const DetourPolicy(overrideDetour: 'vpn-3'),
          origin: UserSource.paste,
          createdAt: DateTime.now(),
          rawBody: memberRaw('solo-node'),
        ).toJson(),
        SubscriptionServers(
          id: 's1',
          name: 'Sub',
          enabled: true,
          tagPrefix: '',
          detourPolicy: const DetourPolicy(overrideDetour: 'vpn-3-auto'),
          url: 'https://example.com/sub',
        ).toJson(),
        FolderServers(
          id: 'f1',
          name: 'Folder',
          enabled: true,
          tagPrefix: '',
          detourPolicy: const DetourPolicy(overrideDetour: 'vpn-3'),
          members: [
            FolderMember(raw: memberRaw('node-a'), detour: 'vpn-3'),
            FolderMember(raw: memberRaw('node-b')),
          ],
        ).toJson(),
        // Папка-омоним: член с bare-тегом 'vpn-3' → ссылки 'vpn-3' внутри
        // НЕЁ означают ЧЛЕНА (приоритет bareIndex FolderDetourPlan).
        FolderServers(
          id: 'f2',
          name: 'Homonym',
          enabled: true,
          tagPrefix: 'hm-',
          detourPolicy: const DetourPolicy(overrideDetour: 'vpn-3'),
          members: [
            FolderMember(raw: memberRaw('vpn-3')),
            FolderMember(raw: memberRaw('node-c'), detour: 'vpn-3'),
          ],
        ).toJson(),
      ],
    };
    await File(mainPath()).writeAsString(jsonEncode(data));
    SettingsStorage.resetCacheForTesting();
  }

  Future<Direction> vpn3() async => (await SettingsStorage.getDirections())
      .firstWhere((c) => c.tag == 'vpn-3');

  Future<ServerList> listById(String id) async =>
      (await SettingsStorage.getServerLists()).firstWhere((l) => l.id == id);

  test('flag-unset: все четыре вида detour-ссылок → \'\', омонимы целы',
      () async {
    await seedDetourRefsOnVpn3();

    final res = await SettingsStorage.updateDirection(
        (await vpn3()).copyWith(isDetour: false));

    expect((await listById('u1')).detourPolicy.overrideDetour, '');
    expect((await listById('s1')).detourPolicy.overrideDetour, '');
    final f1 = await listById('f1') as FolderServers;
    expect(f1.detourPolicy.overrideDetour, '');
    expect(f1.members.first.detour, '');
    // Омоним-папка: и policy, и member ссылаются на ЧЛЕНА 'vpn-3' — не трогаем.
    final f2 = await listById('f2') as FolderServers;
    expect(f2.detourPolicy.overrideDetour, 'vpn-3');
    expect(f2.members[1].detour, 'vpn-3');
    // Счётчики: u1 + s1(autoTag) + f1.policy + f1.member = 4.
    expect(res.detours, 4);
    expect(res.rules, 0);
  });

  test('flag-unset необратим: повторная установка не воскрешает ссылки',
      () async {
    await seedDetourRefsOnVpn3();
    await SettingsStorage.updateDirection(
        (await vpn3()).copyWith(isDetour: false));

    await SettingsStorage.updateDirection(
        (await vpn3()).copyWith(isDetour: true));

    expect((await listById('u1')).detourPolicy.overrideDetour, '');
  });

  test('disable detour-Направления лечит detour-ссылки', () async {
    await seedDetourRefsOnVpn3();

    final res = await SettingsStorage.updateDirection(
        (await vpn3()).copyWith(enabled: false));

    expect((await listById('u1')).detourPolicy.overrideDetour, '');
    expect(res.detours, 4);
  });

  test('delete detour-Направления лечит detour-ссылки', () async {
    await seedDetourRefsOnVpn3();

    final res = await SettingsStorage.deleteDirection('vpn-3');

    expect((await listById('u1')).detourPolicy.overrideDetour, '');
    expect((await listById('s1')).detourPolicy.overrideDetour, '');
    expect(res.detours, 4);
  });

  // Стерегут регресс назад к §248-семантике (flag-set лечил rules → vpn-1).
  group('§274 — flag-set НЕ лечит rules-ссылки', () {
    Future<void> seedRulesRefsOnVpn3({String routeFinal = 'vpn-3'}) async {
      final data = {
        'channels_migrated': true,
        'channels': [
          const Direction(tag: 'vpn-1', label: 'Main').toJson(),
          const Direction(tag: 'vpn-3', label: 'Aux').toJson(),
        ],
        'route_final': routeFinal,
        'custom_rules': [
          CustomRuleInline(
                  name: 'r1', domains: const ['x.com'], outbound: 'vpn-3')
              .toJson(),
          CustomRulePreset(
            name: 'Block Ads',
            presetId: 'block-ads',
            varsValues: const {'outbound': 'vpn-3'},
          ).toJson(),
          CustomRuleSrs(
            name: 'GeoIP RU',
            srsUrl: 'https://example.com/geoip-ru.srs',
            outbound: 'vpn-3',
          ).toJson(),
        ],
      };
      await File(mainPath()).writeAsString(jsonEncode(data));
      SettingsStorage.resetCacheForTesting();
    }

    test('route_final + inline + preset varsValues + srs целы, счётчики 0',
        () async {
      await seedRulesRefsOnVpn3();

      final res = await SettingsStorage.updateDirection(
          (await vpn3()).copyWith(isDetour: true));

      expect(await SettingsStorage.getRouteFinal(), 'vpn-3');
      final rules = await SettingsStorage.getCustomRules();
      expect(rules.map((r) => r.outbound), everyElement('vpn-3'));
      // srs-правило цело наравне с inline/preset — heal вообще не вызывался.
      expect(rules.whereType<CustomRuleSrs>().single.outbound, 'vpn-3');
      expect(res.rules, 0);
      expect(res.detours, 0);
    });

    test('route_final на auto-двойник тоже цел', () async {
      await seedRulesRefsOnVpn3(routeFinal: 'vpn-3-auto');

      await SettingsStorage.updateDirection(
          (await vpn3()).copyWith(isDetour: true));

      expect(await SettingsStorage.getRouteFinal(), 'vpn-3-auto');
    });
  });
}
