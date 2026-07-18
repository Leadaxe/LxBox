// §284 — оркестрация двухфазного WARP-скана. Останавливает боевой VPN,
// поднимает headless probe-сессию (без tun), гонит сырые пробы по IP через
// ядро, ранжирует. Фаза 1 — посев (100 случайных конфигов). Фаза 2 — дотест
// топ-N живых (вариации SNI×fp×protocol + повторы для loss).

import 'dart:math';

import '../../../vpn/box_vpn_client.dart';
import '../../../vpn/cc_channel.dart';
import '../../probe/probe_config.dart';
import 'candidate_generator.dart';
import 'scan_models.dart';
import 'scan_pool.dart';

/// Прогресс скана для UI. `phase`: 'seed' (фаза 1) | 'refine' (фаза 2).
class WarpScanProgress {
  const WarpScanProgress(this.done, this.total, this.phase);
  final int done;
  final int total;
  final String phase;
}

class WarpScanRunner {
  WarpScanRunner({CcChannel? cc, BoxVpnClient? vpn})
      : _cc = cc ?? CcChannel.instance,
        _vpn = vpn ?? BoxVpnClient();

  final CcChannel _cc;
  final BoxVpnClient _vpn;
  bool _cancelled = false;

  /// Конкурентность пула — как §209/§236 (ядро меряет по одной, мультиплекс).
  static const _concurrency = 6;
  static const _probeTimeoutMs = 2500;

  /// Повторы в фазе 2 для оценки loss/стабильного rtt.
  static const _refineRepeats = 3;

  void cancel() => _cancelled = true;

  /// Полный прогон. Останавливает VPN, поднимает сессию, двухфазный скан.
  /// Возвращает результаты: живые (по rtt) сверху, мёртвые снизу. При
  /// невозможности поднять сессию — все кандидаты в error (UI покажет как failed).
  /// `rng` инъектируется для тестов.
  Future<List<ScanResult>> scan({
    required ScanPool pool,
    int seedCount = 100,
    int topN = 3,
    required void Function(WarpScanProgress) onProgress,
    Random? rng,
  }) async {
    _cancelled = false;

    // 1. Стоп боевого VPN — пробы уходят напрямую, вне tun (иначе завернутся).
    //    Блокирующий до Stopped; если VPN уже опущен — быстрый no-op.
    await _vpn.stopVPN();
    if (_cancelled) return const [];

    // 2. Headless probe-сессия (конфиг без нод — проба по IP напрямую).
    final err = await _cc.probeStart(buildScanProbeConfigJson());
    final gen = CandidateGenerator(pool, rng: rng);
    if (err.isNotEmpty) {
      // Не смогли поднять сессию — вернуть посев как мёртвые с этой причиной.
      return gen.seed(seedCount).map((c) => ScanResult.dead(c, err)).toList();
    }

    try {
      // ── Фаза 1: посев ──
      final seeds = gen.seed(seedCount);
      final phase1 = await _probeAll(seeds, 'seed', onProgress);
      if (_cancelled) return mergeScanResults(phase1, const []);

      // ── Фаза 2: дотест топ-N живых IP ──
      final alive = phase1.where((r) => r.alive).toList()
        ..sort((a, b) => scanRtt(a).compareTo(scanRtt(b)));
      final topIps = <String>{};
      for (final r in alive) {
        topIps.add(r.candidate.ip);
        if (topIps.length >= topN) break;
      }

      var refined = const <ScanResult>[];
      if (topIps.isNotEmpty && !_cancelled) {
        final varc = <ScanCandidate>[];
        for (final ip in topIps) {
          varc.addAll(gen.variations(ip));
        }
        refined =
            await _probeAll(varc, 'refine', onProgress, repeats: _refineRepeats);
      }
      return mergeScanResults(phase1, refined);
    } finally {
      await _cc.probeStop();
    }
  }

  /// Пул конкурентных проб (worker-cursor как FolderProbeRunner._runPool).
  Future<List<ScanResult>> _probeAll(
    List<ScanCandidate> cands,
    String phase,
    void Function(WarpScanProgress) onProgress, {
    int repeats = 1,
  }) async {
    final results = <ScanResult>[];
    final total = cands.length;
    var next = 0;
    var done = 0;

    Future<void> worker() async {
      while (true) {
        if (_cancelled || next >= cands.length) return;
        final c = cands[next++];
        final r = await _probeOne(c, repeats);
        results.add(r);
        done++;
        onProgress(WarpScanProgress(done, total, phase));
      }
    }

    await Future.wait(List.generate(_concurrency, (_) => worker()));
    return results;
  }

  /// Проба одного кандидата `repeats` раз. Живой = хоть один ответ; rtt =
  /// медиана ответивших; loss = доля неответивших (только при repeats>1).
  Future<ScanResult> _probeOne(ScanCandidate c, int repeats) async {
    var aliveCount = 0;
    final rtts = <int>[];
    String? lastErr;
    for (var i = 0; i < repeats; i++) {
      if (_cancelled) break;
      final res = await _cc.warpProbe(c.toProbeArgs(_probeTimeoutMs));
      if (res.alive) {
        aliveCount++;
        rtts.add(res.rttMs);
      } else {
        lastErr = res.error;
      }
    }
    if (aliveCount == 0) return ScanResult.dead(c, lastErr ?? 'no response');
    rtts.sort();
    return ScanResult(
      candidate: c,
      alive: true,
      rttMs: rtts[rtts.length ~/ 2],
      loss: repeats > 1 ? (repeats - aliveCount) / repeats : null,
    );
  }

}

/// §284 — rtt для сортировки (мёртвые = +∞, уходят вниз).
int scanRtt(ScanResult r) => r.rttMs ?? (1 << 30);

/// Слияние посева (phase1) и дотеста (refined). ИНВАРИАНТ (spec §284): фаза 2
/// ОБОГАЩАЕТ, не демоутит — живой результат никогда не перекрывается мёртвым,
/// а среди живых для одного ключа (ip,port,proto,sni) остаётся лучший (меньший
/// rtt). Иначе транзиентный сбой дотеста ронял бы рабочую ноду в «failed».
/// Сортировка: живые (по rtt) сверху, мёртвые снизу.
List<ScanResult> mergeScanResults(
  List<ScanResult> phase1,
  List<ScanResult> refined,
) {
  String key(ScanResult r) =>
      '${r.candidate.ip}|${r.candidate.port}|${r.candidate.protocol}|${r.candidate.sni}';
  final byKey = <String, ScanResult>{};
  for (final r in [...phase1, ...refined]) {
    final k = key(r);
    final existing = byKey[k];
    if (existing == null || _betterScan(r, existing)) byKey[k] = r;
  }
  return byKey.values.toList()
    ..sort((a, b) {
      if (a.alive != b.alive) return a.alive ? -1 : 1;
      return scanRtt(a).compareTo(scanRtt(b));
    });
}

/// `a` предпочтительнее `b` для одного ключа: живой бьёт мёртвого; среди живых —
/// меньший rtt (фаза-2 median обычно ≤ single-прогон, естественно обогащает).
bool _betterScan(ScanResult a, ScanResult b) {
  if (a.alive != b.alive) return a.alive;
  if (!a.alive) return false; // оба мёртвые — не меняем
  return scanRtt(a) <= scanRtt(b);
}
