// §284 — источник пула для WARP-скана. Все диапазоны выведены из
// Cloudflare-first-party (cloudflare.com/ips: 162.158.0.0/15 ⊃ 162.159.192/193/195;
// 188.114.96.0/20 ⊃ 188.114.96-99) + §132-verified. НЕТ сторонних реестров.
//
// MASQUE (masque_v4_cidr): .198.0/24 — device-verified (h2 стабилен на всём блоке;
// дефолты .198.1 h3, .198.2 h2). .197.0/24 — официальный CF-анонс MASQUE (firewall-док).
// .192.0/24 — доп. блок, что перебирают референсные реимплементации (usque, masque-plus).
// h3 пинит серверный pubkey из реги: на IP с другим anycast-ключом падает (не IP-блок,
// а pinning) — эксперимент показывает, где ключ совпадает.
//
// Парсится из `scan`-блока assets/warp_endpoints.json. SNI-пулы приходят из
// уже существующих sni_pool / masque_sni_pool (их грузит WarpEndpointPicker).

import 'dart:io' show InternetAddress;
import 'dart:math';
import 'dart:typed_data';

class ScanPool {
  const ScanPool({
    required this.wgV4Cidr,
    required this.wgV6Cidr,
    required this.wgPorts,
    required this.wgPortsEmpirical,
    required this.masqueV4Cidr,
    required this.masquePort,
    required this.utlsFpPool,
    required this.sniPool,
    required this.masqueSniPool,
  });

  final List<String> wgV4Cidr;
  final List<String> wgV6Cidr;

  /// Cloudflare-достоверные WG-порты (2408/500/1701/4500). Приоритетны.
  final List<int> wgPorts;

  /// Empirical-порты — ниже в приоритете (§132: длинный список зарублен голосованием).
  final List<int> wgPortsEmpirical;

  final List<String> masqueV4Cidr;
  final int masquePort;
  final List<String> utlsFpPool;
  final List<String> sniPool;
  final List<String> masqueSniPool;

  /// Пул пригоден, если валиден хотя бы один транспорт. WG требует портов
  /// (иначе пробу не собрать); MASQUE использует свой masquePort, WG-портов
  /// ему не нужно — поэтому masque-only пул валиден без wg_ports.
  bool get hasData {
    final wgOk = (wgV4Cidr.isNotEmpty || wgV6Cidr.isNotEmpty) &&
        wgPorts.isNotEmpty;
    return wgOk || masqueV4Cidr.isNotEmpty;
  }

  /// Парс `scan`-блока. `sniPool`/`masqueSniPool` передаёт caller (они лежат в
  /// корне asset, не в `scan`). Возвращает null, если блок отсутствует/битый —
  /// caller тогда прячет кнопку SCAN.
  static ScanPool? fromJson(
    Map<String, dynamic>? scan, {
    required List<String> sniPool,
    required List<String> masqueSniPool,
  }) {
    if (scan == null) return null;
    List<String> strs(String k) =>
        (scan[k] as List?)?.map((e) => e.toString()).toList() ?? const [];
    List<int> ints(String k) =>
        (scan[k] as List?)?.map((e) => (e as num).toInt()).toList() ?? const [];
    final pool = ScanPool(
      wgV4Cidr: strs('wg_v4_cidr'),
      wgV6Cidr: strs('wg_v6_cidr'),
      wgPorts: ints('wg_ports'),
      wgPortsEmpirical: ints('wg_ports_empirical'),
      masqueV4Cidr: strs('masque_v4_cidr'),
      masquePort: (scan['masque_port'] as num?)?.toInt() ?? 443,
      utlsFpPool: strs('utls_fp_pool'),
      sniPool: sniPool,
      masqueSniPool: masqueSniPool,
    );
    return pool.hasData ? pool : null;
  }
}

/// Возвращает случайный IP внутри CIDR (v4 или v6). Полный рандом по хостовой
/// части — не только последний октет. `rng` инъектируется для тестов.
/// Кидает FormatException на битом CIDR (caller обрабатывает выше).
String randomIpInCidr(String cidr, Random rng) {
  final slash = cidr.indexOf('/');
  if (slash < 0) throw FormatException('not a CIDR: $cidr');
  final base = InternetAddress(cidr.substring(0, slash));
  final mask = int.parse(cidr.substring(slash + 1));
  final bytes = base.rawAddress; // 4 (v4) или 16 (v6)
  final totalBits = bytes.length * 8;
  if (mask < 0 || mask > totalBits) throw FormatException('bad mask: $cidr');
  final hostBits = totalBits - mask;

  // base → BigInt, обнуляем хостовую часть, накладываем случайный host-offset.
  var value = BigInt.zero;
  for (final b in bytes) {
    value = (value << 8) | BigInt.from(b);
  }
  final full = (BigInt.one << totalBits) - BigInt.one;
  final hostMask =
      hostBits == 0 ? BigInt.zero : (BigInt.one << hostBits) - BigInt.one;
  final network = value & (full ^ hostMask);
  final offset = _randomBigInt(hostBits, rng) & hostMask;
  final result = network | offset;

  // BigInt → байты (big-endian, фиксированная длина адреса).
  final out = Uint8List(bytes.length);
  var v = result;
  for (var i = bytes.length - 1; i >= 0; i--) {
    out[i] = (v & BigInt.from(0xff)).toInt();
    v = v >> 8;
  }
  return InternetAddress.fromRawAddress(out).address;
}

/// Случайный BigInt в [0, 2^bits). Генерируем побайтно — nextInt(≤256) валиден
/// (Random.nextInt требует max ≤ 2^32).
BigInt _randomBigInt(int bits, Random rng) {
  var v = BigInt.zero;
  var remaining = bits;
  while (remaining > 0) {
    final take = remaining >= 8 ? 8 : remaining;
    final r = rng.nextInt(1 << take); // take ≤ 8 → max ≤ 256
    v = (v << take) | BigInt.from(r);
    remaining -= take;
  }
  return v;
}
