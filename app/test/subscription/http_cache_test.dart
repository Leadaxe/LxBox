// ignore_for_file: depend_on_referenced_packages

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:lxbox/services/subscription/http_cache.dart';
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';
import 'package:plugin_platform_interface/plugin_platform_interface.dart';

class _FakePathProvider extends PathProviderPlatform with MockPlatformInterfaceMixin {
  final String tempRoot;
  _FakePathProvider(this.tempRoot);
  @override
  Future<String?> getApplicationSupportPath() async => tempRoot;
}

void main() {
  late Directory tempDir;

  setUp(() async {
    TestWidgetsFlutterBinding.ensureInitialized();
    tempDir = await Directory.systemTemp.createTemp('httpcache_test_');
    PathProviderPlatform.instance = _FakePathProvider(tempDir.path);
  });

  tearDown(() async {
    if (await tempDir.exists()) await tempDir.delete(recursive: true);
  });

  group('HttpCache (night T4-2)', () {
    test('save + loadBody round-trip', () async {
      await HttpCache.save(
          'http://x/sub', 'hello-body', {'x-hdr': 'v', 'ua': 'test'});
      expect(await HttpCache.loadBody('http://x/sub'), 'hello-body');
    });

    test('save + loadHeaders round-trip', () async {
      await HttpCache.save(
          'http://x/sub', 'b', {'x-hdr': 'v', 'Content-Type': 'text/plain'});
      final h = await HttpCache.loadHeaders('http://x/sub');
      expect(h, isNotNull);
      expect(h!['x-hdr'], 'v');
      expect(h['Content-Type'], 'text/plain');
    });

    test('loadBody неизвестного URL → null (miss)', () async {
      expect(await HttpCache.loadBody('http://never.seen/'), isNull);
    });

    test('loadHeaders без body-файла → null', () async {
      expect(await HttpCache.loadHeaders('http://never.seen/'), isNull);
    });

    test('разные URL не конфликтуют', () async {
      await HttpCache.save('http://a/', 'A', {'k': '1'});
      await HttpCache.save('http://b/', 'B', {'k': '2'});
      expect(await HttpCache.loadBody('http://a/'), 'A');
      expect(await HttpCache.loadBody('http://b/'), 'B');
      expect((await HttpCache.loadHeaders('http://a/'))!['k'], '1');
      expect((await HttpCache.loadHeaders('http://b/'))!['k'], '2');
    });

    test('повторный save перезаписывает', () async {
      await HttpCache.save('http://x/', 'v1', {'v': '1'});
      await HttpCache.save('http://x/', 'v2', {'v': '2'});
      expect(await HttpCache.loadBody('http://x/'), 'v2');
      expect((await HttpCache.loadHeaders('http://x/'))!['v'], '2');
    });
  });
}
