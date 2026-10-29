part of '../post_steps.dart';

/// Post-step: §691 — `route_exclude_address` tun-inbound (var
/// `tun_route_exclude`, «Bypass the tunnel»). Снимает строку, если:
///
/// 1. она не CIDR (адрес + `/N` в пределах семейства) — ядро разбирает поле
///    как `netip.Prefix` и на ошибке не стартует;
/// 2. она накрывает адрес самого TUN (`address` tun-inbound) — трафик к
///    адресу TUN, в том числе DNS-перехват, уходит мимо туннеля и VPN
///    перестаёт работать.
///
/// На каждую снятую строку — предупреждение сборки. Опустевший список —
/// ключ снимается. Пересечение с пулом FakeIP и сетями за узлами не
/// проверяется (спека §691).
List<String> healTunRouteExclude(Map<String, dynamic> config) {
  final inbounds = config['inbounds'];
  if (inbounds is! List) return const [];
  final warnings = <String>[];
  for (final tun in inbounds) {
    if (tun is! Map<String, dynamic> || tun['type'] != 'tun') continue;
    final raw = tun['route_exclude_address'];
    if (raw is! List) continue;
    final address = tun['address'];
    final own = [
      if (address is List)
        for (final a in address)
          if (a is String) _TunPrefix.parse(a),
    ].whereType<_TunPrefix>().toList();
    final kept = <String>[];
    for (final e in raw) {
      final text = '$e'.trim();
      final prefix = _TunPrefix.parse(text);
      if (prefix == null) {
        warnings.add('Tunnel bypass "$text" skipped: not an address range '
            '(CIDR, e.g. 192.168.0.0/16).');
        continue;
      }
      if (own.any((a) => prefix.covers(a.bytes))) {
        warnings.add('Tunnel bypass "$text" skipped: it covers the tunnel\'s '
            'own address.');
        continue;
      }
      kept.add(text);
    }
    if (kept.isEmpty) {
      tun.remove('route_exclude_address');
    } else {
      tun['route_exclude_address'] = kept;
    }
  }
  return warnings;
}

/// Префикс `адрес/N`: байты адреса и длина маски. Без `/N` — не префикс
/// (ядро `netip.ParsePrefix` его не примет).
class _TunPrefix {
  const _TunPrefix(this.bytes, this.bits);

  final List<int> bytes;
  final int bits;

  static _TunPrefix? parse(String s) {
    final slash = s.indexOf('/');
    if (slash <= 0) return null;
    final host = s.substring(0, slash);
    final List<int> bytes;
    try {
      bytes = host.contains(':')
          ? Uri.parseIPv6Address(host)
          : Uri.parseIPv4Address(host);
    } on FormatException {
      return null;
    }
    final bits = int.tryParse(s.substring(slash + 1));
    if (bits == null || bits < 0 || bits > bytes.length * 8) return null;
    return _TunPrefix(bytes, bits);
  }

  /// Адрес того же семейства, первые [bits] бит которого совпадают.
  bool covers(List<int> addr) {
    if (addr.length != bytes.length) return false;
    for (var i = 0; i < bits; i++) {
      final byte = i >> 3, mask = 0x80 >> (i & 7);
      if ((addr[byte] & mask) != (bytes[byte] & mask)) return false;
    }
    return true;
  }
}
