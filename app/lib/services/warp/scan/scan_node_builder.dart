// §284 — сборка узла-кандидата (URI) из WARP-аккаунта. Одна регистрация →
// множество узлов на разных IP:port/SNI/протоколе. Креды (ключи, client_id,
// server-pubkey) переиспользуются: у Cloudflare они привязаны к аккаунту
// устройства, а не к конкретному data-plane IP.

import '../masque_account.dart';
import '../masquerade_params.dart';
import '../warp_account.dart';
import '../warp_client.dart';
import 'scan_models.dart';

/// Строит `wireguard://`/`masque://` URI для кандидата поверх аккаунтов.
/// Возвращает null, если для нужного протокола нет аккаунта (caller пропускает).
class ScanNodeBuilder {
  ScanNodeBuilder({this.warp, this.masque});

  final WarpAccount? warp;
  final MasqueAccount? masque;

  String? uriFor(ScanCandidate c) {
    switch (c.protocol) {
      case ScanProtocol.awg:
        return _wgUri(c);
      case ScanProtocol.masqueH3:
      case ScanProtocol.masqueH2:
        return _masqueUri(c);
    }
  }

  /// AWG-узел: аккаунт с подменённым endpoint + обфускация (masquerade-домен =
  /// SNI кандидата). `.conf` (INI) — как обфусцированный WARP в §126.
  String? _wgUri(ScanCandidate c) {
    final acc = warp;
    if (acc == null) return null;
    final awg = WarpClient.buildAmneziaAwg(QuicParams(sni: c.sni));
    final tuned = acc.copyWith(endpoint: c.endpoint, awg: awg);
    // reserved опускаем: рабочие AWG-конфиги идут без client_id (§142).
    return tuned.toWireguardConf(includeReserved: false);
  }

  /// MASQUE-узел: те же креды, свой data-plane IP:port + network (h3/h2) + SNI.
  /// server/port нет в copyWith — пересобираем аккаунт (ip:port из кандидата).
  String? _masqueUri(ScanCandidate c) {
    final acc = masque;
    if (acc == null) return null;
    final tuned = MasqueAccount(
      privKeyDer: acc.privKeyDer,
      serverPubDer: acc.serverPubDer,
      clientV4: acc.clientV4,
      clientV6: acc.clientV6,
      server: c.ip,
      port: c.port,
      deviceId: acc.deviceId,
      token: acc.token,
      createdAt: acc.createdAt,
      network: c.protocol == ScanProtocol.masqueH3 ? 'h3' : 'h2',
      sni: c.sni,
      idleTimeout: acc.idleTimeout,
      keepAlive: acc.keepAlive,
    );
    return tuned.toMasqueUri();
  }
}
