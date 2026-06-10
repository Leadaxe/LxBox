import 'dart:async';

import 'package:flutter/material.dart';

import '../../../services/relative_time.dart';
import '../../../services/settings_storage.dart';
import '../../../services/update_checker.dart';
import '../../../services/version_info.dart';

/// "Last check: …" + Check now-кнопка под Updates-toggle. Подписан на
/// `UpdateChecker.latest` чтобы при успешном fetch'е результат сразу
/// отрендерился.
class UpdateStatusRow extends StatefulWidget {
  const UpdateStatusRow({super.key});

  @override
  State<UpdateStatusRow> createState() => _UpdateStatusRowState();
}

class _UpdateStatusRowState extends State<UpdateStatusRow> {
  DateTime? _lastCheck;
  bool _checking = false;
  String? _resultLine;

  @override
  void initState() {
    super.initState();
    unawaited(_loadLastCheck());
  }

  Future<void> _loadLastCheck() async {
    final dt = await SettingsStorage.getLastUpdateCheck();
    if (mounted) setState(() => _lastCheck = dt);
  }

  Future<void> _checkNow() async {
    setState(() {
      _checking = true;
      _resultLine = null;
    });
    final result = await UpdateChecker.I.forceCheck(
      localVersion: VersionInfo.I.version,
    );
    final dt = await SettingsStorage.getLastUpdateCheck();
    if (!mounted) return;
    setState(() {
      _checking = false;
      _lastCheck = dt;
      switch (result.kind) {
        case UpdateCheckKind.newer:
          _resultLine = '${result.info!.tag} available';
        case UpdateCheckKind.upToDate:
          _resultLine = "You're up to date";
        case UpdateCheckKind.failed:
          _resultLine = 'Check failed: ${result.message ?? ''}';
        case UpdateCheckKind.skipped:
          _resultLine = null;
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final lastCheckText = _lastCheck == null
        ? 'Last check: never'
        : 'Last check: ${relativeTime(DateTime.now(), _lastCheck!)}';
    return Padding(
      padding: const EdgeInsets.fromLTRB(72, 0, 16, 12),
      child: Row(
        children: [
          Expanded(
            child: Text(
              _resultLine ?? lastCheckText,
              style: TextStyle(fontSize: 12, color: cs.onSurfaceVariant),
            ),
          ),
          if (_checking)
            const SizedBox(
              width: 14,
              height: 14,
              child: CircularProgressIndicator(strokeWidth: 2),
            )
          else
            TextButton(
              onPressed: _checkNow,
              child: const Text('Check now'),
            ),
        ],
      ),
    );
  }
}
