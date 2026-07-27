import 'dart:io';

import 'package:share_plus/share_plus.dart';

import 'stderr_reader.dart';

/// §316 — системный share одного краш-репорта ядра.
///
/// Общий для плашки на главном и экрана «Crash reports»: и там, и там
/// пользователь делает ровно одно — отдаёт репорт. Архивный репорт это
/// КАТАЛОГ из трёх файлов (трейс + метаданные + конфиг на момент падения) —
/// отдаём все, потому что версия ядра и конфиг для разбора нужны не меньше
/// самого трейса. Возвращает `false`, если поделиться не вышло (файлы
/// исчезли / share упал) — вызывающий решает, показывать ли снекбар.
Future<bool> shareCrashReport(CrashReportFile report) async {
  try {
    final files = <XFile>[];
    final dir = report.dirPath;
    if (dir != null) {
      // Имя файла префиксуем таймстампом каталога: в чужой переписке три
      // одинаковых `go.log` из разных падений не различить.
      await for (final e in Directory(dir).list(followLinks: false)) {
        if (e is! File) continue;
        final base = e.uri.pathSegments.last;
        files.add(XFile(e.path,
            name: '${report.name}-$base', mimeType: _mimeOf(base)));
      }
      files.sort((a, b) => (a.name).compareTo(b.name));
    }
    if (files.isEmpty) {
      files.add(XFile(report.path,
          name: report.name, mimeType: 'text/plain'));
    }
    // ignore: deprecated_member_use
    await Share.shareXFiles(
      files,
      subject: 'L×Box core crash — ${report.mtime.toIso8601String()}',
    );
    return true;
  } catch (_) {
    return false;
  }
}

String _mimeOf(String name) =>
    name.endsWith('.json') ? 'application/json' : 'text/plain';
