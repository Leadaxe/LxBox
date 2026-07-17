import 'dart:async';

import 'package:flutter/material.dart';

import '../../../services/l10n/l10n.dart';
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
    // §279 — screen-local transient render (mounted-гейт выше): строка живёт
    // до следующего чека, смену локали не переживает сознательно.
    final l = context.l;
    setState(() {
      _checking = false;
      _lastCheck = dt;
      switch (result.kind) {
        case UpdateCheckKind.newer:
          _resultLine = l.appSettingsGenUpdateAvailable(result.info!.tag);
        case UpdateCheckKind.upToDate:
          _resultLine = l.appSettingsGenUpToDate;
        case UpdateCheckKind.failed:
          _resultLine = l.appSettingsGenUpdateCheckFailed(result.message ?? '');
        case UpdateCheckKind.skipped:
          _resultLine = null;
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final lastCheckText = _lastCheck == null
        ? context.l.appSettingsGenLastCheckNever
        : context.l
            .appSettingsGenLastCheck(relativeTime(context.l, DateTime.now(), _lastCheck!));
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
              child: Text(context.l.appSettingsGenCheckNow),
            ),
        ],
      ),
    );
  }
}
