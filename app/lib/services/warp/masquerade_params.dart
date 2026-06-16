/// §143 — параметры WARP masquerade (WireSock-style `id`/`ip`/`ib`).
///
/// Ядро (sing-box-lx 009) само разворачивает `id`/`ip`/`ib` в AmneziaWG `i1`
/// CPS-пакет нужного протокола — LxBox больше НЕ генерит `i1` в Dart (старый
/// `quic_i1.dart` / SIP-генератор удалены).
///
/// - [sni] = `id` — домен маскировки (на провод идёт только для `ip=dns`/`sip`).
/// - [ip] = протокол: `quic` \| `dns` \| `stun` \| `sip`.
/// - [ib] = браузер: `chrome` \| `firefox` \| `curl` (осмыслен только при `ip=quic`).
/// - [jc]/[jmin]/[jmax] — junk-пакеты перед handshake.
class QuicParams {
  const QuicParams({
    this.sni = '',
    this.ip = 'quic',
    this.ib = 'chrome',
    this.jc = 4,
    this.jmin = 40,
    this.jmax = 70,
  });

  final String sni;
  final String ip;
  final String ib;
  final int jc;
  final int jmin;
  final int jmax;

  QuicParams copyWith({
    String? sni,
    String? ip,
    String? ib,
    int? jc,
    int? jmin,
    int? jmax,
  }) =>
      QuicParams(
        sni: sni ?? this.sni,
        ip: ip ?? this.ip,
        ib: ib ?? this.ib,
        jc: jc ?? this.jc,
        jmin: jmin ?? this.jmin,
        jmax: jmax ?? this.jmax,
      );
}
