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

    test('§101 — save атомарен: .tmp-резидуалов не остаётся', () async {
      await HttpCache.save('http://x/', 'body', {'h': 'v'});
      final files = Directory('${tempDir.path}/sub_cache')
          .listSync()
          .map((f) => f.path)
          .toList();
      expect(files.where((p) => p.endsWith('.tmp')), isEmpty);
      expect(await HttpCache.loadBody('http://x/'), 'body');
    });
  });

  group('§603 — ключ sha256 и перенос старого ключа', () {
    test('ключ = sha256(url) hex, не hashCode', () {
      expect(HttpCache.keyFor('abc'),
          'ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad');
      expect(HttpCache.keyFor('https://x/sub'),
          isNot(HttpCache.legacyKeyFor('https://x/sub')));
    });

    test('файлы старого ключа читаются и переезжают под новый', () async {
      const url = 'https://old.example/sub';
      final dir = Directory('${tempDir.path}/sub_cache')
        ..createSync(recursive: true);
      final legacy = HttpCache.legacyKeyFor(url);
      File('${dir.path}/$legacy').writeAsStringSync('old-body');
      File('${dir.path}/$legacy.headers').writeAsStringSync('{"a":"b"}');

      expect(await HttpCache.loadBody(url), 'old-body');
      expect(await HttpCache.loadHeaders(url), {'a': 'b'});
      expect(File('${dir.path}/$legacy').existsSync(), isFalse);
      expect(File('${dir.path}/$legacy.headers').existsSync(), isFalse);
      expect(File('${dir.path}/${HttpCache.keyFor(url)}').readAsStringSync(),
          'old-body');
    });

    test('remove чистит и старый ключ', () async {
      const url = 'https://old.example/sub';
      final dir = Directory('${tempDir.path}/sub_cache')
        ..createSync(recursive: true);
      File('${dir.path}/${HttpCache.legacyKeyFor(url)}')
          .writeAsStringSync('old-body');
      await HttpCache.remove(url);
      expect(dir.listSync(), isEmpty);
    });
  });
}
