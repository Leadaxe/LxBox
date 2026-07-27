import 'package:flutter/material.dart';

import '../services/crash_share.dart';
import '../services/format_utils.dart';
import '../services/l10n/locale_controller.dart';
import '../services/stderr_reader.dart';
import '../services/ui_helpers.dart';

/// §316 — история Go-паник ядра: список файлов, тап = поделиться.
///
/// Показываем архив `crash_reports/` плюс текущий репорт, если он непуст
/// (текущая сессия ещё не архивирована ядром — ядро перекладывает файл
/// только на следующем `Setup()`).
///
/// Оговорка (см. §3 спеки): `debug.SetCrashOutput` ловит ТОЛЬКО паники
/// Go-рантайма. JNI-abort, нативный SIGSEGV вне Go и kill системой сюда не
/// попадают — пустой список при наличии tombstone это сам по себе сигнал.
class CrashReportsScreen extends StatefulWidget {
  const CrashReportsScreen({super.key});

  @override
  State<CrashReportsScreen> createState() => _CrashReportsScreenState();
}

class _CrashReportsScreenState extends State<CrashReportsScreen>
    with SnackHelper {
  List<CrashReportFile>? _reports;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final list = await CrashReports.list();
    if (!mounted) return;
    setState(() => _reports = list);
  }

  Future<void> _share(CrashReportFile r) async {
    final ok = await shareCrashReport(r);
    if (!mounted || ok) return;
    showSnack(getLocalText.s("Share failed: %s", r.name));
  }

  @override
  Widget build(BuildContext context) {
    final reports = _reports;
    return Scaffold(
      appBar: AppBar(
        title: Text(getLocalText.s("Crash reports")),
        actions: [
          IconButton(
            icon: const Icon(Icons.refresh),
            tooltip: getLocalText.s("Refresh"),
            onPressed: _load,
          ),
        ],
      ),
      body: reports == null
          ? const Center(child: CircularProgressIndicator())
          : reports.isEmpty
              ? _buildEmpty(context)
              : _buildList(context, reports),
    );
  }

  /// Пустой список — хорошая новость, а не поломка экрана. Говорим это
  /// прямо, вместе с оговоркой про границу применимости.
  Widget _buildEmpty(BuildContext context) => Center(
        child: Padding(
          padding: const EdgeInsets.all(32),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(Icons.check_circle_outline,
                  size: 40, color: Theme.of(context).colorScheme.outline),
              const SizedBox(height: 12),
              Text(
                getLocalText.s("No crash reports"),
                style: Theme.of(context).textTheme.titleMedium,
              ),
              const SizedBox(height: 8),
              Text(
                getLocalText.s("The core has not panicked. Note that this channel only covers Go panics — native crashes and kills by the system are not recorded here."),
                textAlign: TextAlign.center,
                style: Theme.of(context).textTheme.bodySmall,
              ),
            ],
          ),
        ),
      );

  Widget _buildList(BuildContext context, List<CrashReportFile> reports) {
    return ListView.separated(
      itemCount: reports.length,
      separatorBuilder: (_, _) => const Divider(height: 1),
      itemBuilder: (context, i) {
        final r = reports[i];
        return ListTile(
          leading: Icon(
            r.isCurrent ? Icons.bug_report : Icons.bug_report_outlined,
            color: Theme.of(context).colorScheme.error,
          ),
          title: Text(formatDateTime(r.mtime)),
          subtitle: Text(
            r.isCurrent
                ? getLocalText.s("%s · current session", formatBytes(r.size))
                : formatBytes(r.size),
            style: const TextStyle(fontSize: 12),
          ),
          trailing: const Icon(Icons.ios_share, size: 20),
          onTap: () => _share(r),
        );
      },
    );
  }
}
