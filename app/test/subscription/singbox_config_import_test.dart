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

/// §368 — импорт sing-box JSON через контроллер: какой контейнер получается.
///
/// Порог тот же, что у файлового импорта (§129): один узел — сервер
/// (`UserServer`), несколько — набор (файловая подписка). `UserServer` устроен
/// как «один сервер», и конфиг на десяток узлов с группой в него не помещается.
void main() {
  late Directory tempDir;

  const singleOutbound = '{"type":"vless","tag":"solo",'
      '"server":"a.example","server_port":443,"uuid":"u-1"}';

  const wholeConfig = '''
{
  "log": {"level": "info"},
  "dns": {"servers": [{"tag": "g", "address": "8.8.8.8"}]},
  "inbounds": [{"type": "tun", "tag": "tun-in"}],
  "outbounds": [
    {"type": "vless", "tag": "DE", "server": "de.example", "server_port": 443,
     "uuid": "u-de", "detour": "jump"},
    {"type": "trojan", "tag": "NL", "server": "nl.example", "server_port": 443,
     "password": "p-nl"},
    {"type": "shadowsocks", "tag": "jump", "server": "jump.example",
     "server_port": 8388, "method": "aes-256-gcm", "password": "p-j"},
    {"type": "urltest", "tag": "Fastest", "outbounds": ["DE", "NL"]},
    {"type": "direct", "tag": "direct"}
  ],
  "route": {"rules": [{"protocol": "dns", "outbound": "dns-out"}]}
}
''';

  setUp(() async {
    TestWidgetsFlutterBinding.ensureInitialized();
    tempDir = await Directory.systemTemp.createTemp('sb_import_');
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

  group('§368 контейнер по числу узлов', () {
    test('одиночный outbound → UserServer (как было)', () async {
      final c = SubscriptionController();
      await c.addFromInput(singleOutbound);
      expect(c.lastError, isNull);
      final entry = c.entries.single;
      expect(entry.list, isA<UserServer>());
      expect(entry.list.nodes, hasLength(1));
    });

    test('полный конфиг → файловая подписка, а не UserServer', () async {
      final c = SubscriptionController();
      await c.addFromInput(wholeConfig);
      expect(c.lastError, isNull);

      final entry = c.entries.single;
      expect(entry.list, isA<SubscriptionServers>());
      final sub = entry.list as SubscriptionServers;
      // Файловая форма §129: свой url + авто-обновление выключено.
      expect(sub.url, startsWith('file:'));
      expect(sub.updateIntervalHours, -1);
    });

    test('конфиг: узлы, группа и цепочка доехали', () async {
      final c = SubscriptionController();
      await c.addFromInput(wholeConfig);

      final nodes = c.entries.single.list.nodes;
      // DE + NL + группа. `jump` — звено DE, служебный `direct` не в счёт.
      expect(nodes, hasLength(3));

      final de = nodes.firstWhere((n) => n.label == 'DE');
      expect(de.chained?.server, 'jump.example');

      final group = nodes.firstWhere((n) => n.isGroup);
      expect(group, isA<AutoSelectSpec>());
      expect(group.label, 'Fastest');
    });

    test('массив outbound\'ов → одна запись со всеми узлами', () async {
      final c = SubscriptionController();
      await c.addFromInput('['
          '{"type":"vless","tag":"a","server":"a.example",'
          '"server_port":443,"uuid":"u-a"},'
          '{"type":"vless","tag":"b","server":"b.example",'
          '"server_port":443,"uuid":"u-b"}'
          ']');
      expect(c.lastError, isNull);
      // Раньше массив раскладывался по записи на элемент («v1 parity»).
      expect(c.entries, hasLength(1));
      expect(c.entries.single.list.nodes, hasLength(2));
    });

    test('не-JSON → ошибка «не распознано», записей нет', () async {
      final c = SubscriptionController();
      await c.addFromInput('это не конфиг');
      expect(c.lastError, isNotNull);
      expect(c.entries, isEmpty);
    });

    test('JSON без пригодных outbound\'ов → своя ошибка, не «не распознано»',
        () async {
      final c = SubscriptionController();
      await c.addFromInput('{"outbounds":[{"type":"direct","tag":"d"}]}');
      expect(c.lastError, isNotNull);
      expect(c.lastError!.renderEn(),
          contains('No valid outbounds'));
      expect(c.entries, isEmpty);
    });
  });
}
