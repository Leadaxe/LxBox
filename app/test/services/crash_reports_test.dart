// ignore_for_file: depend_on_referenced_packages

import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lxbox/services/crash_banner_state.dart';
import 'package:lxbox/services/settings_storage.dart';
import 'package:lxbox/services/stderr_reader.dart';

/// §316 (пользовательская половина) — история краш-репортов ядра: чтение
/// правильного файла, список, ротация, одноразовость плашки.
void main() {
  late Directory tempDir;
  const pathChannel = MethodChannel('plugins.flutter.io/path_provider');

  setUp(() async {
    TestWidgetsFlutterBinding.ensureInitialized();
    tempDir = await Directory.systemTemp.createTemp('crash_reports_test_');
    // На устройстве базу даёт native `getFilesDir`; в тестах MethodChannel
    // ядра не поднят → `CrashReports.baseDir()` падает на Dart-путь, его и
    // подменяем. Заодно тут же живёт storage (отметка показанного краша).
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(pathChannel, (call) async {
      if (call.method == 'getApplicationDocumentsDirectory' ||
          call.method == 'getApplicationDocumentsPath') {
        return tempDir.path;
      }
      return null;
    });
    SettingsStorage.resetCacheForTesting();
    CrashBannerState.I.resetForTest();
  });

  tearDown(() async {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(pathChannel, null);
    try {
      if (tempDir.existsSync()) await tempDir.delete(recursive: true);
    } on FileSystemException {
      // AppLog пишет persistent-лог в ту же папку async — race с delete.
    }
  });

  Future<File> write(String relative, String content, {DateTime? mtime}) async {
    final f = File('${tempDir.path}/$relative');
    await f.parent.create(recursive: true);
    await f.writeAsString(content);
    if (mtime != null) await f.setLastModified(mtime);
    return f;
  }

  /// Репорт в том виде, в каком его кладёт ЯДРО: каталог-таймстамп с
  /// `go.log` + `metadata.json` + `configuration.json` внутри.
  /// Device-verified 27.07.2026 — до этого код ждал плоский файл и молча
  /// отдавал пустой список при полном архиве.
  Future<void> writeReport(
    String stamp, {
    String trace = 'panic',
    String? coreVersion,
    DateTime? mtime,
  }) async {
    final dir = '$kCrashArchiveDir/$stamp';
    await write('$dir/$kCrashTraceName', trace, mtime: mtime);
    await write(
        '$dir/$kCrashMetaName',
        '{"source":"lxbox","coreVersion":"${coreVersion ?? '1.14.0-lx.16'}",'
            '"crashedAt":"2026-07-26T22:26:00Z"}');
    await write('$dir/configuration.json', '{}');
  }

  group('StderrReader — читаем CrashReport, а не stderr.log', () {
    test('берёт CrashReport-lxbox.log', () async {
      await write(kCrashReportBaseName, 'panic: boom');
      expect(await StderrReader.read(), 'panic: boom');
    });

    test('stderr.log игнорируется даже если существует (фоллбэка нет)',
        () async {
      // Имя из схемы до libbox 1.14. Ядро его больше не пишет; тянуть
      // мёртвое имя фоллбэком — решение юзера «не делать».
      await write('stderr.log', 'legacy panic');
      expect(await StderrReader.read(), isNull);
      expect(await StderrReader.path(), isNull);
    });

    test('пустой файл = «паник не было» (ядро пересоздаёт его на Setup)',
        () async {
      await write(kCrashReportBaseName, '');
      expect(await StderrReader.read(), isNull);
    });
  });

  group('CrashReports.list', () {
    test('репорты-каталоги ядра видны, новые первыми', () async {
      await writeReport('2026-01-01T00-00-00',
          trace: 'a', mtime: DateTime.utc(2026, 1, 1));
      await writeReport('2026-03-01T00-00-00',
          trace: 'bb', mtime: DateTime.utc(2026, 3, 1));
      await write(kCrashReportBaseName, 'ccc',
          mtime: DateTime.utc(2026, 7, 1));

      final list = await CrashReports.list();
      expect(list.map((e) => e.name), [
        kCrashReportBaseName,
        '2026-03-01T00-00-00',
        '2026-01-01T00-00-00',
      ]);
      expect(list.first.isCurrent, isTrue);
      expect(list[1].isCurrent, isFalse);
      expect(list[1].size, 2, reason: 'размер go.log, а не каталога');
      expect(list[1].path, endsWith(kCrashTraceName));
      expect(list[1].dirPath, isNotNull);
    });

    test('coreVersion читается из metadata.json', () async {
      await writeReport('2026-07-26T22-26-00', coreVersion: '1.14.0-lx.16-rc.3');
      final list = await CrashReports.list();
      expect(list.single.coreVersion, '1.14.0-lx.16-rc.3');
    });

    test('каталог без go.log пропускается (не репорт)', () async {
      await write('$kCrashArchiveDir/2026-07-26T00-00-00/configuration.json',
          '{}');
      expect(await CrashReports.list(), isEmpty);
    });

    test('плоский файл (ранние сборки ядра) тоже виден', () async {
      await write('$kCrashArchiveDir/old.log', 'legacy');
      final list = await CrashReports.list();
      expect(list.single.name, 'old.log');
      expect(list.single.dirPath, isNull);
    });

    test('пустой текущий в список не попадает', () async {
      await write(kCrashReportBaseName, '');
      await writeReport('2026-07-26T00-00-00');
      final list = await CrashReports.list();
      expect(list.map((e) => e.name), ['2026-07-26T00-00-00']);
    });

    test('без папки архива и без репорта → пусто', () async {
      expect(await CrashReports.list(), isEmpty);
    });
  });

  group('CrashReports.prune', () {
    test('оставляет 10 свежих, лишние каталоги удаляет целиком', () async {
      for (var i = 0; i < 14; i++) {
        await writeReport('c$i', mtime: DateTime.utc(2026, 1, 1 + i));
      }
      expect(await CrashReports.prune(), 4);

      final left = (await CrashReports.list()).map((e) => e.name).toSet();
      expect(left, hasLength(10));
      // Удалялись самые старые (c0..c3), свежие целы.
      expect(left, isNot(contains('c0')));
      expect(left, isNot(contains('c3')));
      expect(left, contains('c4'));
      expect(left, contains('c13'));
      // Каталог сносится целиком, а не только go.log — иначе остаётся
      // мусор из metadata/configuration, который уже ничего не значит.
      expect(
          Directory('${tempDir.path}/$kCrashArchiveDir/c0').existsSync(),
          isFalse);
    });

    test('при ≤10 репортах не трогает ничего', () async {
      for (var i = 0; i < 10; i++) {
        await writeReport('c$i');
      }
      expect(await CrashReports.prune(), 0);
      expect(await CrashReports.list(), hasLength(10));
    });

    test('текущий репорт ротация не трогает', () async {
      await write(kCrashReportBaseName, 'live');
      for (var i = 0; i < 12; i++) {
        await writeReport('c$i', mtime: DateTime.utc(2026, 1, 1 + i));
      }
      await CrashReports.prune();
      expect(await StderrReader.read(), 'live');
    });
  });

  group('CrashBannerState — один раз на КРАШ', () {
    test('новый краш → показываем; повторный старт → молчим', () async {
      await writeReport('2026-07-01T00-00-00', mtime: DateTime.utc(2026, 7, 1));

      await CrashBannerState.I.refresh();
      expect(CrashBannerState.I.pending?.name, '2026-07-01T00-00-00');

      await CrashBannerState.I.markShown();
      expect(CrashBannerState.I.pending, isNull);

      // Повторный запуск: тот же файл, отметка уже стоит.
      await CrashBannerState.I.refresh();
      expect(CrashBannerState.I.pending, isNull,
          reason: 'про этот краш уже сказали');
    });

    test('следующий (более свежий) краш → снова показываем', () async {
      await writeReport('2026-07-01T00-00-00', mtime: DateTime.utc(2026, 7, 1));
      await CrashBannerState.I.refresh();
      await CrashBannerState.I.markShown();

      await writeReport('2026-07-20T00-00-00', mtime: DateTime.utc(2026, 7, 20));
      await CrashBannerState.I.refresh();
      expect(CrashBannerState.I.pending?.name, '2026-07-20T00-00-00',
          reason: 'отметка привязана к файлу, а не к факту показа');
    });

    test('крашей нет → плашки нет', () async {
      await CrashBannerState.I.refresh();
      expect(CrashBannerState.I.pending, isNull);
    });

    test('markShown без pending — no-op (не затирает отметку пустотой)',
        () async {
      await CrashBannerState.I.markShown();
      expect(await SettingsStorage.getShownCrashStamp(), isEmpty);
    });
  });
}
