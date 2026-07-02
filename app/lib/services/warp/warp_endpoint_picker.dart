import 'dart:convert';
import 'dart:math';

import 'package:flutter/services.dart' show rootBundle;

/// §136 — рандом WARP-endpoint из зашитых Cloudflare-блоков (реверс
/// `warp-generator.github.io` `generateRandomEndpoint`). **БЕЗ пробы/скана.**
///
/// `prefix + rand(1..10) + ":" + pick(ports)`. Работает т.к. почти любой IP в
/// этих /24-блоках на любом порту из списка = живой WARP anycast; DPI режет
/// только дефолтный `engage.cloudflareclient.com:2408`.
///
/// Пулы prefixes/ports/sni_pool — в [_assetPath]
/// (`assets/warp_endpoints.json`), единственный источник истины (легко
/// обновить без пересборки логики). §148 — 8.x-блоки убраны из asset как
/// дохлые/режимые на LTE-DPI; остались твёрдые anycast 162.159.192/195 +
/// 188.114.96-98.
class WarpEndpointPicker {
  WarpEndpointPicker._(
      this._prefixes, this._ports, this._sniPool, this._masqueSniPool);

  static const String _assetPath = 'assets/warp_endpoints.json';
  static final Random _rng = Random.secure();

  final List<String> _prefixes;
  final List<int> _ports;
  final List<String> _sniPool;

  /// §130 — отдельный SNI-пул для MASQUE. Отличается от [_sniPool] тем, что
  /// МОЖЕТ содержать cloudflare-домены: у MASQUE это реальный TLS SNI QUIC-
  /// сессии к Cloudflare (трафик и так идёт туда), а не junk-приманка §136,
  /// где cloudflare-SNI палевен и режется DPI. Fallback на [_sniPool] если
  /// в asset нет отдельного masque_sni_pool.
  final List<String> _masqueSniPool;

  static WarpEndpointPicker? _cached;

  /// Загружает asset один раз (кэш). При ошибке — пустые списки (caller
  /// должен проверить [hasData] / fallback на дефолтный endpoint).
  static Future<WarpEndpointPicker> load() async {
    if (_cached != null) return _cached!;
    try {
      final raw = await rootBundle.loadString(_assetPath);
      final json = jsonDecode(raw) as Map<String, dynamic>;
      final sniPool = (json['sni_pool'] as List?)?.cast<String>() ?? const [];
      _cached = WarpEndpointPicker._(
        (json['prefixes'] as List?)?.cast<String>() ?? const [],
        (json['ports'] as List?)?.map((e) => (e as num).toInt()).toList() ??
            const [],
        sniPool,
        // §130 — fallback на общий пул, если masque_sni_pool не задан.
        (json['masque_sni_pool'] as List?)?.cast<String>() ?? sniPool,
      );
    } catch (_) {
      _cached = WarpEndpointPicker._(const [], const [], const [], const []);
    }
    return _cached!;
  }

  bool get hasData => _prefixes.isNotEmpty && _ports.isNotEmpty;

  /// `prefix + rand(1..10) + ":" + pick(ports)`. Возвращает null если нет
  /// данных (caller оставляет дефолтный endpoint).
  String? randomEndpoint() {
    if (!hasData) return null;
    final prefix = _prefixes[_rng.nextInt(_prefixes.length)];
    final port = _ports[_rng.nextInt(_ports.length)];
    final host = '$prefix${1 + _rng.nextInt(10)}';
    return '$host:$port';
  }

  /// Случайный SNI из пула (РФ-сайты + международные). '' если пул пуст.
  String randomSni() =>
      _sniPool.isEmpty ? '' : _sniPool[_rng.nextInt(_sniPool.length)];

  List<String> get sniPool => List.unmodifiable(_sniPool);

  /// §130 — случайный SNI из MASQUE-пула. '' если пуст.
  String randomMasqueSni() => _masqueSniPool.isEmpty
      ? ''
      : _masqueSniPool[_rng.nextInt(_masqueSniPool.length)];

  /// §130 — MASQUE SNI-пул (может содержать cloudflare-домены).
  List<String> get masqueSniPool => List.unmodifiable(_masqueSniPool);

  /// Для тестов — сброс кэша.
  static void resetForTest() => _cached = null;
}
