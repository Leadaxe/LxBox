// §835 — проверка, что UDP-проба РЕАЛЬНО отправляет 148-байтный WG-handshake
// в сокет, и что батч проходит по всем адресам. Локальные UDP-серверы на
// loopback принимают датаграммы: это изолирует сокетный слой от внешней сети
// (в песочнице она режется), но проверяет именно то, что «трафик не идёт».

import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:lxbox/services/warp/scan/scan_wg_probe.dart';

void main() {
  test('probeWgEndpoint отправляет 148-байтный пакет цели', () async {
    final server = await RawDatagramSocket.bind(InternetAddress.loopbackIPv4, 0);
    final received = <int>[];
    final sub = server.listen((e) {
      if (e == RawSocketEvent.read) {
        final d = server.receive();
        if (d != null) received.addAll(d.data);
      }
    });

    final r = await probeWgEndpoint(
      '127.0.0.1',
      server.port,
      timeout: const Duration(milliseconds: 500),
    );
    await Future<void>.delayed(const Duration(milliseconds: 200));

    // ignore: avoid_print
    print('получено байт: ${received.length}, вердикт: ${r.kind} (${r.detail})');
    expect(received.length, 148,
        reason: 'WG-handshake (148 Б) должен уйти в сокет');

    await sub.cancel();
    server.close();
  });

  test('scanWgBatch проходит все (различные) адреса и зовёт onProgress/onProbe',
      () async {
    // Три РАЗНЫХ порта: адрес-ключ в результате уникален (иначе map дедуплит).
    final servers = <RawDatagramSocket>[];
    final subs = <StreamSubscription<RawSocketEvent>>[];
    for (var i = 0; i < 3; i++) {
      final s = await RawDatagramSocket.bind(InternetAddress.loopbackIPv4, 0);
      servers.add(s);
      subs.add(s.listen((e) {
        if (e == RawSocketEvent.read) s.receive();
      }));
    }

    var progress = 0;
    final probed = <String>[];
    final res = await scanWgBatch(
      endpoints: [for (final s in servers) '127.0.0.1:${s.port}'],
      concurrency: 2,
      timeout: const Duration(milliseconds: 300),
      onProgress: (d, t) => progress = d,
      onProbe: (ep, r) => probed.add('$ep:${r.kind.name}'),
    );

    expect(res.length, 3, reason: 'три разных адреса — три результата');
    expect(progress, 3);
    expect(probed.length, 3, reason: 'onProbe зовётся на каждый адрес');

    for (final s in subs) {
      await s.cancel();
    }
    for (final s in servers) {
      s.close();
    }
  });

  test('probeWgEndpoint на невалидном адресе не бросает (detail вместо throw)',
      () async {
    final r = await probeWgEndpoint('999.999.999.999', 2408,
        timeout: const Duration(milliseconds: 100));
    expect(r.kind.name, isNotEmpty);
    expect(r.detail, isNotEmpty);
  });
}
