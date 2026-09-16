// ignore_for_file: depend_on_referenced_packages

import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:lxbox/controllers/subscription_controller.dart';
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

/// §445 — контроллер: `state_directory` узла Tailscale из индекса переживает
/// правку тега члена и смену префикса папки; удаление члена удаляет каталог
/// при остановленном ядре и оставляет его при поднятом.
void main() {
  late Directory tempDir;
  late String root;
  var coreStopped = true;

  String tsRaw(String tag) =>
      jsonEncode({'type': 'tailscale', 'tag': tag, 'auth_key': 'k'});

  Future<String> stateDirOf(SubscriptionController c) async {
    final json = await c.generateConfig();
    final config = jsonDecode(json!) as Map<String, dynamic>;
    final eps = (config['endpoints'] as List)
        .cast<Map<String, dynamic>>()
        .where((e) => e['type'] == 'tailscale');
    return eps.single['state_directory'] as String;
  }

  setUp(() async {
    TestWidgetsFlutterBinding.ensureInitialized();
    tempDir = await Directory.systemTemp.createTemp('ts_state_ctrl_');
    await Directory('${tempDir.path}/docs').create();
    await Directory('${tempDir.path}/support').create();
    root = '${tempDir.path}/support';
    PathProviderPlatform.instance = _FakePathProvider(tempDir.path);
    SettingsStorage.resetCacheForTesting();
    coreStopped = true;
    SubscriptionController.debugTailscaleStateRoot = root;
    SubscriptionController.debugCoreStopped = () async => coreStopped;
  });

  tearDown(() async {
    SubscriptionController.debugTailscaleStateRoot = null;
    SubscriptionController.debugCoreStopped = null;
    try {
      if (tempDir.existsSync()) await tempDir.delete(recursive: true);
    } on FileSystemException {
      // ignore
    }
  });

  test('правка тега и префикс папки — каталог тот же; удаление — каталог '
      'удалён только при остановленном ядре', () async {
    final c = SubscriptionController();
    await c.init();
    await c.addFolder('F');
    expect(await c.addMembersToFolder(0, tsRaw('a')), isNull);
    await c.addMembersToFolder(0, tsRaw('b'));

    final dirA = '$root/tailscale/a';
    expect(await c.generateConfig(), isNotNull);
    final config = jsonDecode((await c.generateConfig())!) as Map;
    final paths = [
      for (final e in config['endpoints'] as List)
        if ((e as Map)['type'] == 'tailscale') e['state_directory'],
    ];
    expect(paths, [dirA, '$root/tailscale/b']);
    await Directory(dirA).create(recursive: true);
    await File('$dirA/tailscaled.state').writeAsString('key');

    // Правка тела члена: тег a → renamed.
    expect(await c.updateMemberAt(0, 0, tsRaw('renamed')), isNull);
    await c.removeMemberAt(0, 1); // b — без каталога на диске
    expect(await stateDirOf(c), dirA);

    // Префикс папки.
    final entry = c.entries.single;
    await c.replaceList(0, (entry.list as dynamic).copyWith(tagPrefix: 'pr'));
    expect(await stateDirOf(c), dirA);
    expect(File('$dirA/tailscaled.state').existsSync(), isTrue);

    // Удаление под поднятым ядром: каталог остаётся до сборки при остановленном.
    coreStopped = false;
    await c.removeMemberAt(0, 0);
    expect(Directory(dirA).existsSync(), isTrue);
    await c.generateConfig();
    expect(Directory(dirA).existsSync(), isTrue);
    coreStopped = true;
    await c.generateConfig();
    expect(Directory(dirA).existsSync(), isFalse);
  });
}
