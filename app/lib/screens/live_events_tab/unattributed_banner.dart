// §048 — warning banner для unattributed events в Live system-wide tab.
//
// Extracted из `live_events_tab.dart` (behavior-preserving). Показывает
// сколько DNS/TCP event'ов sing-box не смог attribute к owner package за
// последние 30s. Виден только когда [TrafficProfiler.I.unattributedBannerActive].

import 'package:flutter/material.dart';

import '../../services/traffic_profiler.dart';

class UnattributedBanner extends StatelessWidget {
  const UnattributedBanner({super.key});

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Container(
      width: double.infinity,
      color: cs.errorContainer,
      padding:
          const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      child: Row(
        children: [
          Icon(Icons.warning_amber,
              size: 16, color: cs.onErrorContainer),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              '${TrafficProfiler.I.recentUnattributedCount} unattributed events / 30s — '
              'sing-box не смог детектить owner package для части DNS/TCP traffic\'а',
              style: TextStyle(
                  fontSize: 12, color: cs.onErrorContainer),
            ),
          ),
        ],
      ),
    );
  }
}
