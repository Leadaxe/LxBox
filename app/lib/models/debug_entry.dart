enum DebugSource { app, core }

enum DebugLevel { debug, info, warning, error }

enum DebugFilter { all, core, app }

class DebugEntry {
  const DebugEntry({
    required this.time,
    required this.source,
    required this.level,
    required this.message,
  });

  final DateTime time;
  final DebugSource source;
  final DebugLevel level;
  final String message;
}
