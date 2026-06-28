import 'dart:io';
import 'dart:typed_data';

import 'package:path_provider/path_provider.dart';

/// §207 — пишет goroutine-дамп / CPU-профиль во временные файлы для Share.
///
/// Параллель `DumpBuilder` (тот же temp-каталог + timestamp-формат), но без
/// сборки JSON-пака: goroutine-стеки и .pb-профиль шарятся отдельными
/// файлами (текст / бинарь), а не вкладываются в общий dump.
class ProfileDumpWriter {
  ProfileDumpWriter._();

  /// `goroutines-<ts>.txt` ← сырой вывод `runtime.Stack`. Возвращает path.
  static Future<String> writeGoroutines(String text) async {
    final file = File('${await _dir()}/goroutines-${_stamp()}.txt');
    await file.writeAsString(text);
    return file.path;
  }

  /// `cpu-<ts>.pb` ← pprof CPU-профиль (protobuf). Анализ: `go tool pprof`.
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
