enum DebugSource { app, core }

enum DebugFilter { all, core, app }

class DebugEntry {
  const DebugEntry({
    required this.time,
    required this.source,
    required this.message,
  });

  final DateTime time;
  final DebugSource source;
  final String message;
}
