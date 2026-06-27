import '../services/format_utils.dart';

/// Снимок агрегатов трафика для главного экрана (скорость/память/число
/// соединений) и Statistics. §122 — для главного экрана наполняется напрямую
/// из `CcStatus` (CommandClient status-стрим); поля `byRule`/`byApp` —
/// per-connection разбивка для Statistics-экрана.
class TrafficSnapshot {
  const TrafficSnapshot({
    this.uploadTotal = 0,
    this.downloadTotal = 0,
    this.activeConnections = 0,
    this.connectionsIn = 0,
    this.connectionsOut = 0,
    this.memory = 0,
    this.byRule = const {},
    this.byApp = const {},
  });

  final int uploadTotal;
  final int downloadTotal;

  /// §194 — сумма In+Out (для диалогов «N connections will be closed»).
  final int activeConnections;

  /// §194 — соединения по направлениям из ядра (`CcStatus.connectionsIn/Out`):
  /// In = inbound (приложения→tun), Out = outbound (ядро→серверы). Главный
  /// показывает РАЗДЕЛЬНО (↑In ↓Out), чтобы не путать суммой с числом активных
  /// в списке на Stats.
  final int connectionsIn;
  final int connectionsOut;

  /// sing-box process RAM (bytes). §122 — из `CcStatus.memory`.
  final int memory;

  /// Распределение соединений по `rule` — сколько conn'ов попало в каждое
  /// правило. Ключ: `rule` или `rule: payload`. Значение: count.
  final Map<String, int> byRule;

  /// Per-app статистика: package-name → count + bytes.
  final Map<String, AppStat> byApp;

  static const zero = TrafficSnapshot();

  String get uploadFormatted => formatBytes(uploadTotal);
  String get downloadFormatted => formatBytes(downloadTotal);
  String get memoryFormatted => formatBytes(memory);
}

class AppStat {
  const AppStat({this.count = 0, this.upload = 0, this.download = 0});
  final int count;
  final int upload;
  final int download;

  static const zero = AppStat();

  int get totalBytes => upload + download;
}
