enum DebugSource { app, core }

enum DebugLevel { debug, info, warning, error }

enum DebugFilter { all, core, app }

class DebugEntry {
  const DebugEntry({
    required this.time,
    required this.source,
    required this.level,
    required this.message,
    this.fromPreviousSession = false,
  });

  final DateTime time;
  final DebugSource source;
  final DebugLevel level;
  final String message;

  /// `true` если entry был загружен с диска при старте (persistent AppLog,
  /// task 028). UI показывает их с маркером «↑ prev session», DumpBuilder
  /// сериализует с этим флагом, чтобы разработчик мог отделить pre-crash
  /// JVM-events от текущей сессии.
  final bool fromPreviousSession;
}
