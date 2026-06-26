// §048 — header с recording control для Live system-wide tab.
//
// Extracted из `live_events_tab.dart` (behavior-preserving). ▶ START / ⏹ STOP
// + duration badge. Аналогичен Per-app trace header'у, но без target picker'а
// — Live это system-wide recording, фокусируется через filter chips.

import 'package:flutter/material.dart';

import '../../services/traffic_profiler.dart';
import '../../services/format_utils.dart';

class LiveRecordingHeader extends StatelessWidget {
  const LiveRecordingHeader({
    super.key,
    required this.eventCount,
    required this.onToggle,
    this.onExport,
  });

  final int eventCount;
  final VoidCallback onToggle;

  /// §044 — экспорт записанных событий. Кнопка справа от START/STOP; null =
  /// скрыта (нечего экспортировать).
  final VoidCallback? onExport;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final isRec = TrafficProfiler.I.isGlobalRecording;
    final startedAt = TrafficProfiler.I.globalRecordingStartedAt;
    final duration = startedAt == null
        ? Duration.zero
        : DateTime.now().difference(startedAt);
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 12, 12, 4),
      child: Row(
        children: [
          Icon(
            isRec ? Icons.fiber_manual_record : Icons.podcasts,
            size: 16,
            color: isRec ? cs.error : cs.onSurfaceVariant,
          ),
          const SizedBox(width: 8),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  isRec ? 'Recording system-wide events' : 'Not recording',
                  style: TextStyle(
                      fontSize: 13,
                      fontWeight: FontWeight.w500,
                      color: isRec ? cs.error : cs.onSurface),
                ),
                Text(
                  isRec
                      ? '${formatDuration(duration)} · $eventCount events'
                      : 'Tap START to begin capture. Recording continues '
                          'when you leave this tab.',
                  style: TextStyle(
                      fontSize: 11, color: cs.onSurfaceVariant),
                ),
              ],
            ),
          ),
          const SizedBox(width: 8),
          FilledButton.icon(
            onPressed: onToggle,
            icon: Icon(isRec ? Icons.stop : Icons.fiber_manual_record,
                size: 18),
            label: Text(isRec ? 'STOP' : 'START'),
            style: FilledButton.styleFrom(
              backgroundColor: isRec ? cs.error : cs.primary,
              foregroundColor: isRec ? cs.onError : cs.onPrimary,
            ),
          ),
          // §044 — экспорт записанного, справа от большой кнопки.
          if (onExport != null)
            IconButton(
              tooltip: 'Export events',
              icon: const Icon(Icons.download, size: 22),
              onPressed: eventCount == 0 ? null : onExport,
            ),
        ],
      ),
    );
  }
}
