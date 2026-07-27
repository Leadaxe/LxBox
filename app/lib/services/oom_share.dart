import 'dart:io';

import 'package:share_plus/share_plus.dart';

import 'oom_reports.dart';

/// §318 — системный share одного OOM-снимка ядра.
///
/// Отдаём КАТАЛОГ целиком, а не только метаданные: ценность снимка в
/// pprof-профилях (`heap.pb`, `allocs.pb`, `goroutine.pb`) — их открывают в
/// `go tool pprof`, и без них цифры memstats ничего не объясняют. Конфиг и
/// `connections.json` нужны, чтобы понять, на какой нагрузке ядро упёрлось
/// в лимит.
///
/// Возвращает `false`, если поделиться не вышло (файлы исчезли / share
/// упал) — вызывающий решает, показывать ли снекбар.
Future<bool> shareOomReport(OomReportFile report) async {
  try {
    final files = <XFile>[];
    await for (final e
        in Directory(report.dirPath).list(followLinks: false)) {
      if (e is! File) continue;
      final base = e.uri.pathSegments.last;
      // Имя префиксуем таймстампом снимка: в чужой переписке несколько
      // одинаковых `heap.pb` из разных снимков не различить.
      files.add(XFile(e.path,
          name: '${report.name}-$base', mimeType: _mimeOf(base)));
    }
    if (files.isEmpty) return false;
    files.sort((a, b) => (a.name).compareTo(b.name));
    // ignore: deprecated_member_use
    await Share.shareXFiles(
      files,
      subject: 'L×Box core OOM report — ${report.mtime.toIso8601String()}',
    );
    return true;
  } catch (_) {
    return false;
  }
}

/// pprof-профили бинарные — отдаём их octet-stream'ом, иначе почтовые
/// клиенты пытаются показать их текстом и портят содержимое.
String _mimeOf(String name) {
  if (name.endsWith('.pb')) return 'application/octet-stream';
  if (name.endsWith('.json')) return 'application/json';
  return 'text/plain';
}
