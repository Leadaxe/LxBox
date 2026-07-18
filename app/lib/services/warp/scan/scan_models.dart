// §284 — WARP endpoint scanner. Модель кандидата для рандом-скана: посев (100
// случайных полных конфигураций) собирается в узлы папки «SCAN WARP» и гоняется
// через штатную probe-механику (FolderProbeRunner, urltest по IP — без DNS).
//
// Дизайн-инвариант: посев НЕ привилегирует ни один протокол — Монте-Карло по
// пространству {IP × port × protocol × SNI}; «что пролезет» решает сеть/DPI.

/// Транспорт кандидата. AWG = WireGuard + AmneziaWG-обфускация (голый WG DPI
/// режет вернее, поэтому WG-вариант посева всегда обфусцированный — но при этом
/// равноправный, без привилегии).
enum ScanProtocol {
  awg,
  masqueH3,
  masqueH2;

  /// Короткая техническая метка (в теге узла / логах). НЕ пользовательский текст.
  String get token => switch (this) {
        ScanProtocol.awg => 'AWG',
        ScanProtocol.masqueH3 => 'MASQUE-h3',
        ScanProtocol.masqueH2 => 'MASQUE-h2',
      };

  bool get isMasque =>
      this == ScanProtocol.masqueH3 || this == ScanProtocol.masqueH2;
}

/// Одна случайная конфигурация — описывает узел, который надо собрать (через
/// WARP-аккаунт → URI). `ip` — конкретный адрес из CF-блока (полный рандом по
/// хостовой части). `port` согласован с протоколом (WG-порт для awg, 443 для
/// masque). `sni` — маскировочный домен из пула.
class ScanCandidate {
  const ScanCandidate({
    required this.ip,
    required this.port,
    required this.protocol,
    required this.sni,
  });

  final String ip;
  final int port;
  final ScanProtocol protocol;
  final String sni;

  ScanCandidate copyWith({ScanProtocol? protocol, String? sni}) => ScanCandidate(
        ip: ip,
        port: port,
        protocol: protocol ?? this.protocol,
        sni: sni ?? this.sni,
      );

  /// `ip:port` (IPv6 берётся в скобки).
  String get endpoint => ip.contains(':') ? '[$ip]:$port' : '$ip:$port';
}
