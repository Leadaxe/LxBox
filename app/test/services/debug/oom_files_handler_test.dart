// ignore_for_file: depend_on_referenced_packages

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:lxbox/services/debug/context.dart';
import 'package:lxbox/services/debug/contract/errors.dart';
import 'package:lxbox/services/debug/debug_registry.dart';
import 'package:lxbox/services/debug/handlers/files.dart';
import 'package:lxbox/services/debug/transport/request.dart';
import 'package:lxbox/services/debug/transport/response.dart';
import 'package:lxbox/services/oom_reports.dart' show kOomArchiveDir;
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';
import 'package:plugin_platform_interface/plugin_platform_interface.dart';

class _FakePathProvider extends PathProviderPlatform
    with MockPlatformInterfaceMixin {
  _FakePathProvider(this.root);
  final String root;
  @override
  Future<String?> getApplicationDocumentsPath() async => root;
}

/// §318 — OOM-снимки ядра через Debug API. Симметрия с `/files/crash/*`
/// (§316): список + пофайловая выдача каталога с гейтом от traversal.
void main() {
  late Directory tempDir;

  setUp(() async {
    TestWidgetsFlutterBinding.ensureInitialized();
    tempDir = await Directory.systemTemp.createTemp('oomfiles_test_');
    PathProviderPlatform.instance = _FakePathProvider(tempDir.path);
  });

  tearDown(() async {
    if (await tempDir.exists()) await tempDir.delete(recursive: true);
  });

  DebugContext ctx() => DebugContext(
        registry: DebugRegistry.I,
        appStartedAt: DateTime.utc(2020),
      );

  DebugRequest get(String pathAndQuery) => DebugRequest(
        method: 'GET',
        uri: Uri.parse('http://127.0.0.1:9269$pathAndQuery'),
        headers: const {},
        body: Uint8List(0),
        receivedAt: DateTime.utc(2026),
      );

  Future<void> writeSnapshot(String name, {DateTime? mtime}) async {
    final dir = Directory('${tempDir.path}/$kOomArchiveDir/$name');
    await dir.create(recursive: true);
    await File('${dir.path}/heap.pb').writeAsBytes([1, 2, 3, 4]);
    await File('${dir.path}/go.log').writeAsString('core log line');
    final meta = File('${dir.path}/metadata.json');
    await meta.writeAsString(jsonEncode({
      'coreVersion': '1.14.0-lx.3',
      'memoryUsage': '440 MB',
      'heapInuse': '123 MB',
      'numGoroutine': '424',
    }));
    if (mtime != null) await meta.setLastModified(mtime);
  }

  group('§318 — /files/oom/list', () {
    test('новые первыми, с memstats-полями', () async {
      await writeSnapshot('2026-06-27T00-00-41',
          mtime: DateTime.utc(2026, 6, 27));
      await writeSnapshot('2026-07-15T07-15-32',
          mtime: DateTime.utc(2026, 7, 15));

      final resp = await filesHandler(get('/files/oom/list'), ctx());
      final body = (resp as JsonResponse).body as List;

      expect(body, hasLength(2));
      final first = body.first as Map;
      expect(first['name'], '2026-07-15T07-15-32');
      expect(first['memory_usage'], '440 MB');
      expect(first['heap_inuse'], '123 MB');
      expect(first['num_goroutine'], 424);
      expect(first['core_version'], '1.14.0-lx.3');
      // size — весь каталог: heap.pb + go.log + metadata.json.
      expect(first['size'], greaterThan(4));
    });

    test('без папки → [] (killer не срабатывал — не ошибка)', () async {
      final resp = await filesHandler(get('/files/oom/list'), ctx());
      expect((resp as JsonResponse).body, isEmpty);
    });
  });

  group('§318 — /files/oom', () {
    test('по умолчанию отдаётся metadata.json', () async {
      await writeSnapshot('2026-07-15T07-15-32');

      final resp = await filesHandler(
          get('/files/oom?name=2026-07-15T07-15-32'), ctx());
      final text =
          String.fromCharCodes((resp as BytesResponse).bytes);

      expect(text, contains('440 MB'));
    });

    test('&file= отдаёт конкретный профиль', () async {
      await writeSnapshot('2026-07-15T07-15-32');

      final resp = await filesHandler(
          get('/files/oom?name=2026-07-15T07-15-32&file=heap.pb'), ctx());

      expect((resp as BytesResponse).bytes, [1, 2, 3, 4]);
      expect(resp.filename, '2026-07-15T07-15-32-heap.pb');
    });

    test('несуществующий снимок → 404', () async {
      await expectLater(
        filesHandler(get('/files/oom?name=ghost'), ctx()),
        throwsA(isA<NotFound>()),
      );
    });

    test('traversal в &file= отвергается', () async {
      await writeSnapshot('2026-07-15T07-15-32');
      await File('${tempDir.path}/cache.db').writeAsString('secret');

      await expectLater(
        filesHandler(
            get('/files/oom?name=2026-07-15T07-15-32&file=${Uri.encodeComponent("../../cache.db")}'),
            ctx()),
        throwsA(isA<BadRequest>()),
      );
    });

    for (final bad in ['../evil', 'a/b', r'a\b', '.hidden']) {
      test('«$bad» отвергается на /files/oom', () async {
        await expectLater(
          filesHandler(
              get('/files/oom?name=${Uri.encodeComponent(bad)}'), ctx()),
          throwsA(isA<BadRequest>()),
        );
      });
    }
  });
}
