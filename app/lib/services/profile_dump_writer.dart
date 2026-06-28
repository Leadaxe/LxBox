import 'dart:io';
import 'dart:typed_data';

import 'package:path_provider/path_provider.dart';

import '../vpn/pprof_profile.dart';

/// §207 — пишет pprof-слепки во временные файлы для Share.
///
/// Параллель `DumpBuilder` (тот же temp-каталог + timestamp-формат), но без
/// сборки JSON-пака: каждый профиль шарится отдельным файлом. Имя и
/// расширение берёт из дескриптора [PprofProfile] (`goroutine` → `.txt`,
/// остальные → `.pb` под `go tool pprof`).
class ProfileDumpWriter {
  ProfileDumpWriter._();

  /// Запись pprof-слепка по дескриптору. Имя = `<fileBase>-<ts>.<ext>`.
  static Future<String> writeProfile(PprofProfile p, Uint8List bytes) async {
    final file = File('${await _dir()}/${p.fileBase}-${_stamp()}.${p.fileExt}');
    await file.writeAsBytes(bytes);
    return file.path;
  }

  /// `goroutines-<ts>.txt` ← сырой вывод `runtime.Stack` (текст). Используется
  /// напрямую (DumpBuilder / Debug-экран) с уже-декодированной строкой.
  static Future<String> writeGoroutines(String text) async {
    final file = File('${await _dir()}/goroutines-${_stamp()}.txt');
    await file.writeAsString(text);
    return file.path;
  }

  /// `cpu-<ts>.pb` ← pprof CPU-профиль (бинарь). Анализ: `go tool pprof`.
  static Future<String> writeCpuProfile(Uint8List bytes) async {
    final file = File('${await _dir()}/cpu-${_stamp()}.pb');
    await file.writeAsBytes(bytes);
    return file.path;
  }

  static Future<String> _dir() async =>
      (await getTemporaryDirectory()).path;

  /// `2026-06-28T18-30-05` — как в [DumpBuilder]: ISO без двоеточий, 19 симв.
  static String _stamp() =>
      DateTime.now().toIso8601String().replaceAll(':', '-').substring(0, 19);
}
