import 'dart:io';

import 'package:flutter/material.dart';

import '../services/crash_share.dart';
import '../services/format_utils.dart';
import '../services/l10n/locale_controller.dart';
import '../services/stderr_reader.dart';
import '../services/ui_helpers.dart';

/// §316 — вкладка «Crashes» на экране Debug: история Go-паник ядра.
///
/// Показываем архив `crash_reports/` плюс текущий репорт, если он непуст
/// (текущая сессия ещё не архивирована ядром — оно перекладывает файл
/// только на следующем `Setup()`).
///
/// Оговорка (см. §3 спеки): `debug.SetCrashOutput` ловит ТОЛЬКО паники
/// Go-рантайма. JNI-abort, нативный SIGSEGV вне Go и kill системой сюда не
/// попадают — пустой список при наличии tombstone это сам по себе сигнал.
class CrashReportsTab extends StatefulWidget {
  const CrashReportsTab({super.key});

  @override
  State<CrashReportsTab> createState() => _CrashReportsTabState();
}

class _CrashReportsTabState extends State<CrashReportsTab>
    with SnackHelper, AutomaticKeepAliveClientMixin {
  List<CrashReportFile>? _reports;

  @override
  bool get wantKeepAlive => true;

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
    super.build(context);
    final reports = _reports;
    if (reports == null) {
      return const Center(child: CircularProgressIndicator());
    }
    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(12, 8, 12, 0),
          child: Row(
            children: [
              Expanded(
                child: Text(
                  getLocalText.s("Go panics of the sing-box core. Survives SIGABRT — tap a report to share it."),
                  style: Theme.of(context).textTheme.bodySmall,
                ),
              ),
              IconButton(
                icon: const Icon(Icons.refresh, size: 20),
                tooltip: getLocalText.s("Refresh"),
                onPressed: _load,
              ),
            ],
          ),
        ),
        const Divider(height: 1),
        Expanded(
          child: reports.isEmpty
              ? _buildEmpty(context)
              : _buildList(context, reports),
        ),
      ],
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
                : r.coreVersion != null
                    // Версия ядра в подписи: сразу видно, актуально ли
                    // падение для текущей сборки.
                    ? '${formatBytes(r.size)} · ${r.coreVersion}'
                    : formatBytes(r.size),
            style: const TextStyle(fontSize: 12),
          ),
          trailing: IconButton(
            icon: const Icon(Icons.ios_share, size: 20),
            tooltip: getLocalText.s("Share the crash report"),
            onPressed: () => _share(r),
          ),
          // Тап открывает трейс: чаще нужно посмотреть, а не сразу отдать.
          onTap: () => Navigator.of(context).push(
            MaterialPageRoute<void>(
              builder: (_) => CrashReportViewScreen(report: r),
            ),
          ),
        );
      },
    );
  }
}

/// §316 — просмотр одного репорта: сам Go-трейс, monospace, с кнопкой share.
class CrashReportViewScreen extends StatefulWidget {
  const CrashReportViewScreen({super.key, required this.report});

  final CrashReportFile report;

  @override
  State<CrashReportViewScreen> createState() => _CrashReportViewScreenState();
}

class _CrashReportViewScreenState extends State<CrashReportViewScreen>
    with SnackHelper {
  String? _text;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    String text;
    try {
      text = await File(widget.report.path).readAsString();
    } catch (e) {
      text = 'Failed to read: $e';
    }
    if (!mounted) return;
    setState(() => _text = text);
  }

  @override
  Widget build(BuildContext context) {
    final r = widget.report;
    return Scaffold(
      appBar: AppBar(
        title: Text(formatDateTime(r.mtime)),
        actions: [
          IconButton(
            icon: const Icon(Icons.ios_share),
            tooltip: getLocalText.s("Share the crash report"),
            onPressed: () async {
              final ok = await shareCrashReport(r);
              if (!mounted || ok) return;
              showSnack(getLocalText.s("Share failed: %s", r.name));
            },
          ),
        ],
      ),
      body: _text == null
          ? const Center(child: CircularProgressIndicator())
          : SingleChildScrollView(
              padding: const EdgeInsets.all(12),
              child: SelectableText(
                _text!,
                style: const TextStyle(
                  fontFamily: 'monospace',
                  fontSize: 11,
                  height: 1.3,
                ),
              ),
            ),
    );
  }
}
