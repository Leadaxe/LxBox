import 'package:flutter_test/flutter_test.dart';
import 'package:lxbox/services/diagnostics/path_mtu.dart';

/// §725 — поиск Path MTU над поддельным пробником.
class FakeProber implements PathMtuProber {
  FakeProber({
    this.threshold = 1340,
    this.mtu = 1500,
    this.ip = '8.8.8.8',
    this.noNetwork = false,
    this.ifaceLimit,
    this.dropFirstAttemptOf = const {},
  });

  /// Проходит пакет размером не больше порога.
  int threshold;
  final int mtu;
  final String ip;
  final bool noNetwork;

  /// Больше этого — `too_big` (не влезает в интерфейс).
  final int? ifaceLimit;

  /// Размеры, у которых первая попытка теряется.
  final Set<int> dropFirstAttemptOf;

  final sent = <int>[];
  void Function(int size)? onSend;

  @override
  Future<PathMtuNetwork> network() async {
    if (noNetwork) throw const PathMtuNoNetwork();
    return PathMtuNetwork(iface: 'wlan0', transport: 'wifi', mtu: mtu);
  }

  @override
  Future<String> resolve(String host) async => ip;

  @override
  Future<PathMtuProbeReply> probe(String ip, int size,
      {required int timeoutMs, required int seq}) async {
    final first = !sent.contains(size);
    sent.add(size);
    onSend?.call(size);
    final limit = ifaceLimit;
    if (limit != null && size > limit) {
      return const PathMtuProbeReply(PathMtuProbeStatus.tooBig);
    }
    if (first && dropFirstAttemptOf.contains(size)) {
      return const PathMtuProbeReply(PathMtuProbeStatus.timeout);
    }
    return size <= threshold
        ? const PathMtuProbeReply(PathMtuProbeStatus.ok, rttMs: 38)
        : const PathMtuProbeReply(PathMtuProbeStatus.timeout);
  }
}

void main() {
  test('порог 1340 — итог 1340, рекомендации от него', () async {
    final r = await findPathMtu(FakeProber(), '8.8.8.8');
    expect(r.status, PathMtuStatus.ok);
    expect(r.pathMtu, 1340);
    expect(r.wireguardMtu, 1280);
    expect(r.masqueMtu, 1289);
    expect(r.nothingCut, isFalse);
    expect(r.probes.first.size, kPathMtuSmallProbe);
  });

  test('всё проходит — итог равен MTU интерфейса', () async {
    final p = FakeProber(threshold: 9000, mtu: 1480);
    final r = await findPathMtu(p, '8.8.8.8');
    expect(r.pathMtu, 1480);
    expect(r.nothingCut, isTrue);
    expect(p.sent, [kPathMtuSmallProbe, 1480]);
  });

  test('MTU интерфейса неизвестен — потолок 1500', () async {
    final r = await findPathMtu(FakeProber(threshold: 9000, mtu: 0), 'x');
    expect(r.pathMtu, 1500);
  });

  test('маленький не проходит — unreachable после двух попыток', () async {
    final p = FakeProber(threshold: 10);
    final r = await findPathMtu(p, '8.8.8.8');
    expect(r.status, PathMtuStatus.unreachable);
    expect(r.hasRecommendation, isFalse);
    expect(p.sent, [kPathMtuSmallProbe, kPathMtuSmallProbe]);
  });

  test('потеря одной попытки не ломает результат', () async {
    final p = FakeProber(dropFirstAttemptOf: {kPathMtuSmallProbe, 1038});
    final r = await findPathMtu(p, '8.8.8.8');
    expect(r.status, PathMtuStatus.ok);
    expect(r.pathMtu, 1340);
  });

  test('too_big на потолке — без повтора, поиск ниже', () async {
    final p = FakeProber(threshold: 9000, ifaceLimit: 1400);
    final r = await findPathMtu(p, '8.8.8.8');
    expect(p.sent.where((s) => s == 1500), hasLength(1));
    expect(r.probes[1].status, PathMtuProbeStatus.tooBig);
    expect(r.pathMtu, 1400);
  });

  test('IPv6: пол 1280, ниже пола — below_floor', () async {
    final p = FakeProber(ip: '2001:4860:4860::8888', threshold: 1200);
    final r = await findPathMtu(p, 'dns.google');
    expect(r.status, PathMtuStatus.belowFloor);
    expect(r.pathMtu, kPathMtuSmallProbe);
    expect(p.sent, contains(1280));
    expect(p.sent.where((s) => s < 1280 && s > kPathMtuSmallProbe), isEmpty);
  });

  test('IPv6: рекомендация WireGuard — минус 80', () async {
    final r = await findPathMtu(
        FakeProber(ip: '2001:db8::1', threshold: 1400), 'h');
    expect(r.pathMtu, 1400);
    expect(r.wireguardMtu, 1320);
  });

  test('нет сети — no_network', () async {
    final r = await findPathMtu(FakeProber(noNetwork: true), '8.8.8.8');
    expect(r.status, PathMtuStatus.noNetwork);
  });

  test('отмена между пробами', () async {
    final cancel = PathMtuCancel();
    final p = FakeProber();
    p.onSend = (size) {
      if (size == 1500) cancel.cancel();
    };
    final seen = <PathMtuProbe>[];
    final r = await findPathMtu(p, '8.8.8.8',
        cancel: cancel, onProbe: seen.add);
    expect(r.status, PathMtuStatus.cancelled);
    expect(p.sent.last, 1500);
    expect(seen.map((e) => e.size), [kPathMtuSmallProbe]);
  });

  test('JSON для Debug API', () async {
    final r = await findPathMtu(FakeProber(), '8.8.8.8');
    final j = r.toJson(vpnRunning: true);
    expect(j['status'], 'ok');
    expect(j['path_mtu'], 1340);
    expect(j['iface'], 'wlan0');
    expect(j['vpn_running'], true);
    expect(j['recommend'], {'wireguard': 1280, 'masque': 1289});
    expect((j['probes'] as List).first, {
      'size': kPathMtuSmallProbe,
      'status': 'ok',
      'rtt_ms': 38,
    });
  });
}
