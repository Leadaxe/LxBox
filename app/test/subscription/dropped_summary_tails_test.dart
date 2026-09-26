// ignore_for_file: depend_on_referenced_packages

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:lxbox/controllers/subscription_controller.dart';
import 'package:lxbox/models/node_warning.dart';
import 'package:lxbox/models/server_list.dart';
import 'package:lxbox/services/parser/body_decoder.dart';
import 'package:lxbox/services/parser/parse_all.dart';
import 'package:lxbox/services/settings_storage.dart';
import 'package:lxbox/services/subscription/sources.dart';
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';
import 'package:plugin_platform_interface/plugin_platform_interface.dart';

import '../parser/engine_test_setup.dart';

/// §561 / §570 — данные сводки отбраковок источника: запись несёт владельца
/// (запись источника), одинаковые записи одного владельца сводятся, пустой
/// refresh кладёт свои причины в сводку.
class _FakePathProvider extends PathProviderPlatform
    with MockPlatformInterfaceMixin {
  final String tempRoot;
  _FakePathProvider(this.tempRoot);
  @override
  Future<String?> getApplicationSupportPath() async => '$tempRoot/support';
  @override
  Future<String?> getApplicationDocumentsPath() async => '$tempRoot/docs';
}

void main() {
  setUpAll(loadEngineSections);

  test('сводка: дубль (код, параметры, владелец) — одна запись', () {
    const a = RegistryWarning(
        code: 'scheme_unsupported', params: {'scheme': 'x'}, ownerTag: 'L1');
    const b = RegistryWarning(
        code: 'scheme_unsupported', params: {'scheme': 'x'}, ownerTag: 'L2');
    final out = summaryDropped([a, a, b]);
    expect([for (final w in out) w.ownerTag], ['L1', 'L2']);
  });

  test('контейнер .conf без узла — запись называет контейнер', () {
    const good = '[Interface]\n'
        'PrivateKey = AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA=\n'
        'Address = 10.0.0.2/32\n'
        '[Peer]\n'
        'PublicKey = AQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQE=\n'
        'AllowedIPs = 0.0.0.0/0\n'
        'Endpoint = a.example.com:51820\n';
    const bad = '[Interface]\nAddress = 10.0.0.3/32\n'
        '[Peer]\nEndpoint = b.example.com:51820\n';
    final dropped = <NodeWarning>[];
    final nodes =
        parseAll(const AmneziaConfig([good, bad]), nameHint: 'P', dropped: dropped);
    expect(nodes, hasLength(1));
    expect(dropped, isNotEmpty);
    expect(dropped.first.ownerTag, 'P 2');
  });

  group('пустой refresh', () {
    late Directory tempDir;

    setUp(() async {
      TestWidgetsFlutterBinding.ensureInitialized();
      tempDir = await Directory.systemTemp.createTemp('dropped_tails_');
      await Directory('${tempDir.path}/docs').create();
      await Directory('${tempDir.path}/support').create();
      PathProviderPlatform.instance = _FakePathProvider(tempDir.path);
      SettingsStorage.resetCacheForTesting();
      fetchBackoffsForTesting = const [Duration.zero, Duration.zero];
    });

    tearDown(() async {
      fetchBackoffsForTesting = null;
      try {
        if (tempDir.existsSync()) await tempDir.delete(recursive: true);
      } on FileSystemException {
        // гонка удаления temp — не предмет теста
      }
    });

    test('0 узлов: причины разбора — в сводке, узлы прежние', () async {
      await SettingsStorage.saveServerLists([
        SubscriptionServers(
          id: 's1',
          name: 's1',
          enabled: true,
          tagPrefix: '',
          detourPolicy: DetourPolicy.defaults,
          url: 'http://x/a',
        ),
      ]);
      final c = SubscriptionController();
      await c.init();
      await c.rehydrationDone;
      c.httpClientForTesting = MockClient((req) async => http.Response(
          'vless://uuid-1@h1.example:443?type=ws&security=tls#A1\n', 200));
      await c.refreshEntry(c.entries.single);
      expect(c.entries.single.nodeCount, 1);

      c.httpClientForTesting = MockClient((req) async => http.Response(
          'zzz://one\nzzz://two\n', 200));
      await c.refreshEntry(c.entries.single);
      final list = c.entries.single.list as SubscriptionServers;
      expect(list.nodes, hasLength(1), reason: 'узлы прошлого разбора живут');
      expect(list.lastUpdateStatus, UpdateStatus.failed);
      expect([for (final w in list.dropped) w.ownerTag],
          ['zzz://one', 'zzz://two']);
    });
  });
}
