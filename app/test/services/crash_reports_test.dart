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
    test('архив + текущий, новые первыми', () async {
      await write('$kCrashArchiveDir/old.log', 'a',
          mtime: DateTime.utc(2026, 1, 1));
      await write('$kCrashArchiveDir/mid.log', 'bb',
          mtime: DateTime.utc(2026, 3, 1));
      await write(kCrashReportBaseName, 'ccc',
          mtime: DateTime.utc(2026, 7, 1));

      final list = await CrashReports.list();
      expect(list.map((e) => e.name),
          [kCrashReportBaseName, 'mid.log', 'old.log']);
      expect(list.first.isCurrent, isTrue);
      expect(list.first.size, 3);
      expect(list[1].isCurrent, isFalse);
    });

    test('пустой текущий в список не попадает', () async {
      await write(kCrashReportBaseName, '');
      await write('$kCrashArchiveDir/old.log', 'a');
      final list = await CrashReports.list();
      expect(list.map((e) => e.name), ['old.log']);
    });

    test('без папки архива и без репорта → пусто', () async {
      expect(await CrashReports.list(), isEmpty);
    });
  });

  group('CrashReports.prune', () {
    test('оставляет 10 свежих, лишние удаляет', () async {
      for (var i = 0; i < 14; i++) {
        await write('$kCrashArchiveDir/c$i.log', 'x',
            mtime: DateTime.utc(2026, 1, 1 + i));
      }
      expect(await CrashReports.prune(), 4);

      final left = (await CrashReports.list()).map((e) => e.name).toSet();
      expect(left, hasLength(10));
      // Удалялись самые старые (c0..c3), свежие целы.
      expect(left, isNot(contains('c0.log')));
      expect(left, isNot(contains('c3.log')));
      expect(left, contains('c4.log'));
      expect(left, contains('c13.log'));
    });

    test('при ≤10 файлах не трогает ничего', () async {
      for (var i = 0; i < 10; i++) {
        await write('$kCrashArchiveDir/c$i.log', 'x');
      }
      expect(await CrashReports.prune(), 0);
      expect(await CrashReports.list(), hasLength(10));
    });

    test('текущий репорт ротация не трогает', () async {
      await write(kCrashReportBaseName, 'live');
      for (var i = 0; i < 12; i++) {
        await write('$kCrashArchiveDir/c$i.log', 'x',
            mtime: DateTime.utc(2026, 1, 1 + i));
      }
      await CrashReports.prune();
      expect(await StderrReader.read(), 'live');
    });
  });

  group('CrashBannerState — один раз на КРАШ', () {
    test('новый краш → показываем; повторный старт → молчим', () async {
      await write('$kCrashArchiveDir/boom.log', 'panic',
          mtime: DateTime.utc(2026, 7, 1));

      await CrashBannerState.I.refresh();
      expect(CrashBannerState.I.pending?.name, 'boom.log');

      await CrashBannerState.I.markShown();
      expect(CrashBannerState.I.pending, isNull);

      // Повторный запуск: тот же файл, отметка уже стоит.
      await CrashBannerState.I.refresh();
      expect(CrashBannerState.I.pending, isNull,
          reason: 'про этот краш уже сказали');
    });

    test('следующий (более свежий) краш → снова показываем', () async {
      await write('$kCrashArchiveDir/boom.log', 'panic',
          mtime: DateTime.utc(2026, 7, 1));
      await CrashBannerState.I.refresh();
      await CrashBannerState.I.markShown();

      await write('$kCrashArchiveDir/boom2.log', 'panic again',
          mtime: DateTime.utc(2026, 7, 20));
      await CrashBannerState.I.refresh();
      expect(CrashBannerState.I.pending?.name, 'boom2.log',
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
