// §284 — генератор случайных кандидатов (Монте-Карло по {IP × port × protocol
// × SNI}). Ни один протокол не привилегирован. Фаза 2 — вариации вокруг живого
// IP (метод [variations]). Кандидаты затем собираются в узлы папки «SCAN WARP».

import 'dart:math';

import 'scan_models.dart';
import 'scan_pool.dart';

class CandidateGenerator {
  CandidateGenerator(
    this._pool, {
    Random? rng,
    double empiricalPortRatio = 0.3,
    // §305 — v6-endpoint генерим ТОЛЬКО если в системе включён IPv6
    // (`ipv6_enabled`). Иначе v6-нода мёртва (нет маршрута). Дефолт false.
    bool allowV6 = false,
  })  : _rng = rng ?? Random.secure(),
        _empiricalRatio = empiricalPortRatio,
        _allowV6 = allowV6;

  final ScanPool _pool;
  final Random _rng;
  final bool _allowV6;

  /// Доля проб на empirical-порт (§132: достоверны только 2408/500/1701/4500).
  final double _empiricalRatio;

  /// n независимых кандидатов для посева.
  List<ScanCandidate> seed(int n) => List.generate(n, (_) => _one());

  ScanCandidate _one() {
    final proto = _pickProtocol();
    return proto == ScanProtocol.awg
        ? _wgCandidate(proto)
        : _masqueCandidate(proto);
  }

  /// Протоколы приманки AWG (masquerade `ip`). quic — самый частый (мимикрия
  /// под QUIC/HTTP3), но варьируем — иначе все AWG-узлы одинаковы.
  static const _awgIpModes = ['quic', 'quic', 'quic', 'dns', 'stun'];

  ScanCandidate _wgCandidate(ScanProtocol proto) {
    final useV6 = _allowV6 && _pool.wgV6Cidr.isNotEmpty && _rng.nextBool();
    final cidr = _pick(useV6 ? _pool.wgV6Cidr : _pool.wgV4Cidr);
    return ScanCandidate(
      ip: randomIpInCidr(cidr, _rng),
      port: _pickWgPort(),
      protocol: proto,
      sni: _pool.wgSniPool.isEmpty ? '' : _pick(_pool.wgSniPool),
      awgParams: _randomAwg(),
    );
  }

  /// AWG-параметры. Jitter фиксирован дефолтом Amnezia 1.5 (4/40/70 —
  /// обкатанное значение; варьировать его смысла нет, liveness не меняет).
  /// Разнообразие даёт только `ip` — протокол приманки (quic/dns/stun).
  AwgParams _randomAwg() => AwgParams(
        ip: _pick(_awgIpModes),
        jc: 4,
        jmin: 40,
        jmax: 70,
      );

  ScanCandidate _masqueCandidate(ScanProtocol proto) {
    final cidr = _pick(_pool.masqueV4Cidr);
    return ScanCandidate(
      ip: randomIpInCidr(cidr, _rng),
      port: _pickMasquePort(proto),
      protocol: proto,
      sni: _pool.masqueSniPool.isEmpty ? '' : _pick(_pool.masqueSniPool),
    );
  }

  /// §305 — MASQUE-порт по транспорту (h3 и h2 живут на разных). Фолбэк на
  /// h3-набор при неизвестном протоколе; на 443, если набор пуст.
  int _pickMasquePort(ScanProtocol proto) {
    final ports = proto == ScanProtocol.masqueH2
        ? _pool.masquePortsH2
        : _pool.masquePortsH3;
    return ports.isEmpty ? 443 : _pick(ports);
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
    final useExtra = _pool.wgPortsExtra.isNotEmpty &&
        _rng.nextDouble() < _empiricalRatio;
    final ports = useExtra ? _pool.wgPortsExtra : _pool.wgPorts;
    return _pick(ports);
  }

  T _pick<T>(List<T> xs) => xs[_rng.nextInt(xs.length)];

  /// Фаза 2 — вариации вокруг одного живого IP: по одной пробе на каждый
  /// доступный протокол, добор случайными комбинациями (protocol × SNI) до
  /// [limit]. Повторы допустимы (заодно проверка стабильности).
  List<ScanCandidate> variations(String ip, {int limit = 12}) {
    final protos = _protocols();
    if (protos.isEmpty) return const [];
    final out = <ScanCandidate>[];
    for (final p in protos) {
      out.add(_variationOne(ip, p));
    }
    while (out.length < limit) {
      out.add(_variationOne(ip, protos[_rng.nextInt(protos.length)]));
    }
    return out.take(limit).toList();
  }

  ScanCandidate _variationOne(String ip, ScanProtocol p) {
    final isWg = p == ScanProtocol.awg;
    final sniPool = isWg ? _pool.wgSniPool : _pool.masqueSniPool;
    return ScanCandidate(
      ip: ip,
      port: isWg ? _pickWgPort() : _pickMasquePort(p),
      protocol: p,
      sni: sniPool.isEmpty ? '' : _pick(sniPool),
      awgParams: isWg ? _randomAwg() : null,
    );
  }
}
