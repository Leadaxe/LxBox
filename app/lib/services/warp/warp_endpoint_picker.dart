import 'dart:convert';
import 'dart:math';

import 'package:flutter/services.dart' show rootBundle;

import 'scan/scan_pool.dart';

/// §136/§305 — рандом WARP-endpoint из зашитых Cloudflare-блоков. **БЕЗ пробы.**
///
/// Единственный источник истины — [_assetPath] (`assets/warp_endpoints.json`),
/// сгруппированный по транспорту (`wireguard`/`masque`). Весь пул парсится в
/// [ScanPool]; picker — тонкая обёртка над ним (рандом IP/SNI/endpoint).
///
/// WG-рандом (§136): случайный IP из `wireguard.v4_cidr`/`v6_cidr` + порт из
/// `ports`(∪`ports_extra`). Работает т.к. почти любой IP этих блоков на любом
/// порту = живой WARP anycast; DPI режет только `engage…:2408`.
class WarpEndpointPicker {
  WarpEndpointPicker._(this._scan);

  static const String _assetPath = 'assets/warp_endpoints.json';
  static final Random _rng = Random.secure();

  /// Весь пул (null если asset битый/пустой). Picker выводит из него всё.
  final ScanPool? _scan;

  static WarpEndpointPicker? _cached;

  /// Загружает asset один раз (кэш). При ошибке — пул null (caller проверяет
  /// [hasData] / fallback на дефолтный endpoint).
  static Future<WarpEndpointPicker> load() async {
    if (_cached != null) return _cached!;
    try {
      final raw = await rootBundle.loadString(_assetPath);
      final json = jsonDecode(raw) as Map<String, dynamic>;
      _cached = WarpEndpointPicker._(ScanPool.fromFullJson(json));
    } catch (_) {
      _cached = WarpEndpointPicker._(null);
    }
    return _cached!;
  }

  bool get hasData => _scan?.hasData ?? false;

  /// §136 — случайный WG-endpoint `ip:port`. IP из v4/v6-блока, порт из
  /// `ports`∪`ports_extra`. null если нет WG-данных (caller оставляет дефолт).
  ///
  /// §305 — [allowV6]: подставлять v6-блок разрешено ТОЛЬКО если в системе
  /// включён IPv6 (`ipv6_enabled`). Иначе v6-endpoint мёртв (нет маршрута).
  /// Дефолт false — безопасный (v4-only).
  String? randomEndpoint({bool allowV6 = false}) {
    final s = _scan;
    if (s == null) return null;
    final useV6 = allowV6 && s.wgV6Cidr.isNotEmpty && _rng.nextBool();
    final blocks = useV6 ? s.wgV6Cidr : s.wgV4Cidr;
    final ports = [...s.wgPorts, ...s.wgPortsExtra];
    if (blocks.isEmpty || ports.isEmpty) return null;
    try {
      final ip = randomIpInCidr(blocks[_rng.nextInt(blocks.length)], _rng);
      final port = ports[_rng.nextInt(ports.length)];
      // v6-литерал в скобках для host:port.
      final host = ip.contains(':') ? '[$ip]' : ip;
      return '$host:$port';
    } catch (_) {
      return null;
    }
  }

  /// Случайный SNI-приманка для AWG (WG-пул). '' если пуст.
  String randomSni() {
    final p = _scan?.wgSniPool ?? const [];
    return p.isEmpty ? '' : p[_rng.nextInt(p.length)];
  }

  List<String> get sniPool => List.unmodifiable(_scan?.wgSniPool ?? const []);

  /// §386 — пресеты `host:port` для combobox WG-endpoint. Пусто, если ключа
  /// нет в asset/override.
  List<String> get endpointsPreset =>
      List.unmodifiable(_scan?.wgEndpointsPreset ?? const []);

  /// §386 — рекомендуемый WG-endpoint (ключ `recommended_endpoint` asset'а).
  /// UI помечает совпадающий пункт списка. '' → пометки нет.
  String get recommendedEndpoint => _scan?.wgRecommendedEndpoint ?? '';

  /// §386 — рекомендуемый MASQUE-хост (ключ `recommended_host` asset'а).
  String get recommendedMasqueHost => _scan?.masqueRecommendedHost ?? '';

  /// §386 — хосты для combobox MASQUE-endpoint. Приоритет — явный
  /// `masque.hosts_preset` из asset. Фолбэк для старого asset/override
  /// без ключа — узкие h3-CIDR (`/32` → голый IP, device-verified живые
  /// адреса; не-/32 записи пропускаем). Живы и для h2 (подмножество блоков).
  List<String> get masqueHostsPreset {
    final preset = _scan?.masqueHostsPreset ?? const <String>[];
    if (preset.isNotEmpty) return List.unmodifiable(preset);
    final out = <String>[];
    for (final cidr in _scan?.masqueH3V4Cidr ?? const <String>[]) {
      if (cidr.endsWith('/32')) out.add(cidr.substring(0, cidr.length - 3));
    }
    return List.unmodifiable(out);
  }

  /// §130 — случайный SNI из MASQUE-пула. '' если пуст.
  String randomMasqueSni() {
    final p = _scan?.masqueSniPool ?? const [];
    return p.isEmpty ? '' : p[_rng.nextInt(p.length)];
  }

  /// §130 — MASQUE SNI-пул (может содержать cloudflare-домены).
  List<String> get masqueSniPool =>
      List.unmodifiable(_scan?.masqueSniPool ?? const []);

  /// §284 — весь пул (null если asset отсутствует/битый).
  ScanPool? get scan => _scan;

  /// §305 — MASQUE CIDR-блоки для выбора endpoint. Пусто если нет пула.
  List<String> get masqueV4Cidr =>
      List.unmodifiable(_scan?.masqueV4Cidr ?? const []);

  /// §305 — device-verified MASQUE-порты для транспорта (`h3`/`h2`). Пусто если
  /// нет пула.
  List<int> masquePortsFor(String network) =>
      _scan?.masquePortsFor(network) ?? const [];

  /// §305 — случайный MASQUE-порт для транспорта. null если набор пуст.
  int? randomMasquePortFor(String network) {
    final ports = masquePortsFor(network);
    return ports.isEmpty ? null : ports[_rng.nextInt(ports.length)];
  }

  /// §305 — случайный MASQUE-IP из случайного блока. null если пусто/битый CIDR
  /// (caller оставляет endpoint из регистрации).
  String? randomMasqueIp({String network = 'h3'}) {
    // §305 — источник ЗАВИСИТ от транспорта: h3 живёт только на 4 хостах, рандом
    // по всему блоку дал бы мёртвый адрес в ~99% случаев.
    final blocks = _scan?.masqueV4CidrFor(network) ?? const [];
    if (blocks.isEmpty) return null;
    final cidr = blocks[_rng.nextInt(blocks.length)];
    try {
      return randomIpInCidr(cidr, _rng);
    } catch (_) {
      return null;
    }
  }

  /// §305 — сырой JSON asset'а (для дефолта JSON-окна эксперимента). '' при сбое.
  static Future<String> loadRawJson() async {
    try {
      return await rootBundle.loadString(_assetPath);
    } catch (_) {
      return '';
    }
  }

  /// Для тестов — сброс кэша.
  static void resetForTest() => _cached = null;
}
