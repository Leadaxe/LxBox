// §284/§305 — источник пула для WARP-генерации. Структура сгруппирована по
// транспорту (`wireguard` / `masque`), парсится из assets/warp_endpoints.json.
//
// WireGuard (secion `wireguard`): v4/v6 CIDR-блоки Cloudflare-first-party
// (cloudflare.com/ips: 162.159.192/193/195; 188.114.96.0/22), порты 2408/500/
// 1701/4500 (достоверные) + ports_extra (empirical, §132 — ниже приоритетом),
// keepalive (§313 — секунды, попадает в каждый сгенерированный WG/AWG-узел).
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
    this.wgEndpointsPreset = const [],
    required this.wgPorts,
    required this.wgPortsExtra,
    required this.wgSniPool,
    required this.utlsFpPool,
    this.wgKeepalive = 0,
    this.masqueHostsPreset = const [],
    required this.masqueV4Cidr,
    required this.masqueH3V4Cidr,
    required this.masquePortsH3,
    required this.masquePortsH2,
    required this.masqueSniPool,
  });

  // --- WireGuard / AWG ---
  final List<String> wgV4Cidr;
  final List<String> wgV6Cidr;

  /// §386 — готовые `host:port` для combobox endpoint в визарде. Первый элемент
  /// — рекомендуемый (официальный `engage.cloudflareclient.com:2408`), UI
  /// помечает его суффиксом. Пусто (старый asset / JSON-override без ключа) →
  /// combobox без пунктов, только свободный ввод + кубик.
  final List<String> wgEndpointsPreset;

  /// Cloudflare-достоверные WG-порты (2408/500/1701/4500). Приоритетны.
  final List<int> wgPorts;

  /// Empirical-порты — ниже приоритетом (§132: длинный список зарублен голосованием).
  final List<int> wgPortsExtra;

  /// SNI-приманки для AWG-обфускации (junk, НЕ cloudflare-домены).
  final List<String> wgSniPool;

  final List<String> utlsFpPool;

  /// §313 — `persistent_keepalive_interval` (секунды) для сгенерированных
  /// WG/AWG-узлов. Ядро дефолт НЕ подставляет: без этой строки пир молчит при
  /// простое, NAT-маппинг оператора закрывается за 30–120с и узел деградирует.
  ///
  /// Живёт в пуле (а не константой в коде), чтобы правиться JSON-окном
  /// эксперимента (§305) без пересборки APK. `0` (и отсутствие ключа в старом/
  /// пользовательском JSON) = keepalive не писать — гейт `> 0` в
  /// [WarpAccount.toWireguardConf]. На [hasData] не влияет: keepalive — тюнинг,
  /// а не источник кандидатов.
  final int wgKeepalive;

  // --- MASQUE ---

  /// §386 — готовые хосты для combobox MASQUE-endpoint в визарде. Первый —
  /// рекомендуемый (официальный домен `consumer-masque.cloudflareclient.com`),
  /// дальше device-verified IP. Пусто (старый asset/override) → UI собирает
  /// фолбэк из /32-записей [masqueH3V4Cidr].
  final List<String> masqueHostsPreset;

  /// §305 — CIDR-блоки для h2 (h2 живёт по всему блоку). h3 их НЕ использует.
  final List<String> masqueV4Cidr;

  /// §305 — device-verified: h3 (QUIC) живёт ТОЛЬКО на этих адресах (CIDR, обычно
  /// /32), НЕ на всём блоке. Рандомить h3 по широкому CIDR нельзя (попадание ~1%
  /// → мёртвые ноды). CIDR (а не голый IP) — на будущее (под-диапазоны).
  final List<String> masqueH3V4Cidr;

  /// §305 — порты MASQUE, задаются отдельными ключами на транспорт. Device-verified
  /// рабочие наборы сейчас СОВПАДАЮТ (все 7: 443/500/1701/4500/4443/8443/8095) —
  /// ключи раздельные на случай, если CF разведёт их в будущем.
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

  /// §305 — CIDR-источник IP для транспорта. h2 → весь блок (`masqueV4Cidr`);
  /// h3 → узкий `masqueH3V4Cidr` (device-verified 4 хоста). Фолбэк h3 на блок,
  /// если h3-список пуст (обратная совместимость со старым asset).
  List<String> masqueV4CidrFor(String network) {
    if (network == 'h2') return masqueV4Cidr;
    return masqueH3V4Cidr.isNotEmpty ? masqueH3V4Cidr : masqueV4Cidr;
  }

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
    // Нет ключа / не число (старый asset, пользовательский JSON-override) → 0 =
    // keepalive не писать. Строку тоже принимаем — JSON правит человек.
    int intOr0(Map m, String k) {
      final v = m[k];
      if (v is num) return v.toInt();
      if (v is String) return int.tryParse(v.trim()) ?? 0;
      return 0;
    }

    final pool = ScanPool(
      wgV4Cidr: strs(wg, 'v4_cidr'),
      wgV6Cidr: strs(wg, 'v6_cidr'),
      wgEndpointsPreset: strs(wg, 'endpoints_preset'),
      wgPorts: ints(wg, 'ports'),
      wgPortsExtra: ints(wg, 'ports_extra'),
      wgSniPool: strs(wg, 'sni_pool'),
      utlsFpPool: strs(wg, 'utls_fp_pool'),
      wgKeepalive: intOr0(wg, 'keepalive'),
      masqueHostsPreset: strs(mq, 'hosts_preset'),
      masqueV4Cidr: strs(mq, 'v4_cidr'),
      masqueH3V4Cidr: strs(mq, 'h3_v4_cidr'),
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
