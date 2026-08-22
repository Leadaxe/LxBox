// ignore_for_file: depend_on_referenced_packages

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:lxbox/controllers/subscription_controller.dart';
import 'package:lxbox/models/node_spec.dart';
import 'package:lxbox/models/server_list.dart';
import 'package:lxbox/services/settings_storage.dart';
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';
import 'package:plugin_platform_interface/plugin_platform_interface.dart';

class _FakePathProvider extends PathProviderPlatform
    with MockPlatformInterfaceMixin {
  final String tempRoot;
  _FakePathProvider(this.tempRoot);
  @override
  Future<String?> getApplicationSupportPath() async => '$tempRoot/support';
  @override
  Future<String?> getApplicationDocumentsPath() async => '$tempRoot/docs';
}

/// §243 — имя файла становится tag'ом при импорте WG/AWG `.conf`:
/// одиночный путь (B1 — правка tag снова видна в списке) и папочный (B5 —
/// члены получают имена файлов, а не «WireGuard»).
void main() {
  late Directory tempDir;

  // SPEC 103 D-023/D-030 — normalizeWGKey требует РОВНО 32 байта base64;
  // короткие плейсхолдеры вроде "pk"/"pubk" больше не парсятся (null-skip).
  const _testPriv = 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaA=';
  const _testPub = 'bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbA=';

  // Обычный WG-экспорт (Proton-стиль) и awg2-экспорт с обфускацией.
  final wgIni = '[Interface]\n'
      'PrivateKey = $_testPriv\n'
      'Address = 10.0.0.2/32\n'
      '\n'
      '[Peer]\n'
      'PublicKey = $_testPub\n'
      'Endpoint = node.example.com:51820\n';
  final awgIni = '[Interface]\n'
      'PrivateKey = $_testPriv\n'
      'Address = 10.8.1.25/32\n'
      'Jc = 5\n'
      'Jmin = 10\n'
      'Jmax = 50\n'
      'I1 = <b 0x084481800001>\n'
      '[Peer]\n'
      'PublicKey = $_testPub\n'
      'Endpoint = 64.188.69.128:44733\n';

  setUp(() async {
    TestWidgetsFlutterBinding.ensureInitialized();
    tempDir = await Directory.systemTemp.createTemp('wg_name_');
    await Directory('${tempDir.path}/docs').create();
    await Directory('${tempDir.path}/support').create();
    PathProviderPlatform.instance = _FakePathProvider(tempDir.path);
    SettingsStorage.resetCacheForTesting();
  });

  tearDown(() async {
    try {
      if (tempDir.existsSync()) await tempDir.delete(recursive: true);
    } on FileSystemException {
      // ignore
    }
  });

  group('§243 одиночный импорт .conf (B1)', () {
    test('nameHint → tag = имя файла (с авто-эмодзи 🏠), entry.name пуст',
        () async {
      final c = SubscriptionController();
      await c.addFromInput(wgIni, nameHint: 'proton-nl-42');
      expect(c.lastError, isNull);
      final entry = c.entries.single;
      expect(entry.list, isA<UserServer>());
      expect(entry.name, ''); // §234-renameAt в name больше нет
      // §090 G2b — авто-эмодзи: WG без эмодзи в теге получает 🏠-префикс.
      expect(entry.list.nodes.single.tag, '🏠 proton-nl-42');
      expect(entry.displayName, '🏠 proton-nl-42');
    });

    test('без nameHint (вставка INI-текста) → прежний WireGuard', () async {
      final c = SubscriptionController();
      await c.addFromInput(wgIni);
      expect(c.lastError, isNull);
      expect(c.entries.single.list.nodes.single.tag, '🏠 WireGuard');
    });

    test('имя с пробелом/кириллицей/скобками → tag без %-каши', () async {
      final c = SubscriptionController();
      await c.addFromInput(wgIni, nameHint: 'Мой конфиг (дом)');
      final tag = c.entries.single.list.nodes.single.tag;
      expect(tag, '🏠 Мой конфиг (дом)');
      expect(tag, isNot(contains('%')));
    });

    test('имя переживает persist round-trip (rawBody → fromJson)', () async {
      final c = SubscriptionController();
      await c.addFromInput(wgIni, nameHint: 'home-wg');
      final us = c.entries.single.list as UserServer;
      // Путь рестарта: UserServer персистит только rawBody, ноды ре-деривятся.
      final reloaded = UserServer.fromJson(us.toJson());
      expect(reloaded.nodes.single.tag, '🏠 home-wg');
    });

    test(
        'правка tag через updateConnectionAt отражается в displayName, '
        'name затирается', () async {
      final c = SubscriptionController();
      await c.addFromInput(wgIni, nameHint: 'home-wg');
      // Пересохранение из Node Settings (JSON-таб) с новым tag'ом.
      const json = '{"type":"vless","tag":"Renamed ⚡","server":"h.example",'
          '"server_port":443,"uuid":"u-1"}';
      await c.updateConnectionAt(0, [json]);
      expect(c.entries.single.name, '');
      expect(c.entries.single.displayName, 'Renamed ⚡');
    });

    test('legacy-запись v2.11.0 с непустым name: displayName игнорирует name',
        () async {
      final c = SubscriptionController();
      await c.addFromInput(wgIni, nameHint: 'home-wg');
      // Симуляция старой записи: v2.11.0-импорт писал имя файла в name.
      await c.renameAt(0, 'legacy-file-name');
      expect(c.entries.single.name, 'legacy-file-name');
      expect(c.entries.single.displayName, '🏠 home-wg');
      // Пересохранение сервера затирает залежавшийся name.
      const json = '{"type":"vless","tag":"Fresh","server":"h.example",'
          '"server_port":443,"uuid":"u-1"}';
      await c.updateConnectionAt(0, [json]);
      expect(c.entries.single.name, '');
    });

    test('подписки и папки: name в displayName работает как раньше', () async {
      final c = SubscriptionController();
      await c.addFolder('My folder');
      expect(c.entries.single.displayName, 'My folder');
      await c.renameAt(0, 'Renamed folder');
      expect(c.entries.single.displayName, 'Renamed folder');
    });

    test('JSON-вставка (label = tag) не сломана', () async {
      final c = SubscriptionController();
      await c.addFromInput('{"type":"vless","tag":"Json 🚀",'
          '"server":"h.example","server_port":443,"uuid":"u-2"}');
      expect(c.lastError, isNull);
      expect(c.entries.single.name, '');
      expect(c.entries.single.displayName, 'Json 🚀');
    });
  });

  group('§243 папочный импорт .conf (B5)', () {
    test('addMembersToFolder + nameFallback: member tag = имя файла (WG)',
        () async {
      final c = SubscriptionController();
      await c.addFolder('Proton');
      final err =
          await c.addMembersToFolder(0, wgIni, nameFallback: 'proton-nl-1');
      expect(err, isNull);
      final folder = c.entries.single.list as FolderServers;
      final node = folder.members.single.node;
      expect(node, isNotNull);
      expect(node!.tag, 'proton-nl-1');
      // Имя живёт в raw члена (фрагмент) — переживает persist.
      final reloaded = FolderMember.fromJson(folder.members.single.toJson());
      expect(reloaded.node!.tag, 'proton-nl-1');
    });

    test('awg2-INI в папку: tag = имя файла, AWG-поля не потеряны', () async {
      final c = SubscriptionController();
      await c.addFolder('AWG');
      final err =
          await c.addMembersToFolder(0, awgIni, nameFallback: 'awg2 export');
      expect(err, isNull);
      final folder = c.entries.single.list as FolderServers;
      final node = folder.members.single.node as WireguardSpec;
      expect(node.tag, 'awg2 export');
      expect(node.awg!.fields['jc'], 5);
      expect(node.awg!.fields['i1'], '<b 0x084481800001>');
    });

    test('два файла с одинаковым фолбэком — имена не слипаются в WireGuard',
        () async {
      final c = SubscriptionController();
      await c.addFolder('Multi');
      await c.addMembersToFolder(0, wgIni, nameFallback: 'file-a');
      await c.addMembersToFolder(0, awgIni, nameFallback: 'file-b');
      final folder = c.entries.single.list as FolderServers;
      expect(folder.members[0].node!.tag, 'file-a');
      expect(folder.members[1].node!.tag, 'file-b');
    });

    test('без nameFallback (paste INI в папку) → прежний WireGuard', () async {
      final c = SubscriptionController();
      await c.addFolder('Paste');
      await c.addMembersToFolder(0, wgIni);
      final folder = c.entries.single.list as FolderServers;
      expect(folder.members.single.node!.tag, 'WireGuard');
    });

    test('nameFallback для безымянных URI-строк работает как раньше',
        () async {
      const unnamed = 'vless://u3@h3.example:443?type=ws&security=tls';
      final c = SubscriptionController();
      await c.addFolder('Uri');
      final err =
          await c.addMembersToFolder(0, unnamed, nameFallback: 'from-file');
      expect(err, isNull);
      final folder = c.entries.single.list as FolderServers;
      expect(folder.members.single.node!.tag, 'from-file');
    });
  });
}
