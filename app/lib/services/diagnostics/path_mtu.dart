import 'package:flutter/services.dart';

import '../platform_channels.dart';

/// §725 — замер Path MTU: наибольший IP-пакет, который доходит до цели без
/// фрагментации, мимо туннеля и без ядра.
///
/// Здесь — поиск (бинарный, с повторами и отменой) над пробником
/// [PathMtuProber]; одна проба — нативный примитив `PathMtuProbe.kt`
/// (ICMP-сокет на физической сети с запретом фрагментации). Пробник — интерфейс,
/// чтобы поиск тестировался без устройства.

/// Физическая сеть, по которой идут пробы.
class PathMtuNetwork {
  const PathMtuNetwork({
    required this.iface,
    required this.transport,
    required this.mtu,
  });

  /// Имя интерфейса (`wlan0`, `rmnet_data0`); пусто — система не сказала.
  final String iface;

  /// `wifi` | `cellular` | `ethernet` | `other`.
  final String transport;

  /// MTU интерфейса; `0` — неизвестен.
  final int mtu;
}

enum PathMtuProbeStatus { ok, timeout, tooBig, error }

/// Ответ одной пробы.
class PathMtuProbeReply {
  const PathMtuProbeReply(this.status, {this.rttMs = 0, this.error = ''});

  final PathMtuProbeStatus status;
  final int rttMs;
  final String error;
}

/// Нет физической сети (канал вернул `no_network`).
class PathMtuNoNetwork implements Exception {
  const PathMtuNoNetwork();
}

abstract class PathMtuProber {
  /// Бросает [PathMtuNoNetwork], если физической сети нет.
  Future<PathMtuNetwork> network();

  /// IP цели через DNS физической сети (мимо туннеля); литерал — как есть.
  Future<String> resolve(String host);

  Future<PathMtuProbeReply> probe(
    String ip,
    int size, {
    required int timeoutMs,
    required int seq,
  });
}

/// Пробник через нативный канал.
class ChannelPathMtuProber implements PathMtuProber {
  const ChannelPathMtuProber();

  static const _channel = MethodChannel(PlatformChannels.pathMtu);

  @override
  Future<PathMtuNetwork> network() async {
    try {
      final m = await _channel.invokeMapMethod<String, Object?>('network');
      return PathMtuNetwork(
        iface: m?['iface'] as String? ?? '',
        transport: m?['transport'] as String? ?? 'other',
        mtu: (m?['mtu'] as num?)?.toInt() ?? 0,
      );
    } on PlatformException catch (e) {
      if (e.code == 'no_network') throw const PathMtuNoNetwork();
      rethrow;
    }
  }

  @override
  Future<String> resolve(String host) async {
    try {
      final ip = await _channel.invokeMethod<String>('resolve', {'host': host});
      if (ip == null || ip.isEmpty) throw StateError('no address for $host');
      return ip;
    } on PlatformException catch (e) {
      if (e.code == 'no_network') throw const PathMtuNoNetwork();
      throw StateError(e.message ?? e.code);
    }
  }

  @override
  Future<PathMtuProbeReply> probe(
    String ip,
    int size, {
    required int timeoutMs,
    required int seq,
  }) async {
    try {
      final m = await _channel.invokeMapMethod<String, Object?>('probe', {
        'ip': ip,
        'size': size,
        'timeoutMs': timeoutMs,
        'seq': seq,
      });
      return PathMtuProbeReply(
        switch (m?['status']) {
          'ok' => PathMtuProbeStatus.ok,
          'timeout' => PathMtuProbeStatus.timeout,
          'too_big' => PathMtuProbeStatus.tooBig,
          _ => PathMtuProbeStatus.error,
        },
        rttMs: (m?['rtt_ms'] as num?)?.toInt() ?? 0,
        error: m?['error'] as String? ?? '',
      );
    } on PlatformException catch (e) {
      if (e.code == 'no_network') throw const PathMtuNoNetwork();
      return PathMtuProbeReply(PathMtuProbeStatus.error,
          error: e.message ?? e.code);
    }
  }
}

/// Итог пробы одного размера (после повторов).
class PathMtuProbe {
  const PathMtuProbe(this.size, this.status, {this.rttMs = 0});

  /// Размер IP-пакета целиком.
  final int size;
  final PathMtuProbeStatus status;
  final int rttMs;

  bool get passed => status == PathMtuProbeStatus.ok;
}

enum PathMtuStatus { ok, unreachable, noNetwork, belowFloor, cancelled, error }

/// Имена статусов в Debug API.
const Map<PathMtuStatus, String> kPathMtuStatusNames = {
  PathMtuStatus.ok: 'ok',
  PathMtuStatus.unreachable: 'unreachable',
  PathMtuStatus.noNetwork: 'no_network',
  PathMtuStatus.belowFloor: 'below_floor',
  PathMtuStatus.cancelled: 'cancelled',
  PathMtuStatus.error: 'error',
};

const Map<PathMtuProbeStatus, String> kPathMtuProbeStatusNames = {
  PathMtuProbeStatus.ok: 'ok',
  PathMtuProbeStatus.timeout: 'timeout',
  PathMtuProbeStatus.tooBig: 'too_big',
  PathMtuProbeStatus.error: 'error',
};

class PathMtuResult {
  const PathMtuResult({
    required this.target,
    required this.status,
    this.ip = '',
    this.network,
    this.pathMtu = 0,
    this.probes = const [],
    this.error = '',
  });

  final String target;
  final String ip;
  final PathMtuNetwork? network;
  final PathMtuStatus status;

  /// Наибольший прошедший размер IP-пакета; `0` — ничего не прошло.
  final int pathMtu;
  final List<PathMtuProbe> probes;
  final String error;

  bool get isIpv6 => ip.contains(':');

  /// Верхняя граница поиска (MTU интерфейса, иначе 1500).
  int get ceiling {
    final mtu = network?.mtu ?? 0;
    return mtu > 0 ? mtu : kPathMtuFallbackCeiling;
  }

  /// Путь пропускает всё, что пропускает интерфейс.
  bool get nothingCut => status == PathMtuStatus.ok && pathMtu >= ceiling;

  bool get hasRecommendation => status == PathMtuStatus.ok;

  /// MTU узла WireGuard / AWG: внешние IP + UDP + заголовок WG.
  int get wireguardMtu => pathMtu - (isIpv6 ? 80 : 60);

  /// MTU узла MASQUE: внешний QUIC-пакет = mtu + 51 (ядро, SPEC 120).
  int get masqueMtu => pathMtu - kMasqueOverhead;

  Map<String, Object?> toJson({bool vpnRunning = false}) => {
        'target': target,
        'ip': ip,
        'iface': network?.iface ?? '',
        'transport': network?.transport ?? '',
        'iface_mtu': network?.mtu ?? 0,
        'vpn_running': vpnRunning,
        'path_mtu': pathMtu,
        'status': kPathMtuStatusNames[status],
        if (error.isNotEmpty) 'error': error,
        'recommend': hasRecommendation
            ? {'wireguard': wireguardMtu, 'masque': masqueMtu}
            : null,
        'probes': [
          for (final p in probes)
            {
              'size': p.size,
              'status': kPathMtuProbeStatusNames[p.status],
              'rtt_ms': p.rttMs,
            },
        ],
      };
}

/// Отмена поиска между пробами.
class PathMtuCancel {
  bool _cancelled = false;
  bool get isCancelled => _cancelled;
  void cancel() => _cancelled = true;
}

const String kPathMtuDefaultTarget = '8.8.8.8';
const int kPathMtuFallbackCeiling = 1500;
const int kPathMtuSmallProbe = 84;
const int kPathMtuTimeoutMs = 1000;

/// Надбавка MASQUE: ядро ставит внешний `InitialPacketSize = mtu + 51`
/// (docs/KERNEL.md, SPEC 120).
const int kMasqueOverhead = 51;

/// Поиск Path MTU до [target].
///
/// [onNetwork] — сеть известна (до первой пробы); [onProbe] — каждая
/// завершённая проба по мере прихода.
Future<PathMtuResult> findPathMtu(
  PathMtuProber prober,
  String target, {
  PathMtuCancel? cancel,
  void Function(PathMtuNetwork network)? onNetwork,
  void Function(PathMtuProbe probe)? onProbe,
}) async {
  final probes = <PathMtuProbe>[];
  PathMtuNetwork? net;
  var ip = '';
  var seq = 0;

  PathMtuResult done(PathMtuStatus status, {int pathMtu = 0, String error = ''}) =>
      PathMtuResult(
        target: target,
        ip: ip,
        network: net,
        status: status,
        pathMtu: pathMtu,
        probes: List.unmodifiable(probes),
        error: error,
      );

  try {
    net = await prober.network();
  } on PathMtuNoNetwork {
    return done(PathMtuStatus.noNetwork);
  } catch (e) {
    return done(PathMtuStatus.error, error: '$e');
  }
  onNetwork?.call(net);
  if (cancel?.isCancelled ?? false) return done(PathMtuStatus.cancelled);

  try {
    ip = await prober.resolve(target.trim());
  } on PathMtuNoNetwork {
    return done(PathMtuStatus.noNetwork);
  } catch (e) {
    return done(PathMtuStatus.error, error: '$e');
  }

  final v6 = ip.contains(':');
  final floor = v6 ? 1280 : 576;
  final hi = net.mtu > 0 ? net.mtu : kPathMtuFallbackCeiling;

  /// Проба размера: до двух попыток; `too_big` — без повтора.
  Future<PathMtuProbe?> attempt(int size) async {
    PathMtuProbeReply? last;
    for (var i = 0; i < 2; i++) {
      if (cancel?.isCancelled ?? false) return null;
      seq = (seq + 1) & 0xffff;
      last = await prober.probe(ip, size,
          timeoutMs: kPathMtuTimeoutMs, seq: seq);
      if (last.status == PathMtuProbeStatus.ok ||
          last.status == PathMtuProbeStatus.tooBig) {
        break;
      }
    }
    final p = PathMtuProbe(size, last!.status, rttMs: last.rttMs);
    probes.add(p);
    onProbe?.call(p);
    return p;
  }

  try {
    // Достижимость: маленький пакет.
    final small = await attempt(kPathMtuSmallProbe);
    if (small == null) return done(PathMtuStatus.cancelled);
    if (!small.passed) return done(PathMtuStatus.unreachable);
    var lo = kPathMtuSmallProbe;

    final top = await attempt(hi);
    if (top == null) return done(PathMtuStatus.cancelled, pathMtu: lo);
    if (top.passed) return done(PathMtuStatus.ok, pathMtu: hi);
    var bad = hi;

    if (floor >= hi) return done(PathMtuStatus.belowFloor, pathMtu: lo);
    final atFloor = await attempt(floor);
    if (atFloor == null) return done(PathMtuStatus.cancelled, pathMtu: lo);
    if (!atFloor.passed) return done(PathMtuStatus.belowFloor, pathMtu: lo);
    lo = floor;

    while (bad - lo > 1) {
      final mid = (lo + bad) ~/ 2;
      final p = await attempt(mid);
      if (p == null) return done(PathMtuStatus.cancelled, pathMtu: lo);
      if (p.passed) {
        lo = mid;
      } else {
        bad = mid;
      }
    }
    return done(PathMtuStatus.ok, pathMtu: lo);
  } on PathMtuNoNetwork {
    return done(PathMtuStatus.noNetwork);
  }
}
