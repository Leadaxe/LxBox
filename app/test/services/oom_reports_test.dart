// ignore_for_file: depend_on_referenced_packages

import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:lxbox/services/oom_reports.dart';
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';
import 'package:plugin_platform_interface/plugin_platform_interface.dart';

class _FakePathProvider extends PathProviderPlatform
    with MockPlatformInterfaceMixin {
  _FakePathProvider(this.root);
  final String root;
  @override
  Future<String?> getApplicationDocumentsPath() async => root;
}

/// §318 — OOM-снимки ядра: список, размер каталога, ротация, очистка.
///
/// Базу резолвит `CrashReports.baseDir()`; в тестах MethodChannel не поднят,
/// поэтому `getFilesDir()` отдаёт null и срабатывает fallback на
/// path_provider — его и подменяем.
void main() {
  late Directory tempDir;

  setUp(() async {
    TestWidgetsFlutterBinding.ensureInitialized();
    tempDir = await Directory.systemTemp.createTemp('oom_reports_test_');
    PathProviderPlatform.instance = _FakePathProvider(tempDir.path);
  });

  tearDown(() async {
    if (await tempDir.exists()) await tempDir.delete(recursive: true);
  });

  /// Снимок как его кладёт ядро: каталог с metadata.json + профилями.
  Future<Directory> writeSnapshot(
    String name, {
    DateTime? mtime,
    Map<String, Object?>? meta,
    int profileBytes = 0,
    bool withMeta = true,
  }) async {
    final dir = Directory('${tempDir.path}/$kOomArchiveDir/$name');
    await dir.create(recursive: true);
    if (profileBytes > 0) {
      await File('${dir.path}/heap.pb')
          .writeAsBytes(List.filled(profileBytes, 0));
    }
    if (withMeta) {
      final f = File('${dir.path}/$kOomMetaName');
      await f.writeAsString(jsonEncode(meta ??
          {
            'coreVersion': '1.14.0-lx.3',
            'memoryUsage': '440 MB',
            'heapInuse': '123 MB',
            'numGoroutine': '424',
          }));
      if (mtime != null) await f.setLastModified(mtime);
    }
    return dir;
  }

  group('§318 — список снимков', () {
    test('новые первыми, поля из metadata.json разобраны', () async {
      await writeSnapshot('2026-06-27T00-00-41',
          mtime: DateTime.utc(2026, 6, 27));
      await writeSnapshot('2026-07-15T07-15-32',
          mtime: DateTime.utc(2026, 7, 15));

      final list = await OomReports.list();

      expect(list, hasLength(2));
      expect(list.first.name, '2026-07-15T07-15-32',
          reason: 'сортировка по mtime — новые первыми');
      expect(list.first.coreVersion, '1.14.0-lx.3');
      expect(list.first.memoryUsage, '440 MB');
      expect(list.first.heapInuse, '123 MB');
      // numGoroutine приходит строкой (`json:",string"` в Go-структуре).
      expect(list.first.numGoroutine, 424);
      expect(list.first.dirPath, endsWith('2026-07-15T07-15-32'));
    });

    test('size — размер ВСЕГО каталога, а не metadata.json', () async {
      await writeSnapshot('2026-07-15T07-15-32', profileBytes: 4096);

      final list = await OomReports.list();

      // Вес снимка несут профили: если бы считали только головной файл,
      // пользователь видел бы полкилобайта вместо мегабайтов.
      expect(list.single.size, greaterThan(4096));
    });

    test('каталог без metadata.json пропускается (недописанный снимок)',
        () async {
      await writeSnapshot('2026-07-15T07-15-32',
          withMeta: false, profileBytes: 128);

      expect(await OomReports.list(), isEmpty);
    });

    test('битый metadata.json — снимок показываем, поля пустые', () async {
      final dir =
          Directory('${tempDir.path}/$kOomArchiveDir/2026-07-15T07-15-32');
      await dir.create(recursive: true);
      await File('${dir.path}/$kOomMetaName').writeAsString('{not json');

      final list = await OomReports.list();

      expect(list, hasLength(1), reason: 'профили в снимке целы');
      expect(list.single.memoryUsage, isNull);
    });

    test('без папки → пустой список (killer не срабатывал)', () async {
      expect(await OomReports.list(), isEmpty);
    });

    test('numGoroutine числом тоже разбирается', () async {
      await writeSnapshot('2026-07-15T07-15-32', meta: {'numGoroutine': 42});

      expect((await OomReports.list()).single.numGoroutine, 42);
    });
  });

  group('§318 — totalSize', () {
    test('сумма по всем снимкам', () async {
      await writeSnapshot('a', profileBytes: 1000);
      await writeSnapshot('b', profileBytes: 2000);

      final total = await OomReports.totalSize();
      final list = await OomReports.list();

      expect(total, list.fold<int>(0, (sum, r) => sum + r.size));
      expect(total, greaterThan(3000));
    });

    test('пустой архив → 0', () async {
      expect(await OomReports.totalSize(), 0);
    });
  });

  group('§318 — ротация', () {
    test('оставляет keep свежих, удаляет остальные', () async {
      for (var day = 1; day <= 5; day++) {
        await writeSnapshot('2026-07-0$day',
            mtime: DateTime.utc(2026, 7, day));
      }

      final removed = await OomReports.prune(keep: 2);

      expect(removed, 3);
      final left = await OomReports.list();
      expect(left.map((r) => r.name), ['2026-07-05', '2026-07-04'],
          reason: 'удаляются самые старые');
      // Каталог удалён целиком, а не только головной файл.
      expect(
          await Directory('${tempDir.path}/$kOomArchiveDir/2026-07-01')
              .exists(),
          isFalse);
    });

    test('снимков не больше keep → ничего не трогаем', () async {
      await writeSnapshot('2026-07-01');

      expect(await OomReports.prune(keep: 5), 0);
      expect(await OomReports.list(), hasLength(1));
    });

    test('без папки не падает', () async {
      expect(await OomReports.prune(), 0);
    });
  });

  group('§318 — очистка', () {
    test('clear удаляет все снимки', () async {
      await writeSnapshot('a', profileBytes: 100);
      await writeSnapshot('b', profileBytes: 100);

      expect(await OomReports.clear(), 2);
      expect(await OomReports.list(), isEmpty);
    });

    test('clear на пустом архиве → 0', () async {
      expect(await OomReports.clear(), 0);
    });
  });
}
