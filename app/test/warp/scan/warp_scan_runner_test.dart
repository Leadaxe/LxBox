import 'dart:math';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lxbox/services/platform_channels.dart';
import 'package:lxbox/services/warp/scan/scan_models.dart';
import 'package:lxbox/services/warp/scan/scan_pool.dart';
import 'package:lxbox/services/warp/scan/warp_scan_runner.dart';

/// §284 — оркестрация скана через mock method-канала (stopVPN / probeStart /
/// warpProbe / probeStop все идут через единый PlatformChannels.methods).
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel(PlatformChannels.methods);
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;

  ScanPool pool() => const ScanPool(
        wgV4Cidr: ['162.159.192.0/24'],
        wgV6Cidr: [],
        wgPorts: [2408],
        wgPortsEmpirical: [],
        masqueV4Cidr: ['162.159.198.0/24'],
        masquePort: 443,
        utlsFpPool: ['chrome'],
        sniPool: ['a'],
        masqueSniPool: ['b'],
      );

  tearDown(() => messenger.setMockMethodCallHandler(channel, null));

  test('probe unavailable → все результаты failed', () async {
    messenger.setMockMethodCallHandler(channel, (call) async {
      switch (call.method) {
        case 'stopVPN':
          return true;
        case 'probeStart':
          return '';
        case 'warpProbe':
          return {'alive': false, 'rttMs': 0, 'error': 'probe unavailable'};
        case 'probeStop':
          return null;
      }
      return null;
    });
    final res = await WarpScanRunner().scan(
      pool: pool(),
      seedCount: 12,
      onProgress: (_) {},
      rng: Random(1),
    );
    expect(res.length, 12);
    expect(res.every((r) => !r.alive), isTrue);
    expect(res.every((r) => r.error == 'probe unavailable'), isTrue);
  });

  test('всё живо → lifecycle корректен, все alive, сессия закрыта', () async {
    var stopVpn = 0, probeStart = 0, probeStop = 0, warpProbe = 0;
    messenger.setMockMethodCallHandler(channel, (call) async {
      switch (call.method) {
        case 'stopVPN':
          stopVpn++;
          return true;
        case 'probeStart':
          probeStart++;
          return '';
        case 'warpProbe':
          warpProbe++;
          return {'alive': true, 'rttMs': 42, 'error': ''};
        case 'probeStop':
          probeStop++;
          return null;
      }
      return null;
    });
    final res = await WarpScanRunner().scan(
      pool: pool(),
      seedCount: 20,
      topN: 3,
      onProgress: (_) {},
      rng: Random(2),
    );
    expect(stopVpn, 1, reason: 'VPN остановлен ровно раз перед сканом');
    expect(probeStart, 1);
    expect(probeStop, 1, reason: 'сессия закрыта в finally');
    expect(warpProbe, greaterThan(20), reason: 'посев + дотест фазы 2');
    expect(res, isNotEmpty);
    expect(res.every((r) => r.alive), isTrue);
  });

  test('probeStart провалился → посев как мёртвый с этой ошибкой', () async {
    messenger.setMockMethodCallHandler(channel, (call) async {
      switch (call.method) {
        case 'stopVPN':
          return true;
        case 'probeStart':
          return 'VPN is running — test uses the live tunnel instead';
        case 'probeStop':
          return null;
      }
      return null;
    });
    final res = await WarpScanRunner().scan(
      pool: pool(),
      seedCount: 8,
      onProgress: (_) {},
      rng: Random(3),
    );
    expect(res.length, 8);
    expect(res.every((r) => !r.alive), isTrue);
    expect(res.first.error, contains('VPN is running'));
  });

  test('warpProbe кидает PlatformException → скан не падает, все failed', () async {
    messenger.setMockMethodCallHandler(channel, (call) async {
      switch (call.method) {
        case 'stopVPN':
          return true;
        case 'probeStart':
          return '';
        case 'warpProbe':
          throw PlatformException(code: 'boom');
        case 'probeStop':
          return null;
      }
      return null;
    });
    final res = await WarpScanRunner().scan(
      pool: pool(),
      seedCount: 6,
      onProgress: (_) {},
      rng: Random(4),
    );
    expect(res.length, 6);
    expect(res.every((r) => !r.alive), isTrue);
  });

  group('mergeScanResults (демоут-guard)', () {
    ScanCandidate cand(String ip) => ScanCandidate(
        ip: ip, port: 2408, protocol: ScanProtocol.awg, sni: 'y', utlsFp: 'chrome');
    ScanResult live(ScanCandidate c, int rtt) =>
        ScanResult(candidate: c, alive: true, rttMs: rtt);

    test('фаза-2 dead НЕ демоутит живой phase-1 с тем же ключом', () {
      final c = cand('1.2.3.4');
      final merged = mergeScanResults([live(c, 120)], [ScanResult.dead(c, 'x')]);
      expect(merged.single.alive, isTrue);
      expect(merged.single.rttMs, 120);
    });

    test('среди живых остаётся меньший rtt', () {
      final c = cand('1.2.3.4');
      expect(mergeScanResults([live(c, 120)], [live(c, 50)]).single.rttMs, 50);
    });

    test('живые сверху, мёртвые снизу', () {
      final merged = mergeScanResults(
        [ScanResult.dead(cand('9.9.9.9'), 'x'), live(cand('1.1.1.1'), 30)],
        const [],
      );
      expect(merged.first.alive, isTrue);
      expect(merged.last.alive, isFalse);
    });
  });
}
