// §284 — сборка узла-кандидата (URI) из WARP-аккаунта. Одна регистрация →
// множество узлов на разных IP:port/SNI/протоколе/приманке. Креды (ключи,
// client_id, server-pubkey) переиспользуются: у Cloudflare они привязаны к
// аккаунту устройства, а не к конкретному data-plane IP.
//
// Тег узла (заголовок в списке) = [ScanCandidate.nodeTitle], проносится через
// фрагмент URI: для MASQUE — `#<label>` напрямую; для WG (.conf/INI) — через
// `nameHint` парсера, который кладёт его во фрагмент.

import '../../parser/ini_parser.dart';
import '../masque_account.dart';
import '../masquerade_params.dart';
import '../warp_account.dart';
import '../warp_client.dart';
import 'scan_models.dart';

/// Строит `wireguard://`/`masque://` URI (с тегом-заголовком) для кандидата.
/// Возвращает null, если для протокола нет аккаунта или сборка/парс не удались.
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

  /// AWG-узел: аккаунт с подменённым endpoint + обфускация (masquerade `ip`
  /// приманки + `id`=SNI). `.conf` → `parseWireguardIni(nameHint: nodeTitle)`
  /// → канонический `wireguard://…#nodeTitle`.
  String? _wgUri(ScanCandidate c) {
    final acc = warp;
    if (acc == null) return null;
    final p = c.awgParams;
    final awg = WarpClient.buildAmneziaAwg(QuicParams(
      sni: c.sni,
      ip: p?.ip ?? 'quic',
      jc: p?.jc ?? 4,
      jmin: p?.jmin ?? 40,
      jmax: p?.jmax ?? 70,
    ));
    final tuned = acc.copyWith(endpoint: c.endpoint, awg: awg);
    // reserved опускаем: рабочие AWG-конфиги идут без client_id (§142).
    final spec = parseWireguardIni(
      tuned.toWireguardConf(includeReserved: false),
      nameHint: c.nodeTitle,
    );
    return spec?.toUri();
  }

  /// MASQUE-узел: те же креды, network (h3/h2) + IP:port + SNI из кандидата.
  ///
  /// §305 — h3 И h2 берут IP:port кандидата (разнообразие endpoint). Прошлый
  /// форсинг h3 на `acc.server` снят: вывод «h3 привязан к server» был артефактом
  /// headless-probe (probe при остановленном VPN не поднимает QUIC). Боевой тест
  /// (reconnect + urltest) показал: h3 живёт на 4 адресах блока (.198.1/.2,
  /// .199.1/.2) на всех 7 портах, h2 — по всему блоку. Узкий h3-источник задаёт
  /// генератор (`masqueV4CidrFor`), сюда приходит уже готовый кандидат.
  /// server/port нет в copyWith — пересобираем аккаунт.
  String? _masqueUri(ScanCandidate c) {
    final acc = masque;
    if (acc == null) return null;
    final isH3 = c.protocol == ScanProtocol.masqueH3;
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
      network: isH3 ? 'h3' : 'h2',
      sni: c.sni,
      idleTimeout: acc.idleTimeout,
      keepAlive: acc.keepAlive,
    );
    final uri = tuned.toMasqueUri();
    final hash = uri.lastIndexOf('#');
    final base = hash < 0 ? uri : uri.substring(0, hash);
    return '$base#${Uri.encodeComponent(c.nodeTitle)}';
  }
}
