import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:lxbox/controllers/subscription_controller.dart';
import 'package:lxbox/models/codec/source_record.dart';
import 'package:lxbox/models/direction.dart';
import 'package:lxbox/models/dns_ref.dart';
import 'package:lxbox/models/node_link.dart';
import 'package:lxbox/models/node_sections.dart';
import 'package:lxbox/models/server_list.dart';
import 'package:lxbox/services/direction_mutations.dart';
import 'package:lxbox/services/record_vars.dart';
import 'package:lxbox/services/settings_storage.dart';

/// §248 — зеркальный ресинк in-memory `_entries` контроллера после
/// storage-heal detour-ссылок (`syncDetourDirectionRefsCleared`): без него
/// следующий `_persist()` (rename/toggle/refresh) воскресил бы вылеченную
/// ссылку на диске. Harness path_provider-мока — как в
/// detour_direction_heal_test.dart. Плюс unit-тесты общего pure-ядра
/// [clearDetourDirectionRefs] (им обязаны сбрасывать одинаково storage-heal
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
        detourPolicy: DetourPolicy(overrideDetour: NodeLink(tag: overrideDetour)),
        origin: UserSource.paste,
        rawBody: memberRaw('solo-node'),
      );

  group('§248 — syncDetourDirectionRefsCleared (контроллер)', () {
    /// Storage: detour-Направление vpn-2 + одиночка с overrideDetour на него.
    Future<void> seed() async {
      final data = {
        'directions_migrated': true,
        'directions': [
          const Direction(tag: 'vpn-1', label: 'Main').toJson(),
          const Direction(tag: 'vpn-2', label: 'Relay', isDetour: true).toJson(),
        ],
        'storage_version': 1,
        'sources': [sourceToRecord(soloWithDetour('vpn-2'))],
      };
      await File(mainPath()).writeAsString(jsonEncode(data));
      SettingsStorage.resetCacheForTesting();
    }

    test('ресинк зеркалит storage-heal; _persist не воскрешает ссылку',
        () async {
      await seed();
      final c = SubscriptionController();
      await c.init();
      expect(c.entries.single.list.detourPolicy.overrideDetour, const NodeLink(tag: 'vpn-2'));

      // Storage-heal (то, что делают UI/Debug API перед ресинком).
      final vpn2 = (await SettingsStorage.getDirections())
          .firstWhere((ch) => ch.tag == 'vpn-2');
      final res =
          await SettingsStorage.updateDirection(vpn2.copyWith(isDetour: false));
      expect(res.detours, 1);

      // (а) in-memory entries вылечены зеркально.
      c.syncDetourDirectionRefsCleared('vpn-2');
      expect(c.entries.single.list.detourPolicy.overrideDetour, NodeLink.none);

      // (б) контроллерная мутация с _persist (выключение; имя одиночного
      // сервера записью §439 не хранится) НЕ воскрешает 'vpn-2' на диске —
      // иначе heal был бы показан юзеру, но отменён.
      await c.toggleAt(0);
      SettingsStorage.resetCacheForTesting(); // читаем реально с диска
      final saved = (await SettingsStorage.getServerLists()).single;
      expect(saved.enabled, isFalse);
      expect(saved.detourPolicy.overrideDetour, NodeLink.none,
          reason: '_persist после ресинка не должен воскрешать ссылку');
    });

    test('без совпадающих ссылок ресинк — no-op (entries не пересозданы)',
        () async {
      await seed();
      final c = SubscriptionController();
      await c.init();
      final before = c.entries.single.list;

      c.syncDetourDirectionRefsCleared('vpn-9');
      expect(identical(c.entries.single.list, before), isTrue);
      expect(c.entries.single.list.detourPolicy.overrideDetour, const NodeLink(tag: 'vpn-2'));
    });
  });

  group('§248 — clearDetourDirectionRefs (pure-ядро)', () {
    test('tag-матч: overrideDetour одиночки → \'\', count 1', () {
      final r = clearDetourDirectionRefs(soloWithDetour('vpn-2'), 'vpn-2');
      expect(r.count, 1);
      expect(r.healed!.detourPolicy.overrideDetour, NodeLink.none);
    });

    test('autoTag-матч: ссылка на urltest-двойник тоже Направление', () {
      final r = clearDetourDirectionRefs(soloWithDetour('vpn-2-auto'), 'vpn-2');
      expect(r.count, 1);
      expect(r.healed!.detourPolicy.overrideDetour, NodeLink.none);
    });

    test('не-матч → healed null, count 0', () {
      final r = clearDetourDirectionRefs(soloWithDetour('vpn-9'), 'vpn-2');
      expect(r.count, 0);
      expect(r.healed, isNull);
    });

    test('омоним-пропуск: пара на члена-тёзку — не Направление', () {
      // policy и member.detour указывают на члена с сырым тегом 'vpn-2' ТОЙ ЖЕ
      // папки — пара {f1, vpn-2} (D-112); корневое имя Направления с ней не
      // совпадает, и Направление ни при чём.
      const member = NodeLink(folderId: 'f1', tag: 'vpn-2');
      final folder = FolderServers(
        id: 'f1',
        name: 'Homonym',
        enabled: true,
        tagPrefix: 'hm-',
        detourPolicy: const DetourPolicy(overrideDetour: member),
        members: [
          FolderMember(raw: memberRaw('vpn-2')),
          FolderMember(raw: memberRaw('node-b'), detour: member),
        ],
      );
      final r = clearDetourDirectionRefs(folder, 'vpn-2');
      expect(r.count, 0);
      expect(r.healed, isNull);
    });

    test('папка без омонима: policy + оба member.detour → count 3', () {
      final folder = FolderServers(
        id: 'f1',
        name: 'F',
        enabled: true,
        tagPrefix: '',
        detourPolicy: const DetourPolicy(overrideDetour: NodeLink(tag: 'vpn-2')),
        members: [
          FolderMember(raw: memberRaw('node-a'), detour: NodeLink(tag: 'vpn-2')),
          FolderMember(raw: memberRaw('node-b'), detour: NodeLink(tag: 'vpn-2-auto')),
          FolderMember(raw: memberRaw('node-c'), detour: NodeLink(tag: 'Jump')),
        ],
      );
      final r = clearDetourDirectionRefs(folder, 'vpn-2');
      expect(r.count, 3);
      final healed = r.healed as FolderServers;
      expect(healed.detourPolicy.overrideDetour, NodeLink.none);
      expect(healed.members.map((m) => m.detour),
          const [NodeLink.none, NodeLink.none, NodeLink(tag: 'Jump')]);
    });
  });

  // §441 (SPEC 128 §6, D-114) — detour DNS-сервера — одиночная цель по имени:
  // при удалении и выключении Направления `body.detour` user-сервера,
  // корневого и в секциях узлов, переводится на vpn-1, как цель правила.
  group('§441 — detour DNS-серверов на Направление', () {
    DnsServerInline dns(String tag, String detour) => DnsServerInline(
          enabled: true,
          tag: tag,
          body: {'type': 'udp', 'server': '10.0.0.53', 'detour': detour},
        );

    NodeSections sectionsWith(String detour) =>
        NodeSections(dnsServers: [dns('@{self}-dns', detour)]);

    UserServer soloWithSections(String detour) => UserServer(
          id: 'u1',
          name: 'Solo',
          enabled: true,
          tagPrefix: '',
          detourPolicy: const DetourPolicy(),
          origin: UserSource.paste,
          rawBody: memberRaw('solo-node'),
          sections: sectionsWith(detour),
        );

    FolderServers folderWithSections() => FolderServers(
          id: 'f1',
          name: 'F',
          enabled: true,
          tagPrefix: '',
          detourPolicy: const DetourPolicy(),
          members: [
            FolderMember(raw: memberRaw('node-a'), sections: sectionsWith('vpn-2-auto')),
            FolderMember(raw: memberRaw('node-b'), sections: sectionsWith('@self')),
          ],
        );

    String detourOf(DnsServerInline s) => s.body['detour'] as String;

    Future<void> seed() async {
      await File(mainPath()).writeAsString(jsonEncode({
        'directions_migrated': true,
        'directions': [
          const Direction(tag: 'vpn-1', label: 'Main').toJson(),
          const Direction(tag: 'vpn-2', label: 'Relay').toJson(),
        ],
        'storage_version': 1,
        'sources': [
          sourceToRecord(soloWithSections('vpn-2')),
          sourceToRecord(folderWithSections()),
        ],
      }));
      SettingsStorage.resetCacheForTesting();
      await SettingsStorage.saveDnsServers([dns('my-dns', 'vpn-2'), dns('other', 'vpn-9')]);
    }

    test('удаление: корневой и секционные detour → vpn-1, счётчик, зеркало контроллера',
        () async {
      await seed();
      final c = SubscriptionController();
      await c.init();

      final healed = await DirectionMutations.delete('vpn-2', c);

      expect(healed.dnsServers, 3, reason: 'корневой my-dns + solo + член node-a');
      expect(DirectionMutations.healMessageParts(healed),
          contains('3 DNS server(s) switched to vpn-1'));
      final root = (await SettingsStorage.getDnsServers()).cast<DnsServerInline>();
      expect(root.map(detourOf), ['vpn-1', 'vpn-9']);

      final lists = await SettingsStorage.getServerLists();
      expect(detourOf((lists[0] as UserServer).sections!.dnsServers.single), 'vpn-1');
      final members = (lists[1] as FolderServers).members;
      expect(detourOf(members[0].sections!.dnsServers.single), 'vpn-1');
      expect(detourOf(members[1].sections!.dnsServers.single), '@self');

      // Зеркало: `_entries` вылечены так же, и `_persist` не воскрешает ссылку.
      final solo = c.entries.first.list as UserServer;
      expect(detourOf(solo.sections!.dnsServers.single), 'vpn-1');
      await c.toggleAt(0);
      SettingsStorage.resetCacheForTesting();
      final saved = (await SettingsStorage.getServerLists()).first as UserServer;
      expect(saved.enabled, isFalse);
      expect(detourOf(saved.sections!.dnsServers.single), 'vpn-1');
    });

    test('выключение лечит так же; снятие detour-флага — нет', () async {
      await seed();
      final vpn2 = (await SettingsStorage.getDirections())
          .firstWhere((d) => d.tag == 'vpn-2');

      final flagged = await SettingsStorage.updateDirection(vpn2.copyWith(isDetour: true));
      expect(flagged.dnsServers, 0);
      final unflagged = await SettingsStorage.updateDirection(
          vpn2.copyWith(isDetour: false));
      expect(unflagged.dnsServers, 0, reason: 'Направление осталось целью');

      final disabled = await SettingsStorage.updateDirection(
          vpn2.copyWith(isDetour: false, enabled: false));
      expect(disabled.dnsServers, 3);
      final root = (await SettingsStorage.getDnsServers()).cast<DnsServerInline>();
      expect(detourOf(root.first), 'vpn-1');
    });

    test('переименование: detour → новый тег, -auto → новый -auto (pure-ядро)', () {
      final retarget = directionRefRetarget('vpn-2', 'vpn-7', rename: true);

      final solo = retargetSectionsDnsDetours(soloWithSections('vpn-2'), retarget);
      expect(solo.count, 1);
      expect(detourOf((solo.healed as UserServer).sections!.dnsServers.single), 'vpn-7');

      final folder = retargetSectionsDnsDetours(folderWithSections(), retarget);
      expect(folder.count, 1);
      final members = (folder.healed as FolderServers).members;
      expect(detourOf(members[0].sections!.dnsServers.single), 'vpn-7-auto');
      expect(detourOf(members[1].sections!.dnsServers.single), '@self');

      final none = retargetSectionsDnsDetours(soloWithSections('vpn-9'), retarget);
      expect(none.healed, isNull);
      expect(none.count, 0);

      final root = dns('my-dns', 'vpn-2-auto');
      expect(
          detourOf(retargetDnsServerDirectionRefs(root, RecordVarDecls.none, retarget)
              as DnsServerInline),
          'vpn-7-auto');
      final untouched = dns('my-dns', 'vpn-22');
      expect(
          identical(
              retargetDnsServerDirectionRefs(untouched, RecordVarDecls.none, retarget),
              untouched),
          isTrue);
    });
  });
}
