// §284/§305 — источник пула для WARP-генерации. Структура сгруппирована по
// транспорту (`wireguard` / `masque`), парсится из assets/warp_endpoints.json.
//
// WireGuard (secion `wireguard`): v4/v6 CIDR-блоки Cloudflare-first-party
// (cloudflare.com/ips: 162.159.192/193/195; 188.114.96.0/22), порты 2408/500/
// 1701/4500 (достоверные) + ports_extra (empirical, §132 — ниже приоритетом).
//
// MASQUE (section `masque`): device-verified боевым тестом (пинг через рабочий
// туннель, §305) — живы только .198.0/24 и .199.0/24 (.197/.192 = 0 живых,
// убраны). Порты РАЗДЕЛЬНЫ по транспорту: h3 — 443/4443/8095, h2 — 500/4500/8443.
// h3 работает и на чужих IP блока (не только сервер реги) — прошлый вывод «h3
// привязан к server» был артефактом headless-probe (probe при остановленном VPN
// не поднимает QUIC); реальную живость мерить через боевое ядро.

import 'dart:io' show InternetAddress;
import 'dart:math';
import 'dart:typed_data';

class ScanPool {
  const ScanPool({
    required this.wgV4Cidr,
    required this.wgV6Cidr,
    required this.wgPorts,
    required this.wgPortsExtra,
    required this.wgSniPool,
    required this.utlsFpPool,
    required this.masqueV4Cidr,
    required this.masquePortsH3,
    required this.masquePortsH2,
    required this.masqueSniPool,
  });

  // --- WireGuard / AWG ---
  final List<String> wgV4Cidr;
  final List<String> wgV6Cidr;

  /// Cloudflare-достоверные WG-порты (2408/500/1701/4500). Приоритетны.
  final List<int> wgPorts;

  /// Empirical-порты — ниже приоритетом (§132: длинный список зарублен голосованием).
  final List<int> wgPortsExtra;

  /// SNI-приманки для AWG-обфускации (junk, НЕ cloudflare-домены).
  final List<String> wgSniPool;

  final List<String> utlsFpPool;

  // --- MASQUE ---
  final List<String> masqueV4Cidr;

  /// §305 — device-verified порты MASQUE, РАЗДЕЛЬНО по транспорту (h3 и h2 живут
  /// на разных портах).
  final List<int> masquePortsH3;
  final List<int> masquePortsH2;

  /// SNI для MASQUE (МОЖЕТ содержать cloudflare-домены — трафик и так идёт в CF).
  final List<String> masqueSniPool;

  /// Пул пригоден, если валиден хотя бы один транспорт. WG требует портов
  /// (иначе пробу не собрать); MASQUE использует свои masque-порты.
  bool get hasData {
    final wgOk =
        (wgV4Cidr.isNotEmpty || wgV6Cidr.isNotEmpty) && wgPorts.isNotEmpty;
    return wgOk || masqueV4Cidr.isNotEmpty;
  }

  /// §305 — порты для транспорта: `h2` → h2-набор, иначе h3-набор.
  List<int> masquePortsFor(String network) =>
      network == 'h2' ? masquePortsH2 : masquePortsH3;

  /// Парс полной структуры файла (`{wireguard:{...}, masque:{...}}`). Возвращает
  /// null, если структура битая/пустая (caller прячет генератор). Один парсер и
  /// для bundled asset, и для JSON-override окна эксперимента (§305).
  static ScanPool? fromFullJson(Map<String, dynamic>? json) {
    if (json == null) return null;
    final wg = (json['wireguard'] as Map?)?.cast<String, dynamic>() ?? const {};
    final mq = (json['masque'] as Map?)?.cast<String, dynamic>() ?? const {};

    List<String> strs(Map m, String k) =>
        (m[k] as List?)?.map((e) => e.toString()).toList() ?? const [];
    List<int> ints(Map m, String k) =>
        (m[k] as List?)?.map((e) => (e as num).toInt()).toList() ?? const [];

    final pool = ScanPool(
      wgV4Cidr: strs(wg, 'v4_cidr'),
      wgV6Cidr: strs(wg, 'v6_cidr'),
      wgPorts: ints(wg, 'ports'),
      wgPortsExtra: ints(wg, 'ports_extra'),
      wgSniPool: strs(wg, 'sni_pool'),
      utlsFpPool: strs(wg, 'utls_fp_pool'),
      masqueV4Cidr: strs(mq, 'v4_cidr'),
      masquePortsH3: ints(mq, 'ports_h3'),
      masquePortsH2: ints(mq, 'ports_h2'),
      masqueSniPool: strs(mq, 'sni_pool'),
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
