// §284 — таблица результатов WARP-скана. Вверху рабочие (по rtt), ниже — нет.
// Тап по рабочей строке возвращает ScanChoice через showModalBottomSheet<ScanChoice>.

import 'package:flutter/material.dart';

import '../../services/l10n/l10n.dart';
import '../../services/warp/scan/scan_models.dart';

/// Открывает лист результатов. Возвращает выбранную ноду (null — закрыли без
/// выбора / нет рабочих).
Future<ScanChoice?> showWarpScanResults(
  BuildContext context,
  List<ScanResult> results,
) {
  return showModalBottomSheet<ScanChoice>(
    context: context,
    isScrollControlled: true,
    showDragHandle: true,
    builder: (_) => _WarpScanResultsSheet(results: results),
  );
}

class _WarpScanResultsSheet extends StatelessWidget {
  const _WarpScanResultsSheet({required this.results});

  final List<ScanResult> results;

  @override
  Widget build(BuildContext context) {
    final l = context.l;
    final working = results.where((r) => r.alive).toList();
    final failed = results.where((r) => !r.alive).toList();

    if (results.isEmpty) {
      return Padding(
        padding: const EdgeInsets.all(24),
        child: Text(l.warpScanEmptyResult, textAlign: TextAlign.center),
      );
    }

    return DraggableScrollableSheet(
      expand: false,
      initialChildSize: 0.7,
      maxChildSize: 0.95,
      minChildSize: 0.4,
      builder: (ctx, scrollCtrl) => ListView(
        controller: scrollCtrl,
        padding: const EdgeInsets.only(bottom: 24),
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 4, 16, 8),
            child: Text(
              l.warpScanResultsTitle,
              style: Theme.of(context).textTheme.titleLarge,
            ),
          ),
          if (working.isEmpty && failed.isEmpty)
            Padding(
              padding: const EdgeInsets.all(24),
              child: Text(l.warpScanEmptyResult, textAlign: TextAlign.center),
            ),
          if (working.isNotEmpty) _header(context, l.warpScanWorkingHeader),
          ...working.map((r) => _row(context, r, tappable: true)),
          if (failed.isNotEmpty) _header(context, l.warpScanFailedHeader),
          ...failed.map((r) => _row(context, r, tappable: false)),
        ],
      ),
    );
  }

  Widget _header(BuildContext context, String text) => Padding(
        padding: const EdgeInsets.fromLTRB(16, 16, 16, 4),
        child: Text(
          text.toUpperCase(),
          style: Theme.of(context).textTheme.labelSmall?.copyWith(
                color: Theme.of(context).colorScheme.primary,
                letterSpacing: 0.8,
              ),
        ),
      );

  Widget _row(BuildContext context, ScanResult r, {required bool tappable}) {
    final scheme = Theme.of(context).colorScheme;
    return ListTile(
      dense: true,
      title: Text(r.candidate.hostPort),
      subtitle: Text(_subtitle(r)),
      trailing: Icon(
        r.alive ? Icons.check_circle_outline : Icons.cancel_outlined,
        size: 18,
        color: r.alive ? scheme.primary : Theme.of(context).disabledColor,
      ),
      onTap: tappable
          ? () => Navigator.of(context).pop(ScanChoice.fromResult(r))
          : null,
      enabled: tappable,
    );
  }

  /// Технические токены — не локализуются (это данные: протокол/SNI/rtt/ms).
  String _subtitle(ScanResult r) {
    final c = r.candidate;
    final parts = <String>[c.protocol.token];
    if (c.sni.isNotEmpty) parts.add(c.sni);
    if (r.alive && r.rttMs != null) parts.add('${r.rttMs} ms');
    if (r.loss != null && r.loss! > 0) {
      parts.add('${(r.loss! * 100).round()}% loss');
    }
    if (!r.alive && (r.error ?? '').isNotEmpty) parts.add(r.error!);
    return parts.join(' · ');
  }
}
