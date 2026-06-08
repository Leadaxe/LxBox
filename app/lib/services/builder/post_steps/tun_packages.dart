part of '../post_steps.dart';

/// Post-step: §046 — OS-level split-tunneling. Подставляет `include_package`
/// или `exclude_package` в `inbound[type=tun]` на основе `tun_apps` storage.
///
/// Mode → sing-box config:
/// - `off`        → ничего не пишем (sing-box default = все apps через tun)
/// - `allow`      → `tun.include_package = packages` (только эти через tun)
/// - `deny`       → `tun.exclude_package = packages` (все КРОМЕ этих)
///
/// libbox потом читает эти поля из config и передаёт в native слой
/// (BoxVpnService.kt:557-560), который зовёт `VpnService.Builder
/// .addAllowedApplication`/`.addDisallowedApplication`. Применяется на
/// `builder.establish()` — нужен FULL VPN restart, light reload не работает.
///
/// Если `mode != off` но `packages` пустой — silently no-op (нечего apply'ить).
/// Если в config нет tun-inbound — silently no-op (некуда apply'ить).
void applyTunPackages(Map<String, dynamic> config, TunAppsConfig tunApps) {
  if (tunApps.isOff || tunApps.packages.isEmpty) return;

  final inbounds = config['inbounds'];
  if (inbounds is! List) return;

  Map<String, dynamic>? tun;
  for (final i in inbounds) {
    if (i is Map<String, dynamic> && i['type'] == 'tun') {
      tun = i;
      break;
    }
  }
  if (tun == null) return;

  final field = tunApps.isAllow ? 'include_package' : 'exclude_package';
  tun[field] = List<String>.from(tunApps.packages);
}
