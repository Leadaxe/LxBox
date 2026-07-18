import 'package:flutter/material.dart';

import '../../services/traffic_profiler.dart';
import '../../services/l10n/locale_controller.dart';

void showWipeAllDialog(BuildContext context) {
  showDialog<void>(
    context: context,
    builder: (ctx) => AlertDialog(
      title: Text(getLocalText.s("Clear all sessions?")),
      content: Text(getLocalText.s("Saved trace sessions will be removed.")),
      actions: [
        TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: Text(getLocalText.s("Cancel"))),
        TextButton(
          onPressed: () {
            TrafficProfiler.I.clearAll();
            Navigator.pop(ctx);
          },
          child: Text(getLocalText.s("Clear")),
        ),
      ],
    ),
  );
}

void showHelpDialog(BuildContext context) {
  showDialog<void>(
    context: context,
    builder: (ctx) => AlertDialog(
      title: Text(getLocalText.s("Per-app trace")),
      content: SingleChildScrollView(
        child: Text(
          getLocalText.s("Pick an app and tap START to record its DNS resolves, connections, and routing chain.\n\n• Live — newest events first (DNS + TCP/UDP) + System-wide section (events without owner detection — e.g. DNS fails).\n• Domains — aggregated unique domains, with CNAME chain & IPs. Search by domain or IP.\n• IPs — aggregated unique destination IPs (ports, conns, bytes, outbound)\n• Connections — per-connection timeline. Tap a row to inline-expand (CNAME, all IPs, issues); button [View in Domains →] jumps to aggregated breakdown.\n\nConfidence badges:\n  • (default) — verified: router log explicitly named the target\n  • 🔗 sec — secondary: matched via secondary packages (WebView etc)\n  • 〽 — inferred: a recently DNS-resolved IP belongs to the target\n  • ? — unattributed: owner package not detected, event shown as \"nearby\"\n\nEdit secondary — add packages to count as part of this app's traffic (WebView, sandboxed renderer, etc.).\n\nLive system-wide tab (4th in Statistics) — discovery without picking a target: see all traffic from all apps in real-time.\n\nVerbose mode (debug-level core logs) gives more detail but increases CPU/battery use until you disable it. Toggling verbose takes effect on the next session.\n\nSessions are kept in memory only — last 5 are saved across recordings, but ALL are wiped if the app is force-stopped."),
          style: const TextStyle(fontSize: 13),
        ),
      ),
      actions: [
        TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: Text(getLocalText.s("Close"))),
      ],
    ),
  );
}
