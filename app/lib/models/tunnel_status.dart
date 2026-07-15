/// Type-safe VPN tunnel status, mapped from native string events.
enum TunnelStatus {
  disconnected,
  connecting,
  connected,
  stopping,
  revoked,
  error,

  /// Native прислал raw, который мы не знаем как мапить. Был раньше default
  /// на `disconnected` — это ложно резолвило predicate'ы типа
  /// `firstWhere(disconnected|revoked)` на мусор из stream'а. Отдельный
  /// `unknown` позволяет `_handleStatusEvent` явно не делать cleanup и
  /// просто залогировать событие (см. handler). В reconnect/pull — тоже
  /// explicit no-op ветка.
  unknown;

  bool get isUp => this == connected;

  /// §276 — [revoked] приходит отдельным флагом рядом со `Stopped`, а НЕ
  /// статус-строкой: native-`VpnStatus` — это лишь 4 значения, `"Revoked"` он
  /// не слал никогда (весь revoke-UX был мёртвым кодом). Терминальный статус
  /// остаётся `Stopped`, иначе teardown в native виснет — см. EXTRA_REVOKED.
  static TunnelStatus fromNative(String raw, {bool revoked = false}) {
    return switch (raw) {
      'Started' => connected,
      'Starting' => connecting,
      'Stopped' => revoked ? TunnelStatus.revoked : disconnected,
      'Stopping' => stopping,
      _ => unknown,
    };
  }

  String get label => switch (this) {
        disconnected => 'Disconnected',
        connecting => 'Connecting…',
        connected => 'Connected',
        stopping => 'Stopping…',
        revoked => 'Taken by another VPN',
        error => 'Error',
        unknown => 'Unknown',
      };
}

/// Структурированное событие статуса VPN от native — заменяет
/// `Map<String, dynamic>` на типизированный объект. Парсинг делается **раз**
/// в `BoxVpnClient.onStatusChanged`, дальше в HomeController/UI едет уже
/// готовый typed объект — нет дублирования `TunnelStatus.fromNative()` +
/// `_extractStopReason()` логики по callsite'ам.
///
/// Native посылает `Map` вида `{"status": "Started"}` или с error/reason-
/// дополнительными полями на стопе. `errorReason` собирается из первого
/// непустого среди известных ключей (error/message/reason/details/description).
class TunnelStatusEvent {
  const TunnelStatusEvent({
    required this.status,
    required this.raw,
    this.errorReason,
  });

  /// Парсинг raw-события из native — fail-soft: если status неизвестен →
  /// `TunnelStatus.unknown`, errorReason остаётся как есть. UI/HomeController
  /// явно решат что делать с unknown (типично — лог, без mutation).
  factory TunnelStatusEvent.fromNative(Map<dynamic, dynamic> raw) {
    final rawStatus = raw['status']?.toString() ?? '';
    return TunnelStatusEvent(
      // §276 — `revoked: true` рядом со `Stopped` = слот забрало другое
      // VPN-приложение (native onRevoke), а не наш штатный стоп.
      status: TunnelStatus.fromNative(rawStatus, revoked: raw['revoked'] == true),
      raw: rawStatus,
      errorReason: _extractReason(raw),
    );
  }

  /// Empty fallback для случаев когда event-payload оказался пустым/мусорным
  /// (defensive после `.timeout()` или ошибок десериализации).
  static const TunnelStatusEvent unknownEmpty = TunnelStatusEvent(
    status: TunnelStatus.unknown,
    raw: '',
  );

  final TunnelStatus status;

  /// Оригинальный raw-string из native (для логов: "Started", "Stopping", …).
  /// Сохраняем потому что `TunnelStatus.fromNative` lossy — `unknown` не
  /// помнит исходник, а в дебаге надо знать что именно прилетело.
  final String raw;

  /// Текст ошибки/причины остановки если native приложил. `null` если событие
  /// без reason-полей (норма для `Started`/`Stopping`).
  final String? errorReason;

  static String? _extractReason(Map<dynamic, dynamic> raw) {
    const keys = <String>['error', 'message', 'reason', 'details', 'description'];
    for (final key in keys) {
      final value = raw[key];
      if (value == null) continue;
      final text = value.toString().trim();
      if (text.isNotEmpty) return text;
    }
    return null;
  }
}
