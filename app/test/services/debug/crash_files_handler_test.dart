// ignore_for_file: depend_on_referenced_packages

import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:lxbox/services/debug/context.dart';
import 'package:lxbox/services/debug/contract/errors.dart';
import 'package:lxbox/services/debug/debug_registry.dart';
import 'package:lxbox/services/debug/handlers/files.dart';
import 'package:lxbox/services/debug/transport/request.dart';
import 'package:lxbox/services/debug/transport/response.dart';
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';
import 'package:plugin_platform_interface/plugin_platform_interface.dart';

class _FakePathProvider extends PathProviderPlatform
    with MockPlatformInterfaceMixin {
  _FakePathProvider(this.root);
  final String root;
  @override
  Future<String?> getApplicationDocumentsPath() async => root;
}

/// §316 — доступ к краш-репортам ядра (Go-паники) через Debug API.
/// Файлы физически лежали в `filesDir` (ядро пишет их само), но не были
/// ни в whitelist `/files/local`, ни доступны из архивной подпапки.
void main() {
  late Directory tempDir;

  setUp(() async {
    TestWidgetsFlutterBinding.ensureInitialized();
    tempDir = await Directory.systemTemp.createTemp('crashfiles_test_');
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

  Future<File> writeFile(String relative, String content) async {
    final f = File('${tempDir.path}/$relative');
    await f.parent.create(recursive: true);
    await f.writeAsString(content);
    return f;
  }

  group('§316 — текущий краш-репорт через /files/local', () {
    test('CrashReport-lxbox.log отдаётся (был не в whitelist — корень §316)',
        () async {
      await writeFile(kCrashReportBaseName,
          'panic: runtime error: index out of range [3]');
      final resp =
          await filesHandler(get('/files/local?name=$kCrashReportBaseName'), ctx());
      expect(resp, isA<BytesResponse>());
      expect(String.fromCharCodes((resp as BytesResponse).bytes),
          contains('panic: runtime error'));
    });

    test('.old-вариант тоже в whitelist', () async {
      await writeFile('$kCrashReportBaseName.old', 'previous panic');
      final resp = await filesHandler(
          get('/files/local?name=$kCrashReportBaseName.old'), ctx());
      expect(String.fromCharCodes((resp as BytesResponse).bytes),
          'previous panic');
    });

    test('не-whitelist имя → 404, даже если файл существует', () async {
      await writeFile('secrets.json', '{}');
      await expectLater(
        filesHandler(get('/files/local?name=secrets.json'), ctx()),
        throwsA(isA<NotFound>()),
      );
    });
  });

  group('§316 — архив /files/crash', () {
    test('list: новые первыми, поля name/size/mtime', () async {
      final older = await writeFile('crash_reports/old.log', 'aa');
      final newer = await writeFile('crash_reports/new.log', 'bbbb');
      // Явные mtime — порядок обхода FS не гарантирован.
      await older.setLastModified(DateTime.utc(2026, 1, 1));
      await newer.setLastModified(DateTime.utc(2026, 6, 1));

      final resp = await filesHandler(get('/files/crash/list'), ctx());
      final body = (resp as JsonResponse).body as List;
      expect(body, hasLength(2));
      expect((body.first as Map)['name'], 'new.log',
          reason: 'сортировка по mtime — новые первыми');
      expect((body.first as Map)['size'], 4);
      expect((body.last as Map)['name'], 'old.log');
      expect((body.first as Map)['mtime'], isA<String>());
    });

    test('list без папки → [] (крашей не было — не ошибка)', () async {
      final resp = await filesHandler(get('/files/crash/list'), ctx());
      expect((resp as JsonResponse).body, isEmpty);
    });

    test('тело архивного репорта отдаётся', () async {
      await writeFile('crash_reports/boom.log', 'goroutine 1 [running]:');
      final resp =
          await filesHandler(get('/files/crash?name=boom.log'), ctx());
      expect(String.fromCharCodes((resp as BytesResponse).bytes),
          contains('goroutine 1'));
    });

    test('несуществующее имя → 404', () async {
      await expectLater(
        filesHandler(get('/files/crash?name=ghost.log'), ctx()),
        throwsA(isA<NotFound>()),
      );
    });
  });

  group('§316 — path traversal', () {
    // Подпапка задаётся сервером; клиент передаёт только basename. Гейт
    // общий с /files/local — ослаблять его ради «удобных путей» нельзя.
    for (final bad in ['../cache.db', 'a/b.log', r'a\b.log', '.hidden']) {
      test('«$bad» отвергается на /files/crash', () async {
        await expectLater(
          filesHandler(get('/files/crash?name=${Uri.encodeComponent(bad)}'),
              ctx()),
          throwsA(isA<BadRequest>()),
        );
      });
    }

    test('traversal на /files/local тоже отвергается', () async {
      await expectLater(
        filesHandler(
            get('/files/local?name=${Uri.encodeComponent("../cache.db")}'),
            ctx()),
        throwsA(isA<BadRequest>()),
      );
    });
  });
}
