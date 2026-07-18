// §284 — WARP endpoint scanner. Модель кандидата для рандом-скана: посев (100
// случайных полных конфигураций) собирается в узлы папки «SCAN WARP» и гоняется
// через штатную probe-механику (FolderProbeRunner, urltest по IP — без DNS).
//
// Дизайн-инвариант: посев НЕ привилегирует ни один протокол — Монте-Карло по
// пространству {IP × port × protocol × SNI × AWG-параметры}; «что пролезет»
// решает сеть/DPI.

/// Транспорт кандидата. AWG = WireGuard + AmneziaWG-обфускация (голый WG DPI
/// режет вернее, поэтому WG-вариант посева всегда обфусцированный — но при этом
/// равноправный, без привилегии).
enum ScanProtocol {
  awg,
  masqueH3,
  masqueH2;

  bool get isMasque =>
      this == ScanProtocol.masqueH3 || this == ScanProtocol.masqueH2;
}

/// AWG-параметры маскировки кандидата (рандомизируются в посеве — иначе все
/// AWG-узлы вышли бы идентичными). `ip` — протокол приманки (quic/dns/stun/sip);
/// `jc/jmin/jmax` — jitter. Используются только для AWG-узлов.
class AwgParams {
  const AwgParams({
    required this.ip,
    required this.jc,
    required this.jmin,
    required this.jmax,
  });

  final String ip;
  final int jc;
  final int jmin;
  final int jmax;
}

/// Одна случайная конфигурация — описывает узел, который надо собрать (через
/// WARP-аккаунт → URI). `ip` — конкретный адрес из CF-блока (полный рандом по
/// хостовой части). `port` согласован с протоколом (WG-порт для awg, 443 для
/// masque). `sni` — маскировочный домен из пула. `awgParams` — только для AWG.
class ScanCandidate {
  const ScanCandidate({
    required this.ip,
    required this.port,
    required this.protocol,
    required this.sni,
    this.awgParams,
  });

  final String ip;
  final int port;
  final ScanProtocol protocol;
  final String sni;
  final AwgParams? awgParams;

  ScanCandidate copyWith({ScanProtocol? protocol, String? sni}) => ScanCandidate(
        ip: ip,
        port: port,
        protocol: protocol ?? this.protocol,
        sni: sni ?? this.sni,
        awgParams: awgParams,
      );

  /// `ip:port` (IPv6 берётся в скобки).
  String get endpoint => ip.contains(':') ? '[$ip]:$port' : '$ip:$port';

  /// §284 — заголовок узла (тег во фрагменте URI). Jitter фиксирован (4/40/70),
  /// поэтому в тайтле не показывается — только протокол приманки + SNI:
  ///   AWG    → `🔥⛈️ WARP AWG (quic ya.ru)`
  ///   MASQUE → `🔥🎭 WARP MASQUE (h3: cloudflare.com)`
  String get nodeTitle => switch (protocol) {
        ScanProtocol.awg => '🔥⛈️ WARP AWG '
            '(${awgParams?.ip ?? 'quic'}${sni.isEmpty ? '' : ' $sni'})',
        ScanProtocol.masqueH3 =>
          '🔥🎭 WARP MASQUE (h3${sni.isEmpty ? '' : ': $sni'})',
        ScanProtocol.masqueH2 =>
          '🔥🎭 WARP MASQUE (h2${sni.isEmpty ? '' : ': $sni'})',
      };
}
