// §284 фаза 1 — генератор случайных полных конфигураций (Монте-Карло по всему
// пространству {IP × port × protocol × SNI × fp}). Ни один протокол не
// привилегирован. Фаза 2 — вариации вокруг живого IP (метод [variations]).

import 'dart:math';

import 'scan_models.dart';
import 'scan_pool.dart';

class CandidateGenerator {
  CandidateGenerator(
    this._pool, {
    Random? rng,
    double empiricalPortRatio = 0.3,
  })  : _rng = rng ?? Random.secure(),
        _empiricalRatio = empiricalPortRatio;

  final ScanPool _pool;
  final Random _rng;

  /// Доля проб на empirical-порт (§132: достоверны только 2408/500/1701/4500).
  final double _empiricalRatio;

  /// Фаза-1 fingerprint фиксирован — fp-диагностика включается лишь в фазе 2.
  static const phase1Fp = 'chrome';

  /// n независимых кандидатов для посева.
  List<ScanCandidate> seed(int n) => List.generate(n, (_) => _one());

  ScanCandidate _one() {
    final proto = _pickProtocol();
    return proto == ScanProtocol.awg
        ? _wgCandidate(proto)
        : _masqueCandidate(proto);
  }

  ScanCandidate _wgCandidate(ScanProtocol proto) {
    final useV6 = _pool.wgV6Cidr.isNotEmpty && _rng.nextBool();
    final cidr = _pick(useV6 ? _pool.wgV6Cidr : _pool.wgV4Cidr);
    return ScanCandidate(
      ip: randomIpInCidr(cidr, _rng),
      port: _pickWgPort(),
      protocol: proto,
      sni: _pool.sniPool.isEmpty ? '' : _pick(_pool.sniPool),
      utlsFp: phase1Fp,
    );
  }

  ScanCandidate _masqueCandidate(ScanProtocol proto) {
    final cidr = _pick(_pool.masqueV4Cidr);
    return ScanCandidate(
      ip: randomIpInCidr(cidr, _rng),
      port: _pool.masquePort,
      protocol: proto,
      sni: _pool.masqueSniPool.isEmpty ? '' : _pick(_pool.masqueSniPool),
      utlsFp: phase1Fp,
    );
  }

  /// Равновероятно среди доступных протоколов. Исключает masque, если нет
  /// masque-диапазонов, и awg — если нет wg-диапазонов. hasData гарантирует ≥1.
  ScanProtocol _pickProtocol() {
    final opts = _protocols();
    return opts[_rng.nextInt(opts.length)];
  }

  List<ScanProtocol> _protocols() => <ScanProtocol>[
        // AWG только при наличии И WG-диапазона, И WG-портов — иначе
        // _pickWgPort() упал бы на пустом списке (masque-only пул валиден).
        if ((_pool.wgV4Cidr.isNotEmpty || _pool.wgV6Cidr.isNotEmpty) &&
            _pool.wgPorts.isNotEmpty)
          ScanProtocol.awg,
        if (_pool.masqueV4Cidr.isNotEmpty) ...[
          ScanProtocol.masqueH3,
          ScanProtocol.masqueH2,
        ],
      ];

  int _pickWgPort() {
    final useEmpirical = _pool.wgPortsEmpirical.isNotEmpty &&
        _rng.nextDouble() < _empiricalRatio;
    final ports = useEmpirical ? _pool.wgPortsEmpirical : _pool.wgPorts;
    return _pick(ports);
  }

  T _pick<T>(List<T> xs) => xs[_rng.nextInt(xs.length)];

  /// Фаза 2 — вариации вокруг одного живого IP. Гарантирует по одной базовой
  /// пробе на каждый доступный протокол, добивает случайными комбинациями
  /// (SNI × fp) до [limit]. Повторные комбинации допустимы — это заодно
  /// проверка стабильности (loss).
  List<ScanCandidate> variations(String ip, {int limit = 12}) {
    final protos = _protocols();
    if (protos.isEmpty) return const [];
    final out = <ScanCandidate>[];
    for (final p in protos) {
      out.add(_variationOne(ip, p, baseFp: true));
    }
    while (out.length < limit) {
      out.add(_variationOne(ip, protos[_rng.nextInt(protos.length)]));
    }
    return out.take(limit).toList();
  }

  ScanCandidate _variationOne(String ip, ScanProtocol p, {bool baseFp = false}) {
    final isWg = p == ScanProtocol.awg;
    final sniPool = isWg ? _pool.sniPool : _pool.masqueSniPool;
    // fp значим только для masque-проб; для WG держим chrome (не влияет на WG).
    final fp = (isWg || baseFp || _pool.utlsFpPool.isEmpty)
        ? 'chrome'
        : _pick(_pool.utlsFpPool);
    return ScanCandidate(
      ip: ip,
      port: isWg ? _pickWgPort() : _pool.masquePort,
      protocol: p,
      sni: sniPool.isEmpty ? '' : _pick(sniPool),
      utlsFp: fp,
    );
  }
}
