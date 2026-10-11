// §834 — WARP endpoint scanner: UDP WireGuard-проба + классификация ответа.
// Логика первого хода (крипта) — в scan_wire.dart, здесь сокетная часть:
// параллельные UDP-пробы на пул адресов, замер RTT, таймауты, отмена.
//
// §835 — проба больше НЕ бросает наружу: любая ошибка сокета (`bind`, `send`,
// невалидный адрес) возвращается как [WgProbeResult] с `detail`, а не роняет
// весь проход. Раньше `RawDatagramSocket.bind` стоял ВНЕ try, и одна сетевая
// ошибка убивала `Future.wait` всего батча — снаружи это выглядело как «скан
// молча не работает».
//
// Отдельно от probe-сессии ядра: UDP-пробу можно слать когда угодно (даже при
// поднятом VPN-туннеле — она идёт мимо ядра, из системного стека Dart). Это
// позволяет «доверять» живости эндпоинта по wire-level до того, как гонять
// дорогую probe-сессию. Финальный вердикт по стране/ноде — через ядро
// (probeGetUrl), см. endpoint_scanner.dart.

import 'dart:async';
import 'dart:io';

import 'scan_wire.dart';

/// Один UDP-probe к `ip:port`. Возвращает [WgProbeResult]. Не бросает: ошибка
/// сокета/сборки пакета → `timeout` с `detail`.
Future<WgProbeResult> probeWgEndpoint(
  String ip,
  int port, {
  Duration timeout = const Duration(seconds: 3),
  List<int>? serverPubRaw,
}) async {
  final raws = <int>[];
  try {
    raws.addAll(await buildWgInitiation(serverPubRaw: serverPubRaw));
  } catch (e) {
    return WgProbeResult(WgProbeKind.timeout, detail: 'build: $e');
  }

  RawDatagramSocket? socket;
  try {
    socket = await RawDatagramSocket.bind(InternetAddress.anyIPv4, 0);
  } catch (e) {
    return WgProbeResult(WgProbeKind.timeout, detail: 'bind: $e');
  }

  final sw = Stopwatch()..start();
  final completer = Completer<WgProbeResult>();
  StreamSubscription<RawSocketEvent>? sub;
  Timer? timer;
  try {
    socket.broadcastEnabled = false;
    socket.writeEventsEnabled = false;
    final addr = InternetAddress(ip);
    final sent = socket.send(raws, addr, port);
    if (sent != raws.length) {
      return WgProbeResult(
        WgProbeKind.timeout,
        detail: 'send short $sent/${raws.length}',
      );
    }

    timer = Timer(timeout, () {
      if (!completer.isCompleted) {
        completer.complete(
          WgProbeResult(
            WgProbeKind.timeout,
            detail: 'timeout ${timeout.inMilliseconds}ms (no reply)',
          ),
        );
      }
    });
    sub = socket.listen((event) {
      if (event == RawSocketEvent.read) {
        final dm = socket!.receive();
        if (dm == null) return;
        final elapsed = sw.elapsedMilliseconds;
        final res = classifyWgResponse(dm.data, rttMs: elapsed);
        if (res.kind == WgProbeKind.junk) {
          // Мусор/чужой протокол — «ответ есть, но не WARP», не живость.
          if (!completer.isCompleted) {
            completer.complete(res);
          }
          return;
        }
        if (!completer.isCompleted) completer.complete(res);
      }
    });
    return await completer.future;
  } catch (e) {
    return WgProbeResult(WgProbeKind.timeout, detail: 'send: $e');
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

/// Прогон UDP-пробы по пулу адресов с ограничением конкурентности.
/// [onProgress] зовётся после каждого завершённого адреса.
/// [onProbe] — по каждому адресу (для журнала/живого списка), ДО агрегации.
/// Возвращает `Map<endpoint, WgProbeResult>`. [cancelled] — внешний флаг отмены.
Future<Map<String, WgProbeResult>> scanWgBatch({
  required List<String> endpoints,
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
        r = await probeWgEndpoint(ip, port, timeout: timeout);
      } catch (e) {
        // Страховка: probeWgEndpoint задуман no-throw, но батч не должен
        // падать даже если внутри что-то проскочит.
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

/// §835 — TCP-проверка достижимости адреса (порт открыт или соединение
/// отвергнуто = хост жив). Используется для самопроверки сети в журнале скана:
/// отличает «UDP/WG зарезан, но интернет есть» от «нет сети вовсе».
/// Возвращает `(reachable, detail)`; исключений не бросает.
Future<({bool reachable, String detail})> probeTcpReachable(
  String host,
  int port, {
  Duration timeout = const Duration(seconds: 4),
}) async {
  final sw = Stopwatch()..start();
  try {
    final s = await Socket.connect(host, port, timeout: timeout);
    final ms = sw.elapsedMilliseconds;
    try {
      s.destroy();
    } catch (_) {}
    return (reachable: true, detail: 'tcp $host:$port open in ${ms}ms');
  } on SocketException catch (e) {
    // «Connection refused» = хост ответил RST → сеть ЕСТЬ.
    final refused = e.osError?.errorCode == 111 ||
        (e.message.toLowerCase().contains('refused'));
    return (
      reachable: refused,
      detail: 'tcp $host:$port ${refused ? 'refused (host up)' : e.message}',
    );
  } catch (e) {
    return (reachable: false, detail: 'tcp $host:$port $e');
  }
}

/// §838 — TCP-порт ОТКРЫТ (соединение установлено). В отличие от
/// [probeTcpReachable] «connection refused» здесь = `open: false`: для
/// MASQUE-h2 нужен именно слушающий порт, refused — это закрытый порт, туннель
/// на нём не встанет. Исключений не бросает.
Future<({bool open, String detail})> probeTcpOpen(
  String host,
  int port, {
  Duration timeout = const Duration(seconds: 3),
}) async {
  final sw = Stopwatch()..start();
  try {
    final s = await Socket.connect(host, port, timeout: timeout);
    final ms = sw.elapsedMilliseconds;
    try {
      s.destroy();
    } catch (_) {}
    return (open: true, detail: 'tcp $host:$port open in ${ms}ms');
  } on SocketException catch (e) {
    return (open: false, detail: 'tcp $host:$port ${e.message}');
  } catch (e) {
    return (open: false, detail: 'tcp $host:$port $e');
  }
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
