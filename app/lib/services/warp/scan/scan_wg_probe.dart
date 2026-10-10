// §834 — WARP endpoint scanner: UDP WireGuard-проба + классификация ответа.
// Логика первого хода (крипта) — в scan_wire.dart, здесь сокетная часть:
// параллельные UDP-пробы на пул адресов, замер RTT, таймауты, отмена.
//
// Отдельно от probe-сессии ядра: UDP-пробу можно слать когда угодно (даже при
// поднятом VPN-туннеле — она идёт мимо ядра, из системного стека Dart). Это
// позволяет «доверять» живости эндпоинта по wire-level до того, как гонять
// дорогую probe-сессию. Финальный вердикт по стране/ноде — через ядро
// (probeGetUrl), см. endpoint_scanner.dart.

import 'dart:async';
import 'dart:io';

import 'scan_wire.dart';

/// Один UDP-probe к `ip:port`. Возвращает [WgProbeResult].
Future<WgProbeResult> probeWgEndpoint(
  String ip,
  int port, {
  Duration timeout = const Duration(seconds: 3),
  List<int>? serverPubRaw,
}) async {
  final raws = <int>[];
  try {
    final pkt = await buildWgInitiation(serverPubRaw: serverPubRaw);
    raws.addAll(pkt);
  } catch (_) {
    return const WgProbeResult(WgProbeKind.timeout);
  }

  final socket = await RawDatagramSocket.bind(InternetAddress.anyIPv4, 0);
  final sw = Stopwatch()..start();
  try {
    socket.broadcastEnabled = false;
    socket.writeEventsEnabled = false;
    final addr = InternetAddress(ip);
    socket.send(raws, addr, port);

    final completer = Completer<WgProbeResult>();
    late final StreamSubscription<RawSocketEvent> sub;
    final timer = Timer(timeout, () {
      if (!completer.isCompleted) {
        completer.complete(const WgProbeResult(WgProbeKind.timeout));
      }
    });
    sub = socket.listen((event) {
      if (event == RawSocketEvent.read) {
        final dm = socket.receive();
        if (dm == null) return;
        final elapsed = sw.elapsedMilliseconds;
        final res = classifyWgResponse(dm.data, rttMs: elapsed);
        if (res.kind != WgProbeKind.junk && !completer.isCompleted) {
          completer.complete(res);
        }
      }
    });
    try {
      return await completer.future;
    } finally {
      timer.cancel();
      await sub.cancel();
    }
  } finally {
    socket.close();
  }
}

/// Прогон UDP-пробы по пулу адресов с ограничением конкурентности.
/// [onProgress] зовётся после каждого завершённого адреса.
/// Возвращает `Map<endpoint, жива ли проба>`. [cancelled] — внешний флаг отмены.
Future<Map<String, WgProbeResult>> scanWgBatch({
  required List<String> endpoints,
  int concurrency = 16,
  Duration timeout = const Duration(seconds: 3),
  void Function(int done, int total)? onProgress,
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
      final r = await probeWgEndpoint(ip, port, timeout: timeout);
      results[ep] = r;
      done++;
      onProgress?.call(done, queue.length);
    }
  }

  await Future.wait([for (var i = 0; i < concurrency; i++) worker()]);
  return results;
}

/// Разбивает CIDR v4 на список IP (все адреса диапазона). Для /32 — один IP.
/// Широкие блоки (/25 и больше) не разворачиваем — их обрабатывает
/// [expandCidrV4] вызывающих уровней (см. limit по хостам).
List<String> expandCidrV4(String cidr, {int maxHosts = 256}) {
  final slash = cidr.indexOf('/');
  if (slash < 0) return [cidr];
  final parts = cidr.substring(0, slash).split('.').map(int.parse).toList();
  final mask = int.parse(cidr.substring(slash + 1));
  if (mask < 0 || mask > 32) return const [];
  final hostBits = 32 - mask;
  if (hostBits > 8) return const []; // широкие блоки не разворачиваем здесь
  final base = (parts[0] << 24) | (parts[1] << 16) | (parts[2] << 8) | parts[3];
  final count = 1 << hostBits;
  if (count > maxHosts) return const [];
  return [for (var i = 0; i < count; i++) _ipv4(base | i)];
}

String _ipv4(int v) =>
    '${(v >> 24) & 0xFF}.${(v >> 16) & 0xFF}.${(v >> 8) & 0xFF}.${v & 0xFF}';
