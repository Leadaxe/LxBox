// §841 — AmneziaWG-обфусцированный UDP-зонд: I1 + junk + WG-init одним залпом.
//
// Корневая причина «снова нет живых» на сети МегаФон (Орёл, AS12714):
// фаза 1 слала ГОЛЫЙ WireGuard handshake-initiation (148 Б). DPI оператора
// режет его по сигнатуре — все пробы уходили в timeout, хотя эталонный
// сканер (warpscout) на ЭТОЙ ЖЕ сети находит 70/70 эндпоинтов в режиме `awg`.
//
// Разница — обфускация AmneziaWG: перед обычным WG-init отправляется
//   [I1] — «первый пакет»-приманка (по умолчанию fake-DNS-ответ icloud.com,
//          44 Б; также профили quic/dns/stun/sip, см. scan_i1.dart),
//   [junk × jc] — случайные пакеты длиной jmin..jmax (10..50 Б),
// и только затем настоящий WG-init. Всё — ОДНИМ залпом, без пауз.
//
// Снятый на проводе рабочий залп (релей к 162.159.192.74:2408):
//   OUT 44B (I1) → OUT 6× junk(31,48,42,29,39,47) → OUT 148B (type=1)
//   → IN 92B type=2 (живой ответ).
// Эталон: с I1 — 70/70, без I1 (только junk) — 2/70. То есть пробивает
// именно I1-приманка; junk сам по себе почти бесполезен.

import 'dart:async';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'scan_i1.dart';
import 'scan_wire.dart';

/// §841 — состав обфусцированного залпа AmneziaWG: `[I1] + [junk × jc] + [init]`
/// (порядок как в `send.go` amneziawg-go — одним залпом). Вынесено отдельно,
/// чтобы покрыть тестом без сети.
List<Uint8List> buildAwgBurst({
  required Uint8List init,
  bool obfuscate = true,
  String i1Chain = kI1DefaultChain,
  int jc = 6,
  int jmin = 10,
  int jmax = 50,
  Random? rng,
}) {
  final r = rng ?? Random.secure();
  final burst = <Uint8List>[];
  if (obfuscate) {
    burst.add(Uint8List.fromList(renderI1Chain(i1Chain, rng: r)));
  }
  if (jc > 0) {
    final lo = jmin < 1 ? 1 : jmin;
    final hi = jmax < lo ? lo : jmax;
    for (var i = 0; i < jc; i++) {
      final n = lo + r.nextInt(hi - lo + 1);
      final junk = Uint8List(n);
      for (var k = 0; k < n; k++) {
        junk[k] = r.nextInt(256);
      }
      burst.add(junk);
    }
  }
  burst.add(init);
  return burst;
}

/// Результат AWG-пробы: тот же [WgProbeResult], но `detail` описывает состав
/// залпа (для журнала скана).
Future<WgProbeResult> probeAwgEndpoint(
  String ip,
  int port, {
  Duration timeout = const Duration(seconds: 3),
  List<int>? serverPubRaw,
  /// §841 — приватный ключ (raw 32 Б) ЗАРЕГИСТРИРОВАННОГО WARP-аккаунта.
  /// КРИТИЧНО: WARP-эндпоинты отвечают на handshake только от известного
  /// (зарегистрированного) пира — со случайным ключом сервер молчит, даже
  /// если пакет криптографически валиден. Проверено на реальном эндпоинте:
  /// ключ аккаунта → 92 Б type-2, случайный ключ → timeout.
  List<int>? staticPrivRaw,
  /// Использовать I1-приманку. `false` — только junk + init (как `-i1 none`).
  bool obfuscate = true,
  /// Цепочка I1 (AmneziaWG `i1`). По умолчанию — дефолт эталона (icloud.com).
  String i1Chain = kI1DefaultChain,
  /// Число junk-пакетов (AmneziaWG `jc`).
  int jc = 6,
  /// Минимальная длина junk-пакета (`jmin`).
  int jmin = 10,
  /// Максимальная длина junk-пакета (`jmax`).
  int jmax = 50,
  Random? rng,
}) async {
  final r = rng ?? Random.secure();
  final Uint8List init;
  try {
    init = await buildWgInitiation(
      serverPubRaw: serverPubRaw,
      staticPrivRaw: staticPrivRaw,
    );
  } catch (e) {
    return WgProbeResult(WgProbeKind.timeout, detail: 'build: $e');
  }

  // Состав залпа: [I1] + [junk × jc] + [WG-init].
  final burst = buildAwgBurst(
    init: init,
    obfuscate: obfuscate,
    i1Chain: i1Chain,
    jc: jc,
    jmin: jmin,
    jmax: jmax,
    rng: r,
  );
  final i1Len = obfuscate ? burst.first.length : 0;

  RawDatagramSocket? socket;
  try {
    socket = await RawDatagramSocket.bind(InternetAddress.anyIPv4, 0);
  } catch (e) {
    return WgProbeResult(WgProbeKind.timeout, detail: 'bind: $e');
  }

  final bytes = burst.fold<int>(0, (a, b) => a + b.length);
  final shape = 'i1=${i1Len}B junk=${burst.length - 1 - (i1Len > 0 ? 1 : 0)}'
      '(j$jmin..$jmax) init=${init.length}B tot=$bytes';
  final sw = Stopwatch()..start();
  final completer = Completer<WgProbeResult>();
  StreamSubscription<RawSocketEvent>? sub;
  Timer? timer;
  try {
    socket.broadcastEnabled = false;
    socket.writeEventsEnabled = false;
    final addr = InternetAddress(ip);
    for (final p in burst) {
      final sent = socket.send(p, addr, port);
      if (sent != p.length) {
        return WgProbeResult(
          WgProbeKind.timeout,
          detail: 'send short $sent/${p.length} [$shape]',
        );
      }
      // Микро-пауза, чтобы пакеты легли отдельными датаграммами (как залп
      // send.go в amneziawg-go), а не склеились в один буфер.
      await Future<void>.delayed(const Duration(milliseconds: 1));
    }

    timer = Timer(timeout, () {
      if (!completer.isCompleted) {
        completer.complete(
          WgProbeResult(
            WgProbeKind.timeout,
            detail: 'timeout ${timeout.inMilliseconds}ms (no reply) [$shape]',
          ),
        );
      }
    });
    sub = socket.listen((event) {
      if (event != RawSocketEvent.read) return;
      final dm = socket!.receive();
      if (dm == null) return;
      final res = classifyWgResponse(dm.data, rttMs: sw.elapsedMilliseconds);
      if (!completer.isCompleted) completer.complete(res);
    });
    return await completer.future;
  } catch (e) {
    return WgProbeResult(WgProbeKind.timeout, detail: 'send: $e [$shape]');
  } finally {
    timer?.cancel();
    if (sub != null) {
      try {
        await sub.cancel();
      } catch (_) {}
    }
    try {
      socket.close();
    } catch (_) {}
  }
}

/// §841 — прогон AWG-пробы (I1+junk+init) по пулу адресов с ограничением
/// конкурентности. Полный аналог [scanWgBatch], но с обфускацией и ключом
/// зарегистрированного аккаунта. [staticPrivRaw] обязателен для живых ответов.
Future<Map<String, WgProbeResult>> scanAwgBatch({
  required List<String> endpoints,
  List<int>? staticPrivRaw,
  bool obfuscate = true,
  String i1Chain = kI1DefaultChain,
  int jc = 6,
  int jmin = 10,
  int jmax = 50,
  int concurrency = 16,
  Duration timeout = const Duration(seconds: 3),
  void Function(int done, int total)? onProgress,
  void Function(String endpoint, WgProbeResult result)? onProbe,
  bool Function()? cancelled,
}) async {
  final results = <String, WgProbeResult>{};
  final queue = [...endpoints];
  var next = 0;
  var done = 0;

  Future<void> worker() async {
    while (true) {
      if (cancelled?.call() ?? false) return;
      if (next >= queue.length) return;
      final ep = queue[next++];
      final parts = ep.split(':');
      final ip = parts[0];
      final port = int.tryParse(parts.length > 1 ? parts[1] : '') ?? 2408;
      WgProbeResult r;
      try {
        r = await probeAwgEndpoint(
          ip,
          port,
          timeout: timeout,
          staticPrivRaw: staticPrivRaw,
          obfuscate: obfuscate,
          i1Chain: i1Chain,
          jc: jc,
          jmin: jmin,
          jmax: jmax,
        );
      } catch (e) {
        r = WgProbeResult(WgProbeKind.timeout, detail: 'probe: $e');
      }
      results[ep] = r;
      done++;
      onProbe?.call(ep, r);
      onProgress?.call(done, queue.length);
    }
  }

  await Future.wait([for (var i = 0; i < concurrency; i++) worker()]);
  return results;
}
