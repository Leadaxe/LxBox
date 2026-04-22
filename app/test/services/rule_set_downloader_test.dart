// ignore_for_file: depend_on_referenced_packages

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:lxbox/services/rule_set_downloader.dart';
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';
import 'package:plugin_platform_interface/plugin_platform_interface.dart';
import 'dart:io';

class _FakePathProvider extends PathProviderPlatform with MockPlatformInterfaceMixin {
  final String tempRoot;
  _FakePathProvider(this.tempRoot);
  @override
  Future<String?> getApplicationDocumentsPath() async => tempRoot;
}

void main() {
  late Directory tempDir;

  setUp(() async {
    TestWidgetsFlutterBinding.ensureInitialized();
    tempDir = await Directory.systemTemp.createTemp('rsd_test_');
    PathProviderPlatform.instance = _FakePathProvider(tempDir.path);
  });

  tearDown(() async {
    if (await tempDir.exists()) await tempDir.delete(recursive: true);
  });

  group('RuleSetDownloader.download retry (night T3-1)', () {
    test('3rd attempt succeeds after 2 transient 503s', () async {
      var attempts = 0;
      final client = MockClient((req) async {
        attempts++;
        if (attempts < 3) return http.Response('boom', 503);
        return http.Response.bytes([1, 2, 3, 4], 200);
      });
      final id = 'test-id-${DateTime.now().microsecondsSinceEpoch}';
      final path =
          await RuleSetDownloader.download(id, 'http://x/r.srs', client: client);
      expect(path, isNotNull);
      expect(attempts, 3);
      expect(await File(path!).readAsBytes(), [1, 2, 3, 4]);
    });

    test('404 → returns null immediately, no retry', () async {
      var attempts = 0;
      final client = MockClient((req) async {
        attempts++;
        return http.Response('gone', 404);
      });
      final id = 'test-id-${DateTime.now().microsecondsSinceEpoch}';
      final path =
          await RuleSetDownloader.download(id, 'http://x/r.srs', client: client);
      expect(path, isNull);
      expect(attempts, 1, reason: '4xx is permanent — no retry');
    });

    test('все 3 попытки 503 → null', () async {
      var attempts = 0;
      final client = MockClient((req) async {
        attempts++;
        return http.Response('x', 503);
      });
      final id = 'test-id-${DateTime.now().microsecondsSinceEpoch}';
      final path =
          await RuleSetDownloader.download(id, 'http://x/r.srs', client: client);
      expect(path, isNull);
      expect(attempts, 3);
    });

    test('empty body (200) → retries, eventually returns null', () async {
      var attempts = 0;
      final client = MockClient((req) async {
        attempts++;
        return http.Response.bytes([], 200);
      });
      final id = 'test-id-${DateTime.now().microsecondsSinceEpoch}';
      final path =
          await RuleSetDownloader.download(id, 'http://x/r.srs', client: client);
      expect(path, isNull);
      expect(attempts, 3);
    });
  });
}
