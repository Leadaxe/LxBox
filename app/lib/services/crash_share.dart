import 'package:share_plus/share_plus.dart';

import 'stderr_reader.dart';

/// §316 — системный share одного краш-репорта ядра.
///
/// Общий для плашки на главном и экрана «Crash reports»: и там, и там
/// пользователь делает ровно одно — отдаёт файл. Возвращает `false`, если
/// поделиться не вышло (файл исчез / share упал) — вызывающий решает,
/// показывать ли снекбар.
Future<bool> shareCrashReport(CrashReportFile report) async {
  try {
    // ignore: deprecated_member_use
    await Share.shareXFiles(
      [XFile(report.path, name: report.name, mimeType: 'text/plain')],
      subject: 'L×Box core crash — ${report.mtime.toIso8601String()}',
    );
    return true;
  } catch (_) {
    return false;
  }
}
