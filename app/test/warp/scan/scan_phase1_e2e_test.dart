// §835 — сквозная проверка ФАЗЫ 1 сканера (без ядра): локальный UDP-сервер на
// loopback:2408 отвечает валидным WG type-4 (92 Б), и сканер обязан отметить
// адрес живым. Внешняя сеть песочницей режется, поэтому «эндпоинт» эмулируется
// на loopback — проверяется вся оркестрация: кандидаты → проба → классификация
// → статусы → группировка → счётчики.

import 'dart:io';

import 'package:flutter/services.dart' show rootBundle;
import 'package:flutter_test/flutter_test.dart';
import 'package:lxbox/services/warp/scan/endpoint_scanner.dart';
import 'package:lxbox/services/warp/scan/scan_models.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('scan: живой WG-ответ даёт alive-статус и группу', () async {
    // Сервер на каноническом WG-порту отвечает 92-байтным type-4.
    final server = await RawDatagramSocket.bind(InternetAddress.loopbackIPv4, 2408);
    final sub = server.listen((e) {
      if (e == RawSocketEvent.read) {
        final d = server.receive();
        if (d != null) {
          server.send(<int>[4, ...List<int>.filled(91, 0)], d.address, d.port);
        }
      }
    });

    final statuses = <ScanEndpointStatus>[];
    final scanner = EndpointScanner();
    final res = await scanner.scan(
      endpoints: ['127.0.0.1'],
      concurrency: 4,
      timeout: const Duration(milliseconds: 500),
      maxGeoLookups: 0, // фазу 2 (ядро) в тесте не поднимаем
      onStatus: statuses.add,
    );

    // ignore: avoid_print
    print('statuses=${statuses.map((s) => '${s.endpoint}:${s.verdict}').toList()} '
        'totalValid=${res.totalValid} groups=${res.groups.length}');

    expect(res.totalValid, 1, reason: 'живой WG-ответ должен попасть в итог');
    expect(statuses.any((s) => s.verdict == 'alive'), isTrue);
    expect(res.groups.length, 1);

    await sub.cancel();
    server.close();
  });

  test('loadPools даёт непустой список (asset читается)', () async {
    final scanner = EndpointScanner();
    // Прогреваем asset: в тестовом окружении rootBundle отдаёт asset из
    // build/unit_test_assets (в приложении — из APK).
    try {
      await rootBundle.loadString('assets/warp_endpoints.json');
    } catch (_) {}
    final pools = await scanner.loadPools();
    // ignore: avoid_print
    print('кандидатов: ${pools.length}; примеры: ${pools.take(4).toList()}');
    expect(pools, isNotEmpty);
    expect(pools.length, lessThanOrEqualTo(300));
  });
}
