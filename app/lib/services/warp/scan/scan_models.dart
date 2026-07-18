// §284 — WARP endpoint scanner. Модели для двухфазного рандом-скана:
// посев (100 случайных полных конфигураций) → сырая проба через ядро → выбор.
//
// Дизайн-инвариант: посев НЕ привилегирует ни один протокол — Монте-Карло по
// всему пространству {IP × port × protocol × SNI × fp}; «что пролезет» решает
// сеть/DPI, а не наше допущение. См. docs/spec/features/284 warp-endpoint-scanner.

/// Транспорт кандидата. AWG = WireGuard + AmneziaWG-обфускация (голый WG DPI
/// режет вернее, поэтому в посеве WG-вариант всегда обфусцированный, но при
/// этом равноправный, без привилегии).
enum ScanProtocol {
  awg,
  masqueH3,
  masqueH2;

  /// Проводное имя для kernel-контракта (SPEC 028 enum AWG=0/MASQUE_H3=1/H2=2).
  int get wire => switch (this) {
        ScanProtocol.awg => 0,
        ScanProtocol.masqueH3 => 1,
        ScanProtocol.masqueH2 => 2,
      };

  /// Короткая метка для UI-строк (локализуется на стороне виджета отдельно —
  /// здесь только стабильный технический токен, НЕ пользовательский текст).
  String get token => switch (this) {
        ScanProtocol.awg => 'AWG',
        ScanProtocol.masqueH3 => 'MASQUE h3',
        ScanProtocol.masqueH2 => 'MASQUE h2',
      };

  bool get isMasque =>
      this == ScanProtocol.masqueH3 || this == ScanProtocol.masqueH2;
}

/// Одна случайная конфигурация — вход фазы 1. `ip` — уже конкретный адрес из
/// CF-блока (полный рандом по хостовой части, не только `.1-.10`). `port`
/// согласован с протоколом (WG-порт для awg, 443 для masque). `utlsFp` — в
/// фазе 1 фиксируется `chrome`; в фазе 2 варьируется как диагностика (в
/// итоговую ноду не идёт — ядро дропает utls на QUIC, см. §282/SPEC 027).
class ScanCandidate {
  const ScanCandidate({
    required this.ip,
    required this.port,
    required this.protocol,
    required this.sni,
    required this.utlsFp,
    this.reserved,
  });

  final String ip;
  final int port;
  final ScanProtocol protocol;
  final String sni;
  final String utlsFp;

  /// 3-байтовый WARP client_id для WG-пробы. null/empty → ядро шлёт нули
  /// (§132: zeroed-reserved проходит на большинстве endpoint'ов; реальный
  /// clientId — фолбэк-ретрай на молчании, решается на стороне runner'а).
  final List<int>? reserved;

  ScanCandidate copyWith({
    ScanProtocol? protocol,
    String? sni,
    String? utlsFp,
    List<int>? reserved,
  }) =>
      ScanCandidate(
        ip: ip,
        port: port,
        protocol: protocol ?? this.protocol,
        sni: sni ?? this.sni,
        utlsFp: utlsFp ?? this.utlsFp,
        reserved: reserved ?? this.reserved,
      );

  String get hostPort =>
      ip.contains(':') ? '[$ip]:$port' : '$ip:$port'; // IPv6-safe

  Map<String, Object?> toProbeArgs(int timeoutMs) => {
        'ip': ip,
        'port': port,
        'protocol': protocol.wire,
        'sni': sni,
        'utlsFp': utlsFp,
        'timeoutMs': timeoutMs,
        if (reserved != null) 'reserved': reserved,
        // peerPubkey не шлём: все CF WARP-эндпоинты используют единый серверный
        // pubkey → ядро (SPEC 028) подставляет его как default при пустом поле.
      };
}

/// Результат пробы (выход). Ephemeral — не персистится. Инвариант (Variant B,
/// как urlTest): `alive==false` ⇒ `error` непустой; `rttMs` валиден iff alive.
class ScanResult {
  const ScanResult({
    required this.candidate,
    required this.alive,
    this.rttMs,
    this.loss,
    this.error,
  });

  final ScanCandidate candidate;
  final bool alive;
  final int? rttMs;

  /// Доля неотвеченных из N повторов (фаза 2). null в фазе 1 (один прогон).
  final double? loss;
  final String? error;

  static ScanResult dead(ScanCandidate c, String error) =>
      ScanResult(candidate: c, alive: false, error: error);

  ScanResult copyWith({int? rttMs, double? loss}) => ScanResult(
        candidate: candidate,
        alive: alive,
        rttMs: rttMs ?? this.rttMs,
        loss: loss ?? this.loss,
        error: error,
      );
}

/// Что тап по строке успешной ноды возвращает в визард. Отдельный тип от
/// ScanCandidate: несёт только то, что подставляется в конфиг (без fp — он не
/// эмитится, см. ограничение §284).
class ScanChoice {
  const ScanChoice({
    required this.ip,
    required this.port,
    required this.protocol,
    required this.sni,
  });

  factory ScanChoice.fromResult(ScanResult r) => ScanChoice(
        ip: r.candidate.ip,
        port: r.candidate.port,
        protocol: r.candidate.protocol,
        sni: r.candidate.sni,
      );

  final String ip;
  final int port;
  final ScanProtocol protocol;
  final String sni;

  String get endpoint => ip.contains(':') ? '[$ip]:$port' : '$ip:$port';
}
